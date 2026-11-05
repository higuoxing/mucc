/*
 * Parser for the self-hosted C compiler
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

#ifndef _PARSER_H_
#define _PARSER_H_

#include "error.h"
#include "preprocessor.h"
#include "type.h"

typedef struct AstNode AstNode;
typedef struct Initializer Initializer;

typedef enum {
  STORAGE_NONE,
  STORAGE_TYPEDEF,
  STORAGE_STATIC,
  STORAGE_EXTERN,
} StorageClass;

/*
 * An address constant names a global object or string literal plus a byte
 * offset. Without a base, offset holds absolute pointer bits (zero for null).
 */
typedef struct {
  AstNode *base;
  int64_t offset;
} AddressConstant;

typedef struct Designator {
  Token loc;    /* The '.' or '[' token. */
  Token member; /* Member name for '.', unused for '['. */
  AstNode *index;
  struct Designator *next;
} Designator;

/*
 * Parsing records an expression or a brace list with optional designators.
 * Sema uses the same representation to build checked subobjects for layout
 * and codegen. Lists zero omitted subobjects; intermediate nodes introduced
 * by designators preserve their enclosing initialization. Child offsets are
 * relative to their parent; index is an array index or a member's declaration
 * order. A whole-object expression may be followed by child overrides.
 */
struct Initializer {
  Token loc;
  Type *type; /* Destination type for checked nodes. */
  AstNode *expr;
  Initializer *children;
  Initializer *next;
  Designator *designators; /* Source syntax only; absent from checked nodes. */
  int index;
  int offset;
  bool zero_fill; /* Initialize the whole subobject before applying children. */
  /*
   * Converted static scalar values, including signed values or unsigned bits.
   */
  union {
    int64_t value;
    AddressConstant address;
  } constant;
};

/* Struct, union and enum tags share a namespace and follow block scope. */
typedef struct Tag {
  Token name;
  Type *type;
  int scope_depth;
  bool is_defining;
  struct Tag *next;
} Tag;

typedef struct Variable {
  Token name;
  Type *type;
  int offset; /* Positive distance below %rbp for stack variables. */
  bool is_global;
  bool is_static;  /* Internal linkage for file-scope objects. */
  bool is_defined; /* Global storage is provided by this translation unit. */
  bool is_parameter;
  Initializer *initializer;
  struct Variable *next; /* Parameter list, in declaration order. */
} Variable;

typedef struct Enum {
  Token name;
  int value;
} Enum;

/*
 * Labels have function scope (C11 6.2.1), so this table is not restored
 * when a block ends, unlike ordinary identifier bindings.
 */
typedef struct Label {
  Token name;
  struct Label *next;
} Label;

/*
 * A 'goto' whose target is validated after the function body is parsed,
 * since labels may be declared after the goto that uses them.
 */
typedef struct GotoRef {
  Token name; /* Target label. */
  Token loc;  /* The 'goto' keyword, for diagnostics. */
  struct GotoRef *next;
} GotoRef;

/*
 * Function declarations refer to a shared descriptor across redeclarations.
 * In C11, f() doesn't supply a prototype (6.7.6.3).
 */
typedef struct Function {
  Token name;
  Type *return_type;
  int nparams;
  Type **param_types;
  int has_prototype; /* 0 for a declaration with an empty argument list. */
  bool is_variadic;  /* Parameters end with '...'; nparams counts fixed ones. */
  int is_defined;    /* 1 once a definition has been seen. */
  bool is_static;    /* Internal linkage, retained across redeclarations. */
} Function;

typedef enum {
  SYMBOL_VARIABLE,
  SYMBOL_FUNCTION,
  SYMBOL_TYPEDEF,
  SYMBOL_ENUMERATOR,
} SymbolKind;

/*
 * A symbol can represent a variable, function, typedef name, or enumerator.
 */
typedef struct Symbol {
  Token name;
  SymbolKind kind;
  int scope_depth;
  union {
    Variable *variable;
    Function *function;
    Type *typedef_type;
    Enum *enumerator;
  } d;
  struct Symbol *next;
} Symbol;

/*
 * A function call whose argument count is checked against a visible
 * prototype or later compatible definition.
 */
typedef struct CallRef {
  Token name; /* Called function. */
  Token loc;  /* The callee identifier, for diagnostics. */
  int nargs;
  AstNode *call;
  struct CallRef *next;
} CallRef;

/*
 * The case labels of one switch, attached to its AST_SWITCH node for
 * codegen's dispatch. Order in the list is not significant.
 */
typedef struct CaseList {
  struct AstNode *node; /* AST_CASE */
  struct CaseList *next;
} CaseList;

typedef struct {
  Preprocessor pp;
  Token previous; /* Last consumed token, for missing-token diagnostics. */
  Token current;
  Token lookahead;

  Symbol *symbols;
  Tag *tags;
  Label *labels;
  GotoRef *goto_refs;
  Function *current_function;
  Variable *last_parameter; /* Last fixed parameter of the current function. */
  CallRef *call_refs;
  /*
   * The innermost switch being parsed, or NULL; 'case' and 'default' are
   * valid only inside its body, and 'break' may target it.
   */
  AstNode *current_switch;
  int scope_depth;
  int loop_depth;
} Parser;

typedef enum {
  AST_ADD,
  AST_ADDR,
  AST_ASSIGN,
  AST_BIT_AND,
  AST_BIT_OR,
  AST_BIT_XOR,
  AST_BITWISE_NOT,
  AST_BLOCK,
  AST_BREAK,
  AST_CALL,
  AST_CASE,
  AST_CAST,
  AST_COMMA,
  AST_COMPOUND_ASSIGN,
  AST_COMPOUND_LITERAL,
  AST_CONDITIONAL,
  AST_CONTINUE,
  AST_DECL,
  AST_DEREF,
  AST_DIV,
  AST_DO,
  AST_EQ,
  AST_EXPR_STMT,
  AST_FOR,
  AST_FUNCTION,
  AST_GE,
  AST_GOTO,
  AST_GT,
  AST_IF,
  AST_INT_LITERAL,
  AST_LABEL,
  AST_LE,
  AST_LOGICAL_AND,
  AST_LOGICAL_NOT,
  AST_LOGICAL_OR,
  AST_LSHIFT,
  AST_LT,
  AST_MEMBER,
  AST_MOD,
  AST_MUL,
  AST_NE,
  AST_NEG,
  AST_POST_DECREMENT,
  AST_PTR_ADD,
  AST_PTR_DIFF,
  AST_PTR_SUB,
  AST_POST_INCREMENT,
  AST_PRE_DECREMENT,
  AST_PRE_INCREMENT,
  AST_RETURN,
  AST_RSHIFT,
  AST_STRING_LITERAL,
  AST_SUB,
  AST_SWITCH,
  AST_VAR,
  AST_VA_START,
  AST_VA_ARG,
  AST_VA_END,
  AST_VA_COPY,
  AST_WHILE,
} AstKind;

typedef struct AstNode {
  AstKind kind;
  Type *type; /* Inferred expression type. */
  Token loc;
  struct AstNode *next; /* Statements or external declarations. */
  union {
    struct {
      Function
          *declaration; /* Shared type and linkage across redeclarations. */
      struct AstNode *body;
      /*
       * Parameters in declaration order. This list is retained for
       * codegen independently of their scope-bound symbol entries.
       */
      struct Variable *params;
      int stack_size;     /* Assigned by stack layout after parsing. */
      int return_offset;  /* Saved hidden result pointer for a MEMORY return. */
      int va_area_offset; /* Register save area, below %rbp. */
      int va_gp_offset;   /* First unnamed GP register's byte offset. */
      int va_stack_offset; /* First unnamed stack argument, above %rbp. */
    } function;

    struct {
      struct AstNode *first_stmt;
    } block;

    struct {
      struct AstNode *cond;
      struct AstNode *then_stmt;
      struct AstNode *else_stmt; /* NULL if there is no 'else' clause. */
    } if_stmt;

    struct {
      struct AstNode *cond;
      struct AstNode *body;
    } while_stmt;

    struct {
      struct AstNode *init; /* Decl or expression-statement, NULL if omitted. */
      struct AstNode
          *cond; /* NULL if omitted (a nonzero constant, 6.8.5.3p2). */
      struct AstNode *post; /* Expression, NULL if omitted. */
      struct AstNode *body;
    } for_stmt;

    struct {
      struct AstNode *body;
      struct AstNode *cond;
    } do_stmt;

    struct {
      Token name;
    } goto_stmt;

    struct {
      Token name;
      struct AstNode *stmt;
    } label_stmt;

    struct {
      struct AstNode *cond;
      struct AstNode *body;
      /*
       * The case and default nodes still sit in the body's statement
       * chain (their position matters for fallthrough); this list is for
       * codegen's dispatch. The default case, if any, is the entry whose
       * node has is_default set.
       */
      struct CaseList *cases;
    } switch_stmt;

    struct {
      int64_t val; /* Meaningless when is_default is set. */
      struct AstNode *stmt;
      int label;      /* Dispatch label number, assigned by codegen. */
      int is_default; /* 1 for 'default:', 0 for 'case'. */
    } case_stmt;

    struct {
      Function *function;
      struct AstNode *args; /* First argument expression, or NULL. */
      int offset; /* Stack storage for an aggregate result, set by layout. */
    } call;

    struct {
      struct AstNode *cond;
      struct AstNode *then_expr;
      struct AstNode *else_expr;
    } conditional;

    struct {
      struct AstNode *expr;
    } ret;

    struct {
      Variable *var;
      Initializer *init;
    } decl;

    struct {
      struct AstNode *expr;
    } expr_stmt;

    struct {
      Variable *var; /* Named object or compound literal storage. */
    } variable;

    struct {
      uint64_t val;
    } int_literal;

    struct {
      unsigned char
          *val; /* Decoded bytes; type->array_len includes final zero. */
    } string_literal;

    struct {
      struct AstNode *operand;
      int offset; /* Stack slot for an aggregate AST_CAST value, set by layout.
                   */
    } unary;

    struct {
      struct AstNode *base; /* Struct or union; arrow uses AST_DEREF. */
      Member *member;
    } member;

    struct {
      struct AstNode *lhs;
      struct AstNode *rhs;
    } binary;

    struct {
      struct AstNode *lhs;
      struct AstNode *rhs; /* Converted right operand. */
      AstKind op; /* Typed integer operation or AST_PTR_ADD/AST_PTR_SUB. */
      Type *operation_type; /* Type before conversion back to lhs->type. */
    } compound_assign;
  } d;
} AstNode;

extern AstNode *parse_translation_unit(const SourceFile *file,
                                       const Vector *include_paths);

#endif
