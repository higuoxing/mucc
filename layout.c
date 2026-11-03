/*
 * Stack and argument layout for the self-hosted C compiler
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

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#include "layout.h"
#include "type.h"

/*
 * Our supported scalars and naturally aligned records use INTEGER eightbytes.
 * Records larger than two eightbytes use MEMORY. Floating-point, vector and
 * packed record types will require additional ABI classes when introduced.
 */
int register_count(const Type *type) {
  if (type->kind == TYPE_VOID)
    return 0;
  if (!is_record(type))
    return 1;
  return type_size(type) > 16 ? 0 : (type_size(type) + 7) / 8;
}

bool return_in_memory(const Type *type) {
  return is_record(type) && register_count(type) == 0;
}

int layout_argument(const Type *type, int *nregs, int64_t *stack_size) {
  int count = register_count(type);
  /*
   * An argument must fit entirely in the remaining registers. A record that
   * does not fit leaves those registers available for subsequent arguments.
   */
  if (count && count <= 6 - *nregs) {
    int reg = *nregs;
    *nregs += count;
    return reg;
  }
  *stack_size += ((int64_t)type_size(type) + 7) / 8 * 8;
  return -1;
}

typedef struct {
  const char *filename;
  int size;
} StackLayout;

static void layout_error(StackLayout *layout, Token loc, const char *message)
    __attribute__((noreturn));

static void layout_error(StackLayout *layout, Token loc, const char *message) {
  fprintf(stderr, "%s:%d:%d: error: %s\n", layout->filename, loc.line, loc.col,
          message);
  exit(1);
}

static int layout_slot(StackLayout *layout, Type *type, Token loc) {
  int size = type_size(type);
  int alignment = type_alignment(type);
  int padding = (alignment - layout->size % alignment) % alignment;
  /*
   * Leave room for codegen to round the frame size to a multiple of 16.
   */
  if (size > INT_MAX - 15 - layout->size - padding)
    layout_error(layout, loc, "local variables exceed supported stack size");
  layout->size += padding + size;
  return layout->size;
}

/*
 * Aggregate conversions need storage for their values through the containing
 * full expression. Give each reachable conversion its own stack slot. sizeof
 * has already become a literal, so its operand allocates no temporary storage.
 */
static void layout_expr(StackLayout *layout, AstNode *expr) {
  if (!expr)
    return;
  switch (expr->kind) {
  case AST_VAR:
  case AST_INT_LITERAL:
  case AST_STRING_LITERAL:
    break;
  case AST_CAST:
    layout_expr(layout, expr->d.unary.operand);
    if (is_record(expr->type))
      expr->d.unary.offset = layout_slot(layout, expr->type, expr->loc);
    break;
  case AST_ADDR:
  case AST_DEREF:
  case AST_NEG:
  case AST_BITWISE_NOT:
  case AST_LOGICAL_NOT:
  case AST_PRE_INCREMENT:
  case AST_PRE_DECREMENT:
  case AST_POST_INCREMENT:
  case AST_POST_DECREMENT:
    layout_expr(layout, expr->d.unary.operand);
    break;
  case AST_MEMBER:
    layout_expr(layout, expr->d.member.base);
    break;
  case AST_CALL: {
    AstNode *arg;
    int nregs = return_in_memory(expr->type) ? 1 : 0;
    int64_t stack_size = 0;
    for (arg = expr->d.call.args; arg; arg = arg->next) {
      layout_expr(layout, arg);
      layout_argument(arg->type, &nregs, &stack_size);
    }
    if (stack_size + nregs * 8 > INT_MAX - 15)
      layout_error(layout, expr->loc,
                   "function arguments exceed supported stack size");
    if (is_record(expr->type))
      expr->d.call.offset = layout_slot(layout, expr->type, expr->loc);
    break;
  }
  case AST_CONDITIONAL:
    layout_expr(layout, expr->d.conditional.cond);
    layout_expr(layout, expr->d.conditional.then_expr);
    layout_expr(layout, expr->d.conditional.else_expr);
    break;
  case AST_COMPOUND_ASSIGN:
    layout_expr(layout, expr->d.compound_assign.lhs);
    layout_expr(layout, expr->d.compound_assign.rhs);
    break;
  case AST_ASSIGN:
  case AST_ADD:
  case AST_SUB:
  case AST_PTR_ADD:
  case AST_PTR_SUB:
  case AST_PTR_DIFF:
  case AST_MUL:
  case AST_DIV:
  case AST_MOD:
  case AST_LSHIFT:
  case AST_RSHIFT:
  case AST_BIT_AND:
  case AST_BIT_OR:
  case AST_BIT_XOR:
  case AST_EQ:
  case AST_NE:
  case AST_LT:
  case AST_LE:
  case AST_GT:
  case AST_GE:
  case AST_LOGICAL_AND:
  case AST_LOGICAL_OR:
  case AST_COMMA:
    layout_expr(layout, expr->d.binary.lhs);
    layout_expr(layout, expr->d.binary.rhs);
    break;
  default:
    layout_error(layout, expr->loc, "unexpected expression in stack layout");
  }
}

static void layout_initializer(StackLayout *layout, Initializer *init) {
  Initializer *child;
  if (!init)
    return;
  layout_expr(layout, init->expr);
  for (child = init->children; child; child = child->next)
    layout_initializer(layout, child);
}

/* Case-list entries refer to nodes already reached through the switch body. */
static void layout_stmt(StackLayout *layout, AstNode *stmt) {
  if (!stmt)
    return;
  switch (stmt->kind) {
  case AST_DECL:
    if (stmt->d.decl.var)
      stmt->d.decl.var->offset =
          layout_slot(layout, stmt->d.decl.var->type, stmt->d.decl.var->name);
    layout_initializer(layout, stmt->d.decl.init);
    break;
  case AST_EXPR_STMT:
    layout_expr(layout, stmt->d.expr_stmt.expr);
    break;
  case AST_RETURN:
    layout_expr(layout, stmt->d.ret.expr);
    break;
  case AST_BLOCK: {
    AstNode *cur;
    for (cur = stmt->d.block.first_stmt; cur; cur = cur->next)
      layout_stmt(layout, cur);
    break;
  }
  case AST_IF:
    layout_expr(layout, stmt->d.if_stmt.cond);
    layout_stmt(layout, stmt->d.if_stmt.then_stmt);
    layout_stmt(layout, stmt->d.if_stmt.else_stmt);
    break;
  case AST_WHILE:
    layout_expr(layout, stmt->d.while_stmt.cond);
    layout_stmt(layout, stmt->d.while_stmt.body);
    break;
  case AST_FOR:
    layout_stmt(layout, stmt->d.for_stmt.init);
    layout_expr(layout, stmt->d.for_stmt.cond);
    layout_expr(layout, stmt->d.for_stmt.post);
    layout_stmt(layout, stmt->d.for_stmt.body);
    break;
  case AST_DO:
    layout_stmt(layout, stmt->d.do_stmt.body);
    layout_expr(layout, stmt->d.do_stmt.cond);
    break;
  case AST_SWITCH:
    layout_expr(layout, stmt->d.switch_stmt.cond);
    layout_stmt(layout, stmt->d.switch_stmt.body);
    break;
  case AST_CASE:
    layout_stmt(layout, stmt->d.case_stmt.stmt);
    break;
  case AST_LABEL:
    layout_stmt(layout, stmt->d.label_stmt.stmt);
    break;
  default:
    break;
  }
}

void assign_stack_offsets(const char *filename, AstNode *ast) {
  AstNode *fn;
  for (fn = ast; fn; fn = fn->next) {
    Variable *param;
    StackLayout layout = {.filename = filename};
    bool memory_return;
    int nregs;
    int64_t stack_size = 0;
    if (fn->kind != AST_FUNCTION)
      continue;

    memory_return = return_in_memory(fn->d.function.declaration->return_type);
    nregs = memory_return ? 1 : 0;
    if (memory_return)
      fn->d.function.return_offset =
          layout_slot(&layout, &builtin_type_long, fn->loc);
    /*
     * Scalars retain eight-byte homes; aggregate parameters need their full
     * object size. Every parameter has its own writable local copy.
     */
    for (param = fn->d.function.params; param; param = param->next) {
      Type *slot_type =
          is_record(param->type) ? param->type : &builtin_type_long;
      param->offset = layout_slot(&layout, slot_type, param->name);
      layout_argument(param->type, &nregs, &stack_size);
      if (stack_size > INT_MAX - 16)
        layout_error(&layout, param->name,
                     "function parameters exceed supported stack size");
    }

    layout_stmt(&layout, fn->d.function.body);
    fn->d.function.stack_size = layout.size;
  }
}
