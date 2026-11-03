/*
 * Codegen for the self-hosted C compiler
 * Copyright (C) 2026  Xing Guo
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <inttypes.h>
#include <limits.h>
#include <stdio.h>

#include "codegen.h"
#include "layout.h"
#include "parser.h"
#include "type.h"

/*
 * Function and control-flow state for statement emission. Loops and switches
 * copy this context before replacing their break and continue targets.
 */
typedef struct {
  const AstNode *function;
  int break_label;    /* -1 when there is no enclosing loop or switch. */
  int continue_label; /* -1 when there is no enclosing loop. */
  int ret_label; /* Unique return label, also used to qualify user labels. */
} CodegenContext;

/*
 * Counts generated labels so that each control-flow construct gets unique
 * ones (.L.else.N, .L.end.N, ...).
 */
static int label_seq;

/*
 * Number of unbalanced pushq instructions in the current expression, so
 * that a call site can restore 16-byte stack alignment.
 */
static int push_depth;

/*
 * Assembly is emitted here; set by codegen() so that helpers need no FILE*
 * parameter (GCC's asm_out_file).
 */
static FILE *out;

/*
 * The first six integer argument registers, in order (System V AMD64),
 * in their 64-bit, 32-bit, 16-bit, and 8-bit spellings.
 */
static const char *argregs64[] = {"%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"};
static const char *argregs32[] = {"%edi", "%esi", "%edx",
                                  "%ecx", "%r8d", "%r9d"};
static const char *argregs16[] = {"%di", "%si", "%dx", "%cx", "%r8w", "%r9w"};
static const char *argregs8[] = {"%dil", "%sil", "%dl", "%cl", "%r8b", "%r9b"};

static void codegen_expr(AstNode *expr);

static void codegen_bytes(const unsigned char *bytes, int length) {
  int i;
  for (i = 0; i < length; ++i) {
    if (i % 16 == 0)
      fprintf(out, "\t.byte ");
    else
      fprintf(out, ", ");
    fprintf(out, "%u", (unsigned)bytes[i]);
    if (i % 16 == 15 || i == length - 1)
      fprintf(out, "\n");
  }
}

/*
 * Emit the decoded bytes, including embedded zeros and the final terminator.
 * Preserve the caller's section and return the string's label number.
 */
static int codegen_string_literal(AstNode *expr) {
  int seq = label_seq++;
  fprintf(out, "\t.pushsection .rodata\n");
  fprintf(out, ".L.string.%d:\n", seq);
  codegen_bytes(expr->d.string_literal.val, expr->type->array_len);
  fprintf(out, "\t.popsection\n");
  return seq;
}

/*
 * Copy the string into the local array, then zero any remaining elements.
 * Repeated byte instructions keep large padding from bloating the code.
 */
static void codegen_local_string_array(Type *type, AstNode *expr, int offset) {
  int size = type_size(type);
  int length = expr->type->array_len < size ? expr->type->array_len : size;
  int seq = codegen_string_literal(expr);
  fprintf(out, "\tleaq .L.string.%d(%%rip), %%rsi\n", seq);
  fprintf(out, "\tleaq -%d(%%rbp), %%rdi\n", offset);
  fprintf(out, "\tmovl $%d, %%ecx\n", length);
  fprintf(out, "\trep movsb\n");
  if (size > length) {
    fprintf(out, "\txorl %%eax, %%eax\n");
    fprintf(out, "\tmovl $%d, %%ecx\n", size - length);
    fprintf(out, "\trep stosb\n");
  }
}

static void codegen_addr(AstNode *expr) {
  switch (expr->kind) {
  case AST_VAR: {
    Variable *var = expr->d.variable.var;
    if (var->is_global)
      fprintf(out, "\tleaq %.*s(%%rip), %%rax\n", var->name.len,
              var->name.start);
    else
      fprintf(out, "\tleaq -%d(%%rbp), %%rax\n", var->offset);
    break;
  }
  case AST_MEMBER:
    /*
     * Both '.' and '->' use the record's address plus its member offset.
     * Union members have offset zero; anonymous members form nested accesses.
     */
    codegen_expr(expr->d.member.base);
    fprintf(out, "\taddq $%d, %%rax\n", expr->d.member.member->offset);
    break;
  case AST_STRING_LITERAL: {
    int seq = codegen_string_literal(expr);
    fprintf(out, "\tleaq .L.string.%d(%%rip), %%rax\n", seq);
    break;
  }
  case AST_DEREF:
    /* The pointer value is the address. */
    codegen_expr(expr->d.unary.operand);
    break;
  default:
    fprintf(stderr, "invalid address expr in codegen\n");
    exit(1);
  }
}

/*
 * Load through the address in %rax into a 64-bit destination register.
 * Signed loads sign-extend, unsigned loads zero-extend. Clobbers %r11.
 */
static void codegen_load(Type *type, const char *dst) {
  if (type->size == 8)
    fprintf(out, "\tmovq (%%rax), %s\n", dst);
  else if (type->size == 1)
    fprintf(out,
            type->is_unsigned ? "\tmovzbq (%%rax), %s\n"
                              : "\tmovsbq (%%rax), %s\n",
            dst);
  else if (type->kind == TYPE_SHORT)
    fprintf(out,
            type->is_unsigned ? "\tmovzwq (%%rax), %s\n"
                              : "\tmovswq (%%rax), %s\n",
            dst);
  else if (type->is_unsigned) {
    fprintf(out, "\tmovl (%%rax), %%r11d\n");
    fprintf(out, "\tmovq %%r11, %s\n", dst);
  } else
    fprintf(out, "\tmovslq (%%rax), %s\n", dst);
}

/*
 * Store the value in %rcx through the address in %rax. For records, %rcx
 * points to the source bytes; the copy preserves %rax and clobbers %rcx,
 * %rsi and %rdi. Scalar stores preserve both input registers.
 */
static void codegen_store(Type *type) {
  if (is_record(type)) {
    fprintf(out, "\tmovq %%rcx, %%rsi\n");
    fprintf(out, "\tmovq %%rax, %%rdi\n");
    fprintf(out, "\tmovl $%d, %%ecx\n", type_size(type));
    fprintf(out, "\trep movsb\n");
  } else if (type->size == 8)
    fprintf(out, "\tmovq %%rcx, (%%rax)\n");
  else if (type->size == 1)
    fprintf(out, "\tmovb %%cl, (%%rax)\n");
  else if (type->kind == TYPE_SHORT)
    fprintf(out, "\tmovw %%cx, (%%rax)\n");
  else
    fprintf(out, "\tmovl %%ecx, (%%rax)\n");
}

/*
 * A list initializes its whole object before writing explicit subobjects.
 * A designator's intermediate nodes only apply their children, preserving
 * any preceding whole-object copy or string initialization.
 */
static void codegen_local_initializer(Initializer *init, int offset) {
  Initializer *child;
  if (init->zero_fill) {
    fprintf(out, "\tleaq -%d(%%rbp), %%rdi\n", offset);
    fprintf(out, "\txorl %%eax, %%eax\n");
    fprintf(out, "\tmovl $%d, %%ecx\n", type_size(init->type));
    fprintf(out, "\trep stosb\n");
  }
  if (init->expr) {
    if (init->type->kind == TYPE_ARRAY) {
      codegen_local_string_array(init->type, init->expr, offset);
    } else {
      codegen_expr(init->expr);
      fprintf(out, "\tmovq %%rax, %%rcx\n");
      fprintf(out, "\tleaq -%d(%%rbp), %%rax\n", offset);
      codegen_store(init->type);
    }
  }
  for (child = init->children; child; child = child->next)
    codegen_local_initializer(child, offset - child->offset);
}

/*
 * Pack at most eight bytes from %r10 into an ABI result register. Partial
 * eightbytes must not read beyond the object. Clobbers %r11.
 * size must be 1..8; offset must be nonnegative and leave room for every byte.
 */
static void codegen_load_bytes(const char *dst, int offset, int size) {
  int i;
  if (size < 1 || size > 8 || offset < 0 || offset > INT_MAX - (size - 1)) {
    fprintf(stderr, "invalid byte load in codegen: offset %d, size %d\n",
            offset, size);
    exit(1);
  }
  if (size == 8) {
    fprintf(out, "\tmovq %d(%%r10), %s\n", offset, dst);
    return;
  }
  fprintf(out, "\txorq %s, %s\n", dst, dst);
  for (i = size - 1; i >= 0; --i) {
    if (i != size - 1)
      fprintf(out, "\tshlq $8, %s\n", dst);
    fprintf(out, "\tmovzbq %d(%%r10), %%r11\n", offset + i);
    fprintf(out, "\torq %%r11, %s\n", dst);
  }
}

/*
 * Unpack an ABI register into a local object without touching adjacent bytes.
 * offset is the positive distance below %rbp. Clobbers %r10.
 * size must be 1..8 and offset must be at least size to stay below %rbp.
 */
static void codegen_store_bytes(const char *src, int offset, int size) {
  int i;
  if (size < 1 || size > 8 || offset < size) {
    fprintf(stderr, "invalid byte store in codegen: offset %d, size %d\n",
            offset, size);
    exit(1);
  }
  if (size == 8) {
    fprintf(out, "\tmovq %s, -%d(%%rbp)\n", src, offset);
    return;
  }
  fprintf(out, "\tmovq %s, %%r10\n", src);
  for (i = 0; i < size; ++i) {
    fprintf(out, "\tmovb %%r10b, -%d(%%rbp)\n", offset - i);
    if (i != size - 1)
      fprintf(out, "\tshrq $8, %%r10\n");
  }
}

static void codegen_return(const CodegenContext *ctx) {
  const AstNode *function = ctx->function;
  Type *type = function->d.function.declaration->return_type;
  int size = type_size(type);
  if (!is_record(type))
    return;
  if (return_in_memory(type)) {
    fprintf(out, "\tmovq %%rax, %%rcx\n");
    fprintf(out, "\tmovq -%d(%%rbp), %%rax\n",
            function->d.function.return_offset);
    codegen_store(type);
  } else {
    fprintf(out, "\tmovq %%rax, %%r10\n");
    codegen_load_bytes("%rax", 0, size < 8 ? size : 8);
    if (size > 8)
      codegen_load_bytes("%rdx", 8, size - 8);
  }
}

/*
 * Normalize the value in %rax to its integer type: truncate to the type's
 * width, then sign- or zero-extend. _Bool converts any nonzero value to 1.
 * Long, pointer and void need no change.
 */
static void codegen_normalize(Type *type) {
  if (type->kind == TYPE_BOOL) {
    fprintf(out, "\tcmpq $0, %%rax\n");
    fprintf(out, "\tsetne %%al\n");
    fprintf(out, "\tmovzbl %%al, %%eax\n");
  } else if (type->kind == TYPE_CHAR)
    fprintf(out, type->is_unsigned ? "\tmovzbq %%al, %%rax\n"
                                   : "\tmovsbq %%al, %%rax\n");
  else if (type->kind == TYPE_SHORT)
    fprintf(out, type->is_unsigned ? "\tmovzwq %%ax, %%rax\n"
                                   : "\tmovswq %%ax, %%rax\n");
  else if (type->kind == TYPE_INT || type->kind == TYPE_ENUM)
    fprintf(out, type->is_unsigned ? "\tmovl %%eax, %%eax\n" : "\tcltq\n");
}

/*
 * Test the full value in %rax using the expression's width.
 */
static void codegen_test(Type *type) {
  fprintf(out, type->size == 8 ? "\tcmpq $0, %%rax\n" : "\tcmpl $0, %%eax\n");
}

/*
 * Integer operands are already in %rax and %rcx. Width and signedness
 * select instructions; shifts always take their count from %cl.
 */
static void codegen_integer_binary(AstKind kind, Type *type) {
  bool wide = type->size == 8;
  char suffix = wide ? 'q' : 'l';
  const char *lhs = wide ? "%rax" : "%eax";
  const char *rhs = wide ? "%rcx" : "%ecx";
  const char *op;

  switch (kind) {
  case AST_ADD:
    op = "add";
    break;
  case AST_SUB:
    op = "sub";
    break;
  case AST_MUL:
    op = "imul";
    break;
  case AST_BIT_AND:
    op = "and";
    break;
  case AST_BIT_OR:
    op = "or";
    break;
  case AST_BIT_XOR:
    op = "xor";
    break;
  case AST_LSHIFT:
    op = "sal";
    rhs = "%cl";
    break;
  case AST_RSHIFT:
    op = type->is_unsigned ? "shr" : "sar";
    rhs = "%cl";
    break;
  case AST_DIV:
  case AST_MOD:
    if (type->is_unsigned) {
      fprintf(out, "\txorl %%edx, %%edx\n");
      fprintf(out, "\tdiv%c %s\n", suffix, rhs);
    } else {
      fprintf(out, wide ? "\tcqto\n" : "\tcltd\n");
      fprintf(out, "\tidiv%c %s\n", suffix, rhs);
    }
    if (kind == AST_MOD)
      fprintf(out, "\tmov%c %s, %s\n", suffix, wide ? "%rdx" : "%edx", lhs);
    return;
  default:
    fprintf(stderr, "unrecognized integer binary operator\n");
    exit(1);
  }
  fprintf(out, "\t%s%c %s, %s\n", op, suffix, rhs, lhs);
}

/* Pointer operands are in %rax and %rcx; sema has checked the pointee type. */
static void codegen_pointer_offset(AstKind kind, Type *type) {
  fprintf(out, "\timulq $%d, %%rcx\n", type_size(type->base));
  fprintf(out, kind == AST_PTR_ADD ? "\taddq %%rcx, %%rax\n"
                                   : "\tsubq %%rcx, %%rax\n");
}

static void codegen_call(AstNode *expr) {
  AstNode *arg;
  bool memory_return = return_in_memory(expr->type);
  /*
   * A hidden return-buffer pointer reserves the first argument register, %rdi.
   */
  int nregs = memory_return ? 1 : 0;
  int64_t stack_offset = 0;
  int stack_size;
  int slots;
  int i;

  for (arg = expr->d.call.args; arg; arg = arg->next)
    layout_argument(arg->type, &nregs, &stack_offset);
  stack_size = (int)stack_offset;
  /*
   * Stack arguments precede staging slots for register arguments. Padding
   * stays above both, leaving the first stack argument at 0(%rsp).
   */
  slots = stack_size / 8 + nregs;
  slots += (push_depth + slots) % 2;
  if (slots)
    fprintf(out, "\tsubq $%d, %%rsp\n", slots * 8);
  push_depth += slots;

  nregs = memory_return ? 1 : 0;
  stack_offset = 0;
  for (arg = expr->d.call.args; arg; arg = arg->next) {
    int offset = (int)stack_offset;
    int reg = layout_argument(arg->type, &nregs, &stack_offset);
    if (reg >= 0)
      offset = stack_size + reg * 8;
    /* Stage values before loading registers; nested calls may clobber them. */
    codegen_expr(arg);
    if (is_record(arg->type)) {
      fprintf(out, "\tmovq %%rax, %%rcx\n");
      fprintf(out, "\tleaq %d(%%rsp), %%rax\n", offset);
      codegen_store(arg->type);
    } else {
      fprintf(out, "\tmovq %%rax, %d(%%rsp)\n", offset);
    }
  }
  for (i = memory_return ? 1 : 0; i < nregs; ++i)
    fprintf(out, "\tmovq %d(%%rsp), %s\n", stack_size + i * 8, argregs64[i]);
  if (memory_return)
    fprintf(out, "\tleaq -%d(%%rbp), %%rdi\n", expr->d.call.offset);
  /* Prototype-less calls must report that no vector registers were used. */
  fprintf(out, "\txorl %%eax, %%eax\n");
  fprintf(out, "\tcall %.*s\n", expr->d.call.function->name.len,
          expr->d.call.function->name.start);
  if (slots)
    fprintf(out, "\taddq $%d, %%rsp\n", slots * 8);
  push_depth -= slots;

  if (is_record(expr->type)) {
    int size = type_size(expr->type);
    if (!memory_return) {
      codegen_store_bytes("%rax", expr->d.call.offset, size < 8 ? size : 8);
      if (size > 8)
        codegen_store_bytes("%rdx", expr->d.call.offset - 8, size - 8);
    }
    fprintf(out, "\tleaq -%d(%%rbp), %%rax\n", expr->d.call.offset);
  } else if (expr->type->kind == TYPE_BOOL) {
    /* Only the low byte of a _Bool result is defined by the ABI. */
    fprintf(out, "\tmovzbl %%al, %%eax\n");
  } else {
    codegen_normalize(expr->type);
  }
}

static void codegen_expr(AstNode *expr) {
  switch (expr->kind) {
  case AST_VAR:
  case AST_DEREF:
  case AST_STRING_LITERAL:
  case AST_MEMBER:
    codegen_addr(expr);
    if (expr->type->kind != TYPE_ARRAY && !is_record(expr->type))
      codegen_load(expr->type, "%rax");
    break;
  case AST_ADDR:
    /* The address is the value. */
    codegen_addr(expr->d.unary.operand);
    break;
  case AST_ASSIGN:
    codegen_expr(expr->d.binary.rhs);
    fprintf(out, "\tpushq %%rax\n");
    push_depth++;
    codegen_addr(expr->d.binary.lhs);
    fprintf(out, "\tpopq %%rcx\n");
    push_depth--;
    codegen_store(expr->type);
    if (!is_record(expr->type)) {
      fprintf(out, "\tmovq %%rcx, %%rax\n");
      codegen_normalize(expr->type);
    }
    break;
  case AST_COMPOUND_ASSIGN: {
    AstKind op = expr->d.compound_assign.op;
    Type *operation_type = expr->d.compound_assign.operation_type;

    /*
     * Evaluate rhs first, as for ordinary assignment, and preserve it while
     * computing the target address. Calls in either operand may clobber
     * registers. Once the address is saved, load and update the object once.
     */
    codegen_expr(expr->d.compound_assign.rhs);
    codegen_normalize(expr->d.compound_assign.rhs->type);
    fprintf(out, "\tpushq %%rax\n");
    push_depth++;
    codegen_addr(expr->d.compound_assign.lhs);
    fprintf(out, "\tpopq %%rcx\n");
    push_depth--;
    fprintf(out, "\tpushq %%rax\n");
    push_depth++;
    codegen_load(expr->type, "%rax");
    codegen_normalize(operation_type);
    if (op == AST_PTR_ADD || op == AST_PTR_SUB)
      codegen_pointer_offset(op, operation_type);
    else
      codegen_integer_binary(op, operation_type);
    /*
     * Convert back before storing, so _Bool objects contain only 0 or 1.
     */
    codegen_normalize(expr->type);
    fprintf(out, "\tmovq %%rax, %%rcx\n");
    fprintf(out, "\tpopq %%rax\n");
    push_depth--;
    codegen_store(expr->type);
    fprintf(out, "\tmovq %%rcx, %%rax\n");
    break;
  }
  case AST_CAST:
    codegen_expr(expr->d.unary.operand);
    if (is_record(expr->type)) {
      fprintf(out, "\tmovq %%rax, %%rcx\n");
      fprintf(out, "\tleaq -%d(%%rbp), %%rax\n", expr->d.unary.offset);
      codegen_store(expr->type);
      break;
    }
    if ((is_integer(expr->type) || expr->type->kind == TYPE_PTR) &&
        is_integer(expr->d.unary.operand->type) &&
        expr->type->size > expr->d.unary.operand->type->size)
      codegen_normalize(expr->d.unary.operand->type);
    codegen_normalize(expr->type);
    break;
  case AST_INT_LITERAL:
    if (expr->type->size == 8)
      fprintf(out, "\tmovabsq $%" PRIu64 ", %%rax\n", expr->d.int_literal.val);
    else
      fprintf(out, "\tmovl $%" PRIu32 ", %%eax\n",
              (uint32_t)expr->d.int_literal.val);
    break;
  case AST_ADD:
  case AST_SUB:
  case AST_MUL:
  case AST_DIV:
  case AST_MOD:
  case AST_LSHIFT:
  case AST_RSHIFT:
  case AST_BIT_AND:
  case AST_BIT_XOR:
  case AST_BIT_OR:
    codegen_expr(expr->d.binary.rhs);
    fprintf(out, "\tpushq %%rax\n");
    push_depth++;
    codegen_expr(expr->d.binary.lhs);
    fprintf(out, "\tpopq %%rcx\n");
    push_depth--;
    codegen_integer_binary(expr->kind, expr->type);
    break;
  case AST_PTR_ADD:
  case AST_PTR_SUB: {
    /* Pointer +- integer, scaled by the pointee's size. */
    codegen_expr(expr->d.binary.rhs);
    codegen_normalize(expr->d.binary.rhs->type);
    fprintf(out, "\tpushq %%rax\n");
    push_depth++;
    codegen_expr(expr->d.binary.lhs);
    fprintf(out, "\tpopq %%rcx\n");
    push_depth--;
    codegen_pointer_offset(expr->kind, expr->type);
    break;
  }
  case AST_PTR_DIFF: {
    /* Pointer difference: byte distance / pointee size. */
    codegen_expr(expr->d.binary.rhs);
    fprintf(out, "\tpushq %%rax\n");
    push_depth++;
    codegen_expr(expr->d.binary.lhs);
    fprintf(out, "\tpopq %%rcx\n");
    push_depth--;
    fprintf(out, "\tsubq %%rcx, %%rax\n");
    fprintf(out, "\tmovq $%d, %%rcx\n",
            type_size(expr->d.binary.lhs->type->base));
    fprintf(out, "\tcqto\n");
    fprintf(out, "\tidivq %%rcx\n");
    break;
  }
  case AST_LT:
  case AST_LE:
  case AST_GT:
  case AST_GE:
  case AST_EQ:
  case AST_NE: {
    bool wide = expr->d.binary.lhs->type->size == 8 ||
                expr->d.binary.rhs->type->size == 8;
    codegen_expr(expr->d.binary.rhs);
    fprintf(out, "\tpushq %%rax\n");
    push_depth++;
    codegen_expr(expr->d.binary.lhs);
    fprintf(out, "\tpopq %%rcx\n");
    push_depth--;

    fprintf(out, wide ? "\tcmpq %%rcx, %%rax\n" : "\tcmpl %%ecx, %%eax\n");
    switch (expr->kind) {
    case AST_EQ:
      fprintf(out, "\tsete %%al\n");
      break;
    case AST_NE:
      fprintf(out, "\tsetne %%al\n");
      break;
    case AST_LT:
      fprintf(out, expr->d.binary.lhs->type->is_unsigned ? "\tsetb %%al\n"
                                                         : "\tsetl %%al\n");
      break;
    case AST_LE:
      fprintf(out, expr->d.binary.lhs->type->is_unsigned ? "\tsetbe %%al\n"
                                                         : "\tsetle %%al\n");
      break;
    case AST_GT:
      fprintf(out, expr->d.binary.lhs->type->is_unsigned ? "\tseta %%al\n"
                                                         : "\tsetg %%al\n");
      break;
    case AST_GE:
      fprintf(out, expr->d.binary.lhs->type->is_unsigned ? "\tsetae %%al\n"
                                                         : "\tsetge %%al\n");
      break;
    default:
      fprintf(stderr, "unrecognized comparison operator\n");
      exit(1);
    }
    /* Zero-extend %al into %eax. */
    fprintf(out, "\tmovzbl %%al, %%eax\n");
    break;
  }
  case AST_LOGICAL_AND: {
    int seq = label_seq++;

    /* Short-circuit: skip the right operand when the left one is zero. */
    codegen_expr(expr->d.binary.lhs);
    codegen_test(expr->d.binary.lhs->type);
    fprintf(out, "\tje .L.false.%d\n", seq);
    codegen_expr(expr->d.binary.rhs);
    codegen_test(expr->d.binary.rhs->type);
    fprintf(out, "\tje .L.false.%d\n", seq);
    fprintf(out, "\tmovl $1, %%eax\n");
    fprintf(out, "\tjmp .L.end.%d\n", seq);
    fprintf(out, ".L.false.%d:\n", seq);
    fprintf(out, "\tmovl $0, %%eax\n");
    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_LOGICAL_OR: {
    int seq = label_seq++;

    /* Short-circuit: skip the right operand when the left one is nonzero. */
    codegen_expr(expr->d.binary.lhs);
    codegen_test(expr->d.binary.lhs->type);
    fprintf(out, "\tjne .L.true.%d\n", seq);
    codegen_expr(expr->d.binary.rhs);
    codegen_test(expr->d.binary.rhs->type);
    fprintf(out, "\tjne .L.true.%d\n", seq);
    fprintf(out, "\tmovl $0, %%eax\n");
    fprintf(out, "\tjmp .L.end.%d\n", seq);
    fprintf(out, ".L.true.%d:\n", seq);
    fprintf(out, "\tmovl $1, %%eax\n");
    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_COMMA:
    /* The left operand's value is discarded, its side effects kept. */
    codegen_expr(expr->d.binary.lhs);
    codegen_expr(expr->d.binary.rhs);
    break;
  case AST_CONDITIONAL: {
    int seq = label_seq++;

    /* Only the selected branch is evaluated. */
    codegen_expr(expr->d.conditional.cond);
    codegen_test(expr->d.conditional.cond->type);
    fprintf(out, "\tje .L.else.%d\n", seq);
    codegen_expr(expr->d.conditional.then_expr);
    fprintf(out, "\tjmp .L.end.%d\n", seq);
    fprintf(out, ".L.else.%d:\n", seq);
    codegen_expr(expr->d.conditional.else_expr);
    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_CALL:
    codegen_call(expr);
    break;
  case AST_NEG:
    codegen_expr(expr->d.unary.operand);
    fprintf(out, expr->type->size == 8 ? "\tnegq %%rax\n" : "\tnegl %%eax\n");
    break;
  case AST_BITWISE_NOT:
    codegen_expr(expr->d.unary.operand);
    fprintf(out, expr->type->size == 8 ? "\tnotq %%rax\n" : "\tnotl %%eax\n");
    break;
  case AST_LOGICAL_NOT:
    codegen_expr(expr->d.unary.operand);
    codegen_test(expr->d.unary.operand->type);
    /* Set %al to 1 if %eax was 0 */
    fprintf(out, "\tsete %%al\n");
    /* Zero-extend %al into %eax */
    fprintf(out, "\tmovzbl %%al, %%eax\n");
    break;
  case AST_PRE_INCREMENT:
  case AST_PRE_DECREMENT:
  case AST_POST_INCREMENT:
  case AST_POST_DECREMENT: {
    bool post =
        expr->kind == AST_POST_INCREMENT || expr->kind == AST_POST_DECREMENT;
    bool decrement =
        expr->kind == AST_PRE_DECREMENT || expr->kind == AST_POST_DECREMENT;
    int is_ptr = expr->type->kind == TYPE_PTR;
    bool wide = expr->type->size == 8;
    /* Pointers step by the pointee's size, integers by 1. */
    int step = is_ptr ? type_size(expr->type->base) : 1;
    codegen_addr(expr->d.unary.operand);
    codegen_load(expr->type, "%rcx");
    if (post) {
      /* Save the original value as the result. */
      fprintf(out, "\tpushq %%rcx\n");
      push_depth++;
    }
    /*
     * For _Bool, ++ always stores 1 and -- toggles between 0 and 1.
     */
    if (expr->type->kind == TYPE_BOOL)
      fprintf(out, decrement ? "\txorl $1, %%ecx\n" : "\tmovl $1, %%ecx\n");
    else
      fprintf(out, "\t%s%c $%d, %s\n", decrement ? "sub" : "add",
              wide ? 'q' : 'l', step, wide ? "%rcx" : "%ecx");
    codegen_store(expr->type);
    if (post) {
      fprintf(out, "\tpopq %%rax\n");
      push_depth--;
    } else {
      fprintf(out, "\tmovq %%rcx, %%rax\n");
      codegen_normalize(expr->type);
    }
    break;
  }
  default:
    fprintf(stderr, "unrecognized ast node\n");
    exit(1);
  }
  return;
}

static void codegen_stmt(const CodegenContext *ctx, AstNode *stmt) {
  switch (stmt->kind) {
  case AST_RETURN:
    if (stmt->d.ret.expr) {
      codegen_expr(stmt->d.ret.expr);
      codegen_return(ctx);
    }
    fprintf(out, "\tjmp .Lreturn.%d\n", ctx->ret_label);
    break;
  case AST_BREAK:
    if (ctx->break_label < 0) {
      fprintf(stderr, "break outside loop in codegen\n");
      exit(1);
    }
    fprintf(out, "\tjmp .L.end.%d\n", ctx->break_label);
    break;
  case AST_CONTINUE:
    if (ctx->continue_label < 0) {
      fprintf(stderr, "continue outside loop in codegen\n");
      exit(1);
    }
    fprintf(out, "\tjmp .L.continue.%d\n", ctx->continue_label);
    break;
  case AST_IF: {
    int seq = label_seq++;

    /* Jump to the else branch when the condition is zero. */
    codegen_expr(stmt->d.if_stmt.cond);
    codegen_test(stmt->d.if_stmt.cond->type);
    fprintf(out, "\tje .L.else.%d\n", seq);
    codegen_stmt(ctx, stmt->d.if_stmt.then_stmt);
    fprintf(out, "\tjmp .L.end.%d\n", seq);
    fprintf(out, ".L.else.%d:\n", seq);
    if (stmt->d.if_stmt.else_stmt)
      codegen_stmt(ctx, stmt->d.if_stmt.else_stmt);
    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_WHILE: {
    int seq = label_seq++;
    CodegenContext loop_ctx = *ctx;
    loop_ctx.break_label = seq;
    loop_ctx.continue_label = seq;

    /*
     * .L.continue.N coincides with the head: 'continue' re-tests the
     * condition.
     */
    fprintf(out, ".L.begin.%d:\n", seq);
    fprintf(out, ".L.continue.%d:\n", seq);
    codegen_expr(stmt->d.while_stmt.cond);
    codegen_test(stmt->d.while_stmt.cond->type);
    fprintf(out, "\tje .L.end.%d\n", seq);
    codegen_stmt(&loop_ctx, stmt->d.while_stmt.body);
    fprintf(out, "\tjmp .L.begin.%d\n", seq);
    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_FOR: {
    int seq = label_seq++;
    CodegenContext loop_ctx = *ctx;
    loop_ctx.break_label = seq;
    loop_ctx.continue_label = seq;

    if (stmt->d.for_stmt.init)
      codegen_stmt(ctx, stmt->d.for_stmt.init);
    fprintf(out, ".L.begin.%d:\n", seq);
    if (stmt->d.for_stmt.cond) {
      /* An omitted condition is a nonzero constant: skip the test. */
      codegen_expr(stmt->d.for_stmt.cond);
      codegen_test(stmt->d.for_stmt.cond->type);
      fprintf(out, "\tje .L.end.%d\n", seq);
    }
    codegen_stmt(&loop_ctx, stmt->d.for_stmt.body);
    /* 'continue' must skip to the post expression, not the condition. */
    fprintf(out, ".L.continue.%d:\n", seq);
    if (stmt->d.for_stmt.post)
      codegen_expr(stmt->d.for_stmt.post);
    fprintf(out, "\tjmp .L.begin.%d\n", seq);
    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_DO: {
    int seq = label_seq++;
    CodegenContext loop_ctx = *ctx;
    loop_ctx.break_label = seq;
    loop_ctx.continue_label = seq;

    /*
     * The test sits after the body, so the loop always runs at least once;
     * 'continue' jumps to the test and 'break' to the end label.
     */
    fprintf(out, ".L.begin.%d:\n", seq);
    codegen_stmt(&loop_ctx, stmt->d.do_stmt.body);
    fprintf(out, ".L.continue.%d:\n", seq);
    codegen_expr(stmt->d.do_stmt.cond);
    codegen_test(stmt->d.do_stmt.cond->type);
    fprintf(out, "\tjne .L.begin.%d\n", seq);
    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_GOTO:
    /*
     * User labels have function scope, but the assembler's symbol
     * namespace is file-wide, so the same label name in two functions
     * would collide. Prefixing with the function's return label number
     * keeps them distinct; the dot then also keeps them clear of the
     * generated '.L.begin.N' family.
     */
    fprintf(out, "\tjmp .L%d.%.*s\n", ctx->ret_label,
            stmt->d.goto_stmt.name.len, stmt->d.goto_stmt.name.start);
    break;
  case AST_LABEL:
    fprintf(out, ".L%d.%.*s:\n", ctx->ret_label, stmt->d.label_stmt.name.len,
            stmt->d.label_stmt.name.start);
    codegen_stmt(ctx, stmt->d.label_stmt.stmt);
    break;
  case AST_SWITCH: {
    int seq = label_seq++;
    CodegenContext switch_ctx = *ctx;
    CaseList *cl;
    AstNode *default_node = NULL;
    switch_ctx.break_label = seq;

    /*
     * Dispatch is a chain of compares and jumps over the cases collected
     * by the parser; a jump table can replace it once case densities make
     * that worthwhile.
     */
    codegen_expr(stmt->d.switch_stmt.cond);
    for (cl = stmt->d.switch_stmt.cases; cl; cl = cl->next) {
      cl->node->d.case_stmt.label = label_seq++;
      if (cl->node->d.case_stmt.is_default) {
        default_node = cl->node;
        continue;
      }
      if (stmt->d.switch_stmt.cond->type->size == 8) {
        fprintf(out, "\tmovabsq $%" PRId64 ", %%rcx\n",
                cl->node->d.case_stmt.val);
        fprintf(out, "\tcmpq %%rcx, %%rax\n");
      } else {
        fprintf(out, "\tcmpl $%" PRId64 ", %%eax\n", cl->node->d.case_stmt.val);
      }
      fprintf(out, "\tje .L.case.%d\n", cl->node->d.case_stmt.label);
    }
    if (default_node)
      fprintf(out, "\tjmp .L.default.%d\n", default_node->d.case_stmt.label);
    fprintf(out, "\tjmp .L.end.%d\n", seq);

    /* 'break' inside the body exits this switch, not any outer loop. */
    codegen_stmt(&switch_ctx, stmt->d.switch_stmt.body);

    fprintf(out, ".L.end.%d:\n", seq);
    break;
  }
  case AST_CASE:
    if (stmt->d.case_stmt.is_default)
      fprintf(out, ".L.default.%d:\n", stmt->d.case_stmt.label);
    else
      fprintf(out, ".L.case.%d:\n", stmt->d.case_stmt.label);
    codegen_stmt(ctx, stmt->d.case_stmt.stmt);
    break;
  case AST_DECL:
    if (stmt->d.decl.init)
      codegen_local_initializer(stmt->d.decl.init, stmt->d.decl.var->offset);
    break;
  case AST_EXPR_STMT:
    if (stmt->d.expr_stmt.expr)
      codegen_expr(stmt->d.expr_stmt.expr);
    break;
  case AST_BLOCK: {
    AstNode *cur;
    for (cur = stmt->d.block.first_stmt; cur; cur = cur->next)
      codegen_stmt(ctx, cur);
    break;
  }
  default:
    fprintf(stderr, "unknown AST node\n");
    exit(1);
  }
}

static void codegen_address_constant(AddressConstant *address) {
  AstNode *base = address->base;
  if (!base) {
    fprintf(out, "\t.quad %" PRIu64 "\n", (uint64_t)address->offset);
    return;
  }
  if (base->kind == AST_STRING_LITERAL) {
    int seq = codegen_string_literal(base);
    fprintf(out, "\t.quad .L.string.%d", seq);
  } else if (base->kind == AST_VAR) {
    Token name = base->d.variable.var->name;
    fprintf(out, "\t.quad %.*s", name.len, name.start);
  } else {
    fprintf(stderr, "invalid address constant in codegen\n");
    exit(1);
  }
  if (address->offset)
    fprintf(out, "%+" PRId64, address->offset);
  fprintf(out, "\n");
}

/*
 * String bytes supply the gaps between explicit character overrides.
 */
static bool initializer_range_nonzero(Initializer *init, int begin, int end) {
  int i;
  if (!init->expr || init->type->kind != TYPE_ARRAY)
    return false;
  if (end > init->expr->type->array_len)
    end = init->expr->type->array_len;
  for (i = begin; i < end; ++i)
    if (init->expr->d.string_literal.val[i])
      return true;
  return false;
}

static bool initializer_nonzero(Initializer *init) {
  Initializer *child;
  int offset = 0;
  if (!init)
    return false;
  if (init->type->kind == TYPE_PTR)
    return init->constant.address.base != NULL ||
           init->constant.address.offset != 0;
  if (is_integer(init->type))
    return init->constant.value != 0;
  for (child = init->children; child; child = child->next) {
    if (initializer_range_nonzero(init, offset, child->offset) ||
        initializer_nonzero(child))
      return true;
    offset = child->offset + type_size(child->type);
  }
  return initializer_range_nonzero(init, offset, type_size(init->type));
}

/*
 * Emit unoverridden string bytes or implicit zeros. Large gaps use .zero,
 * without constructing an in-memory image of the global object.
 */
static void codegen_initializer_range(Initializer *init, int begin, int end) {
  int length = 0;
  if (init->expr && init->type->kind == TYPE_ARRAY) {
    int string_end = init->expr->type->array_len;
    if (string_end > end)
      string_end = end;
    if (string_end > begin) {
      length = string_end - begin;
      codegen_bytes(init->expr->d.string_literal.val + begin, length);
    }
  }
  if (end - begin > length)
    fprintf(out, "\t.zero %d\n", end - begin - length);
}

static void codegen_global_initializer(Initializer *init) {
  Initializer *child;
  int offset = 0;
  if (init->type->kind == TYPE_PTR) {
    codegen_address_constant(&init->constant.address);
    return;
  }
  if (is_integer(init->type)) {
    const char *directive;
    switch (type_size(init->type)) {
    case 1:
      directive = ".byte";
      break;
    case 2:
      directive = ".short";
      break;
    case 4:
      directive = ".long";
      break;
    case 8:
      directive = ".quad";
      break;
    default:
      fprintf(stderr, "unsupported global initializer size\n");
      exit(1);
    }
    fprintf(out, "\t%s %" PRId64 "\n", directive, init->constant.value);
    return;
  }
  for (child = init->children; child; child = child->next) {
    codegen_initializer_range(init, offset, child->offset);
    codegen_global_initializer(child);
    offset = child->offset + type_size(child->type);
  }
  codegen_initializer_range(init, offset, type_size(init->type));
}

/*
 * Zero-initialized globals use .bss; nonzero initializers use .data.
 * Preserve the current section because objects can appear between functions.
 */
static void codegen_global_variable(Variable *var) {
  Token name = var->name;
  int size = type_size(var->type);
  bool nonzero = initializer_nonzero(var->initializer);
  fprintf(out, "\t.pushsection %s\n", nonzero ? ".data" : ".bss");
  fprintf(out, "\t.%s %.*s\n", var->is_static ? "local" : "globl", name.len,
          name.start);
  fprintf(out, "\t.type %.*s, @object\n", name.len, name.start);
  fprintf(out, "\t.size %.*s, %d\n", name.len, name.start, size);
  fprintf(out, "\t.balign %d\n", type_alignment(var->type));
  fprintf(out, "%.*s:\n", name.len, name.start);
  if (nonzero)
    codegen_global_initializer(var->initializer);
  else
    fprintf(out, "\t.zero %d\n", size);
  fprintf(out, "\t.popsection\n");
}

/*
 * Save every incoming register before copying stack parameters: a record copy
 * uses %rdi, %rsi and %rcx, which may still contain other parameter values.
 */
static void codegen_function_params(const AstNode *fn) {
  Variable *param;
  bool memory_return =
      return_in_memory(fn->d.function.declaration->return_type);
  /*
   * A hidden return-buffer pointer reserves the first argument register, %rdi.
   */
  int nregs = memory_return ? 1 : 0;
  int64_t stack_size = 0;
  if (memory_return)
    fprintf(out, "\tmovq %%rdi, -%d(%%rbp)\n", fn->d.function.return_offset);
  for (param = fn->d.function.params; param; param = param->next) {
    int reg = layout_argument(param->type, &nregs, &stack_size);
    int size = type_size(param->type);
    if (reg < 0)
      continue;
    if (is_record(param->type)) {
      codegen_store_bytes(argregs64[reg], param->offset, size < 8 ? size : 8);
      if (size > 8)
        codegen_store_bytes(argregs64[reg + 1], param->offset - 8, size - 8);
    } else if (size == 8) {
      fprintf(out, "\tmovq %s, -%d(%%rbp)\n", argregs64[reg], param->offset);
    } else if (size == 1) {
      fprintf(out, "\tmovb %s, -%d(%%rbp)\n", argregs8[reg], param->offset);
    } else if (size == 2) {
      fprintf(out, "\tmovw %s, -%d(%%rbp)\n", argregs16[reg], param->offset);
    } else {
      fprintf(out, "\tmovl %s, -%d(%%rbp)\n", argregs32[reg], param->offset);
    }
  }
  nregs = memory_return ? 1 : 0;
  stack_size = 0;
  for (param = fn->d.function.params; param; param = param->next) {
    int64_t offset = 16 + stack_size;
    int reg = layout_argument(param->type, &nregs, &stack_size);
    if (reg >= 0)
      continue;
    if (is_record(param->type)) {
      fprintf(out, "\tleaq %" PRId64 "(%%rbp), %%rcx\n", offset);
    } else {
      fprintf(out, "\tleaq %" PRId64 "(%%rbp), %%rax\n", offset);
      codegen_load(param->type, "%rcx");
    }
    fprintf(out, "\tleaq -%d(%%rbp), %%rax\n", param->offset);
    codegen_store(param->type);
  }
}

void codegen(const AstNode *ast, FILE *out_file) {
  const AstNode *decl;

  out = out_file;
  fprintf(out, "\t.text\n");

  /*
   * The translation unit contains global objects and function definitions.
   */
  for (decl = ast; decl; decl = decl->next) {
    if (decl->kind == AST_DECL) {
      codegen_global_variable(decl->d.decl.var);
      continue;
    }
    Function *func;
    Token name;
    int stack_size;
    CodegenContext ctx = {
        .function = decl,
        .break_label = -1,
        .continue_label = -1,
        .ret_label = label_seq++,
    };

    if (decl->kind != AST_FUNCTION) {
      fprintf(stderr, "expected function AST\n");
      exit(1);
    }

    func = decl->d.function.declaration;
    name = func->name;
    stack_size = (decl->d.function.stack_size + 15) / 16 * 16;
    fprintf(out, "\t.%s %.*s\n", func->is_static ? "local" : "globl", name.len,
            name.start);
    fprintf(out, "%.*s:\n", name.len, name.start);
    fprintf(out, "\tpushq %%rbp\n");
    fprintf(out, "\tmovq %%rsp, %%rbp\n");
    if (stack_size)
      fprintf(out, "\tsubq $%d, %%rsp\n", stack_size);

    codegen_function_params(decl);

    codegen_stmt(&ctx, decl->d.function.body);

    /* Reaching the end of the function returns zero. */
    fprintf(out, "\tmovl $0, %%eax\n");
    fprintf(out, ".Lreturn.%d:\n", ctx.ret_label);
    fprintf(out, "\tmovq %%rbp, %%rsp\n");
    fprintf(out, "\tpopq %%rbp\n");
    fprintf(out, "\tret\n");
  }

  fprintf(out, "\t.section .note.GNU-stack, \"\",@progbits\n");
}
