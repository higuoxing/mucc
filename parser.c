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

#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "builtins.h"
#include "lexer.h"
#include "parser.h"
#include "sema.h"
#include "type.h"
#include "vector.h"

static AstNode *new_ast_node(Parser *p, AstKind kind);
static AstNode *new_expr(Parser *p, AstKind kind, Type *type);
static void reset_function_state(Parser *p);
static void parser_advance(Parser *p);
static AstNode *parse_assignment(Parser *p);
static AstNode *parse_expression(Parser *p);
static AstNode *parse_condition(Parser *p);
static AstNode *parse_conditional(Parser *p);
static AstNode *parse_cast(Parser *p);
static AstNode *parse_unary(Parser *p);
static AstNode *parse_call_expr(Parser *p, Function *func);
static AstNode *parse_postfix(Parser *p);
static AstNode *parse_postfix_suffix(Parser *p, AstNode *expr);
static AstNode *parse_compound_literal(Parser *p, Type *type, Token loc);
static Initializer *parse_initializer(Parser *p);
static AstNode *parse_primary(Parser *p);
static AstNode *parse_string_literal(Parser *p);
static AstNode *parse_decl(Parser *p, bool allow_typedef);
static AstNode *parse_return_stmt(Parser *p);
static AstNode *parse_if_stmt(Parser *p);
static AstNode *parse_while_stmt(Parser *p);
static AstNode *parse_for_stmt(Parser *p);
static AstNode *parse_do_stmt(Parser *p);
static AstNode *parse_break_stmt(Parser *p);
static AstNode *parse_continue_stmt(Parser *p);
static AstNode *parse_goto_stmt(Parser *p);
static AstNode *parse_label_stmt(Parser *p);
static AstNode *parse_switch_stmt(Parser *p);
static AstNode *parse_case_stmt(Parser *p);
static AstNode *parse_default_stmt(Parser *p);
static AstNode *parse_stmt(Parser *p, bool allow_decl);
static AstNode *parse_compound_stmt(Parser *p);
static AstNode *parse_block(Parser *p);
static AstNode *parse_external_declaration(Parser *p);
static Type *parse_declspecs(Parser *p, StorageClass *storage_class,
                             bool *anonymous_record);
static AstNode *parse_typedef_declarators(Parser *p, Type *base);
static Type *parse_declarator(Parser *p, Type *type, Token *name);
static Type *parse_type_name(Parser *p);

static bool is_declspec(Parser *p, Token token) {
  TokenKind kind = token.kind;
  if (kind == TOKEN_IDENTIFIER) {
    Symbol *sym = find_symbol(p, token);
    return sym && sym->kind == SYMBOL_TYPEDEF;
  }
  return kind == TOKEN_TYPEDEF || kind == TOKEN_STATIC ||
         kind == TOKEN_EXTERN || kind == TOKEN_CONST || kind == TOKEN_BOOL ||
         kind == TOKEN_CHAR || kind == TOKEN_SHORT || kind == TOKEN_INT ||
         kind == TOKEN_LONG || kind == TOKEN_UNSIGNED || kind == TOKEN_VOID ||
         kind == TOKEN_STRUCT || kind == TOKEN_UNION || kind == TOKEN_ENUM;
}

/* assignment-operator: = += -= *= /= %= <<= >>= &= ^= |=  (C11 6.5.16) */
static bool is_assignment_op(TokenKind ty) {
  return ty == TOKEN_ASSIGN || ty == TOKEN_PLUS_EQ || ty == TOKEN_MINUS_EQ ||
         ty == TOKEN_STAR_EQ || ty == TOKEN_SLASH_EQ ||
         ty == TOKEN_PERCENT_EQ || ty == TOKEN_LSHIFT_EQ ||
         ty == TOKEN_RSHIFT_EQ || ty == TOKEN_BIT_AND_EQ ||
         ty == TOKEN_BIT_XOR_EQ || ty == TOKEN_BIT_OR_EQ;
}

static AstNode *new_ast_node(Parser *p, AstKind kind) {
  AstNode *node;
  node = calloc(1, sizeof(AstNode));
  if (!node)
    error_at(p->current, "out of memory");
  node->kind = kind;
  node->loc = p->current;
  node->type = &builtin_type_void;
  return node;
}

static AstNode *new_expr(Parser *p, AstKind kind, Type *type) {
  AstNode *node = new_ast_node(p, kind);
  node->type = type;
  return node;
}

static void parser_advance(Parser *p) {
  p->previous = p->current;
  p->current = p->lookahead;
  p->lookahead = pp_next_token(&p->pp);
}

static void enter_scope(Parser *p) { ++p->scope_depth; }

/*
 * Scope exit restores the outer bindings. File-scope function symbols remain
 * visible even when they were added while parsing parameters at depth 1.
 */
static void leave_scope(Parser *p) {
  while (p->symbols && p->symbols->scope_depth == p->scope_depth)
    p->symbols = p->symbols->next;
  while (p->tags && p->tags->scope_depth == p->scope_depth)
    p->tags = p->tags->next;
  --p->scope_depth;
}

static void reset_function_state(Parser *p) {
  p->labels = NULL;
  p->goto_refs = NULL;
  p->current_switch = NULL;
  p->current_function = NULL;
  p->last_parameter = NULL;
  p->scope_depth = 0;
  p->loop_depth = 0;
}

static void parser_init(Parser *p, const SourceFile *file,
                        const Vector *include_paths) {
  p->tags = NULL;
  p->symbols = NULL;
  p->labels = NULL;
  p->goto_refs = NULL;
  p->call_refs = NULL;
  p->current_switch = NULL;
  p->current_function = NULL;
  p->last_parameter = NULL;
  p->scope_depth = 0;
  p->loop_depth = 0;
  pp_init(&p->pp, file, include_paths);
  p->previous = (Token){0};
  p->current = pp_next_token(&p->pp);
  p->lookahead = pp_next_token(&p->pp);
  declare_builtins(p);
}

static void parse_expect(Parser *p, TokenKind t, const char *msg) {
  if (p->current.kind != t) {
    error_at(p->current, "%s", msg);
  }

  parser_advance(p);
}

/*
 * A missing statement terminator belongs immediately after the last token,
 * even when the next token is on another line or follows a comment.
 * Semicolons separating for clauses still use parse_expect at the next token.
 */
static Token semicolon_at(Parser *p) {
  /* Zero-width, just past the previous token: where the ';' should have been.
   */
  Token loc = p->previous;
  loc.start += loc.len;
  loc.col += loc.len;
  loc.len = 0;
  return loc;
}

static void parse_semicolon(Parser *p) {
  if (p->current.kind != TOKEN_SEMICOLON)
    error_at(semicolon_at(p), "expect ';'");
  parser_advance(p);
}

/*
 * cast-expression:
 *   unary-expression
 *   '(' type-name ')' cast-expression
 * (C11 6.5.4)
 *
 * A visible typedef name distinguishes a type name from a grouped expression.
 * A brace list after the type name starts a compound literal instead of a cast.
 */
static AstNode *parse_cast(Parser *p) {
  if (p->current.kind == TOKEN_LPAREN && is_declspec(p, p->lookahead)) {
    Token loc = p->current;
    Type *type;
    parser_advance(p);
    type = parse_type_name(p);
    parse_expect(p, TOKEN_RPAREN, "expect ')'");
    if (p->current.kind == TOKEN_LBRACE)
      return parse_postfix_suffix(p, parse_compound_literal(p, type, loc));
    return sema_cast(type, parse_cast(p), loc);
  }
  return parse_unary(p);
}

/*
 * unary-expression:
 *   '-' cast-expression | '~' cast-expression | '!' cast-expression
 *   '++' unary-expression | '--' unary-expression
 *   '&' cast-expression | '*' cast-expression
 *   'sizeof' unary-expression | 'sizeof' '(' type-name ')'
 *   postfix-expression
 */
static AstNode *parse_unary(Parser *p) {
  if (p->current.kind == TOKEN_SIZEOF) {
    Token loc = p->current;
    Type *type;
    parser_advance(p);
    if (p->current.kind == TOKEN_LPAREN && is_declspec(p, p->lookahead)) {
      Token operand_loc = p->current;
      parser_advance(p);
      type = parse_type_name(p);
      parse_expect(p, TOKEN_RPAREN, "expect ')'");
      if (p->current.kind == TOKEN_LBRACE)
        type = parse_postfix_suffix(
                   p, parse_compound_literal(p, type, operand_loc))
                   ->type;
    } else {
      type = parse_unary(p)->type;
    }
    return sema_sizeof(type, loc);
  }
  if (p->current.kind == TOKEN_MINUS || p->current.kind == TOKEN_TILDE ||
      p->current.kind == TOKEN_BANG || p->current.kind == TOKEN_PLUS_PLUS ||
      p->current.kind == TOKEN_MINUS_MINUS ||
      p->current.kind == TOKEN_BIT_AND || p->current.kind == TOKEN_STAR) {
    AstNode *operand;
    AstKind op;
    Token op_tok;

    switch (p->current.kind) {
    case TOKEN_MINUS:
      op = AST_NEG;
      break;
    case TOKEN_TILDE:
      op = AST_BITWISE_NOT;
      break;
    case TOKEN_BANG:
      op = AST_LOGICAL_NOT;
      break;
    case TOKEN_PLUS_PLUS:
      op = AST_PRE_INCREMENT;
      break;
    case TOKEN_MINUS_MINUS:
      op = AST_PRE_DECREMENT;
      break;
    case TOKEN_BIT_AND:
      op = AST_ADDR;
      break;
    case TOKEN_STAR:
      op = AST_DEREF;
      break;
    default:
      fprintf(stderr, "unreachable %s:%d", __FILE__, __LINE__);
      exit(1);
    }

    /* Consume '-' or '~' or '!' or '++' or '--' or '&' or '*' */
    op_tok = p->current;
    parser_advance(p);
    operand = op == AST_PRE_INCREMENT || op == AST_PRE_DECREMENT
                  ? parse_unary(p)
                  : parse_cast(p);

    return sema_unary(op, operand, op_tok);
  }

  return parse_postfix(p);
}

static AstNode *parse_compound_literal(Parser *p, Type *type, Token loc) {
  if (p->current.kind != TOKEN_LBRACE)
    error_at(p->current, "expect '{'");
  return sema_compound_literal(p, type, parse_initializer(p), loc);
}

/*
 * postfix-expression:
 *   identifier '(' argument-expression-list_opt ')'
 */
static AstNode *parse_call_expr(Parser *p, Function *func) {
  AstNode *call;
  CallRef *ref;
  int nargs = 0;

  ref = (CallRef *)calloc(1, sizeof(CallRef));
  if (!ref)
    error_at(p->current, "out of memory");
  ref->name = p->current;
  ref->loc = p->current;
  ref->next = p->call_refs;
  p->call_refs = ref;

  call = new_expr(p, AST_CALL, unqualified_type(func->return_type));
  call->d.call.function = func;
  ref->call = call;
  /* Consume the function name. */
  parser_advance(p);
  parse_expect(p, TOKEN_LPAREN, "expect '('");

  if (p->current.kind != TOKEN_RPAREN) {
    AstNode **tail = &call->d.call.args;

    for (;;) {
      *tail = parse_assignment(p);
      tail = &(*tail)->next;
      nargs++;
      if (p->current.kind == TOKEN_COMMA) {
        parser_advance(p);
        continue;
      }
      break;
    }
  }
  parse_expect(p, TOKEN_RPAREN, "expect ')'");

  ref->nargs = nargs;
  sema_check_call(p, func, call, nargs);
  return call;
}

/*
 * va_arg takes a type name, rather than an expression, as its second operand.
 * The other builtins take one or two assignment expressions like a call.
 */
static AstNode *parse_builtin_va(Parser *p, AstKind kind) {
  Token loc = p->current;
  AstNode *first;
  AstNode *second = NULL;
  Type *type = &builtin_type_void;
  parser_advance(p);
  parse_expect(p, TOKEN_LPAREN, "expect '('");
  first = parse_assignment(p);
  if (kind != AST_VA_END) {
    parse_expect(p, TOKEN_COMMA, "expect ','");
    if (kind == AST_VA_ARG)
      type = parse_type_name(p);
    else
      second = parse_assignment(p);
  }
  parse_expect(p, TOKEN_RPAREN, "expect ')'");
  return sema_builtin_va(p, kind, first, second, type, loc);
}

/*
 * postfix-expression:
 *   primary-expression
 *   '(' type-name ')' '{' initializer-list ','_opt '}'
 *   identifier '(' argument-expression-list_opt ')'
 *   postfix-expression '[' expression ']'
 *   postfix-expression '.' identifier
 *   postfix-expression '->' identifier
 *   postfix-expression '++' | postfix-expression '--'
 */
static AstNode *parse_postfix(Parser *p) {
  AstNode *left;

  if (p->current.kind == TOKEN_LPAREN && is_declspec(p, p->lookahead)) {
    Token loc = p->current;
    Type *type;
    parser_advance(p);
    type = parse_type_name(p);
    parse_expect(p, TOKEN_RPAREN, "expect ')'");
    left = parse_compound_literal(p, type, loc);
  } else if (p->current.kind == TOKEN_IDENTIFIER &&
             p->lookahead.kind == TOKEN_LPAREN) {
    AstKind builtin = builtin_kind(p->current);
    if (builtin != AST_CALL)
      return parse_postfix_suffix(p, parse_builtin_va(p, builtin));
    Symbol *sym = find_symbol(p, p->current);
    if (!sym)
      error_at(p->current, "function '%.*s' not declared", p->current.len,
               p->current.start);
    if (sym->kind == SYMBOL_TYPEDEF)
      error_at(p->current, "typedef name is not an expression");
    if (sym->kind != SYMBOL_FUNCTION)
      error_at(p->current, "called object is not a function");
    left = parse_call_expr(p, sym->d.function);
  } else {
    left = parse_primary(p);
  }
  return parse_postfix_suffix(p, left);
}

static AstNode *parse_postfix_suffix(Parser *p, AstNode *left) {
  while (p->current.kind == TOKEN_PLUS_PLUS ||
         p->current.kind == TOKEN_MINUS_MINUS ||
         p->current.kind == TOKEN_LBRACKET || p->current.kind == TOKEN_DOT ||
         p->current.kind == TOKEN_ARROW) {
    Token op = p->current;
    if (op.kind == TOKEN_DOT || op.kind == TOKEN_ARROW) {
      Token name;
      parser_advance(p);
      if (p->current.kind != TOKEN_IDENTIFIER)
        error_at(p->current, "expect member name");
      name = p->current;
      parser_advance(p);
      left = sema_member(left, op, name);
      continue;
    }
    if (op.kind == TOKEN_LBRACKET) {
      AstNode *index;
      parser_advance(p);
      index = parse_expression(p);
      parse_expect(p, TOKEN_RBRACKET, "expect ']'");
      left = sema_subscript(p, left, index, op);
      continue;
    }
    AstKind kind =
        op.kind == TOKEN_PLUS_PLUS ? AST_POST_INCREMENT : AST_POST_DECREMENT;
    parser_advance(p);
    left = sema_unary(kind, left, op);
  }

  return left;
}

/*
 * Concatenate adjacent string tokens (C11 5.1.1.2, translation phase 6).
 * Keep embedded zeros, append one final terminator, and transfer the combined
 * buffer to AST while retaining the first token's source location.
 */
static AstNode *parse_string_literal(Parser *p) {
  Token literal = p->current;
  Vector bytes;
  unsigned char terminator = 0;
  vector_init(&bytes, sizeof(unsigned char));
  do {
    Token next = p->current;
    if (bytes.len > (size_t)(INT_MAX - next.d.string_literal.len))
      error_at(literal, "string literal is too long");
    if (!vector_append(&bytes, next.d.string_literal.val,
                       (size_t)next.d.string_literal.len - 1))
      error_at(literal, "out of memory");
    free(next.d.string_literal.val);
    parser_advance(p);
  } while (p->current.kind == TOKEN_STRING_LITERAL);
  if (!vector_push(&bytes, &terminator))
    error_at(literal, "out of memory");
  literal.d.string_literal.len = (int)bytes.len;
  literal.d.string_literal.val = vector_release(&bytes);
  return sema_string_literal(literal);
}

/*
 * primary-expression:
 *   integer-constant | character-constant | string-literal
 *   '(' expression ')' | identifier
 */
static AstNode *parse_primary(Parser *p) {
  if (p->current.kind == TOKEN_STRING_LITERAL)
    return parse_string_literal(p);

  if (p->current.kind == TOKEN_INT_LITERAL) {
    AstNode *expr;
    expr = sema_integer_literal(p->current);

    /* Consume the integer or character constant. */
    parser_advance(p);
    return expr;
  }

  if (p->current.kind == TOKEN_LPAREN) {
    AstNode *expr;
    /* Consume '(' */
    parser_advance(p);
    expr = parse_expression(p);
    parse_expect(p, TOKEN_RPAREN, "expect ')'");
    return expr;
  }

  if (p->current.kind == TOKEN_IDENTIFIER) {
    AstNode *expr;
    Symbol *sym = find_symbol(p, p->current);
    if (!sym)
      error_at(p->current, "undeclared identifier");
    if (sym->kind == SYMBOL_TYPEDEF)
      error_at(p->current, "typedef name is not an expression");
    if (sym->kind == SYMBOL_ENUMERATOR) {
      expr = sema_enumerator_expr(sym->d.enumerator, p->current);
      parser_advance(p);
      return expr;
    }
    if (sym->kind != SYMBOL_VARIABLE)
      error_at(p->current, "undeclared identifier");
    expr = new_expr(p, AST_VAR, sym->d.variable->type);
    expr->d.variable.var = sym->d.variable;
    /* Consume identifier. */
    parser_advance(p);
    return expr;
  }

  error_at(p->current, "expect expr");
  return NULL;
}

static Tag *find_tag(Parser *p, Token name, bool current_scope) {
  Tag *tag;
  for (tag = p->tags; tag; tag = tag->next) {
    if (same_identifier(tag->name, name)) {
      if (!current_scope || tag->scope_depth == p->scope_depth)
        return tag;
    }
  }
  return NULL;
}

static Tag *declare_tag(Parser *p, Token name, Type *type) {
  Tag *tag = calloc(1, sizeof(Tag));
  if (!tag)
    error_at(name, "out of memory");
  tag->name = name;
  tag->type = type;
  tag->scope_depth = p->scope_depth;
  tag->next = p->tags;
  p->tags = tag;
  return tag;
}

/*
 * enum-specifier:
 *   'enum' identifier
 *   'enum' identifier_opt '{' enumerator (',' enumerator)* ','_opt '}'
 * enumerator: identifier ('=' constant-expression)_opt
 * (C11 6.7.2.2; enum tags must be defined before use without a definition.)
 */
static Type *parse_enum_specifier(Parser *p) {
  Token loc = p->current;
  Token name = {0};
  Tag *tag = NULL;
  Type *type;
  int64_t next_value = 0;

  /* Consume 'enum' */
  parser_advance(p);
  if (p->current.kind == TOKEN_IDENTIFIER) {
    name = p->current;
    parser_advance(p);
    tag = find_tag(p, name, p->current.kind == TOKEN_LBRACE);
  } else if (p->current.kind != TOKEN_LBRACE) {
    error_at(p->current, "expect enum tag or '{'");
  }
  if (tag && tag->type->kind != TYPE_ENUM)
    error_at(name, "tag '%.*s' declared as a different kind", name.len,
             name.start);
  if (p->current.kind != TOKEN_LBRACE) {
    if (!tag || tag->type->size < 0)
      error_at(name, "enum '%.*s' is not defined", name.len, name.start);
    return tag->type;
  }
  if (tag) {
    if (tag->type->size >= 0 || tag->is_defining)
      error_at(name, "redefinition of enum '%.*s'", name.len, name.start);
    type = tag->type;
  } else {
    type = enum_type();
    if (!type)
      error_at(loc, "out of memory");
    if (name.kind == TOKEN_IDENTIFIER)
      tag = declare_tag(p, name, type);
  }
  if (tag)
    tag->is_defining = true;
  parser_advance(p);
  for (;;) {
    Token enumerator_name = p->current;
    AstNode *initializer = NULL;
    Enum *enumerator;
    parse_expect(p, TOKEN_IDENTIFIER, "expect enumerator name");
    if (p->current.kind == TOKEN_ASSIGN) {
      parser_advance(p);
      initializer = parse_conditional(p);
    }
    enumerator =
        declare_enumerator(p, enumerator_name, initializer, next_value);
    next_value = (int64_t)enumerator->value + 1;
    if (p->current.kind != TOKEN_COMMA)
      break;
    parser_advance(p);
    if (p->current.kind == TOKEN_RBRACE)
      break;
  }
  parse_expect(p, TOKEN_RBRACE, "expect '}'");
  type->size = type->base->size;
  if (tag)
    tag->is_defining = false;
  return type;
}

/*
 * Check names promoted from anonymous members as well as ordinary members.
 */
static void check_member_names(Parser *p, Type *type, Member *member) {
  if (member->name.kind == TOKEN_IDENTIFIER) {
    if (find_member(type, member->name))
      error_at(member->name, "duplicate %s member",
               type->kind == TYPE_STRUCT ? "struct" : "union");
  } else {
    Member *inner;
    for (inner = unqualified_type(member->type)->members; inner;
         inner = inner->next)
      check_member_names(p, type, inner);
  }
}

/*
 * Parse one member declarator and update the record's size and alignment.
 * The caller links the returned member before parsing the next declarator.
 */
static Member *parse_record_member(Parser *p, Type *type, Type *base, int *size,
                                   bool anonymous) {
  Token name = p->current;
  Type *member_type = anonymous ? base : parse_declarator(p, base, &name);
  Member *member;
  int alignment;
  int padding = 0;

  if (!anonymous && name.kind != TOKEN_IDENTIFIER)
    error_at(name, "expect member name");
  if (member_type->kind == TYPE_VOID)
    error_at(name, "member has void type");
  if (type_size(member_type) < 0)
    error_at(name, "member has incomplete type");
  alignment = type_alignment(member_type);
  if (type->kind == TYPE_STRUCT) {
    padding = (alignment - *size % alignment) % alignment;
    if (*size > INT_MAX - padding ||
        type_size(member_type) > INT_MAX - *size - padding)
      error_at(name, "struct size exceeds supported limit");
  }
  member = calloc(1, sizeof(Member));
  if (!member)
    error_at(name, "out of memory");
  member->name = name;
  member->type = member_type;
  check_member_names(p, type, member);
  if (type->kind == TYPE_STRUCT) {
    member->offset = *size + padding;
    *size = member->offset + type_size(member_type);
  } else if (type_size(member_type) > *size) {
    *size = type_size(member_type);
  }
  if (alignment > type->alignment)
    type->alignment = alignment;
  return member;
}

/*
 * struct-or-union-specifier:
 *   ('struct' | 'union') identifier
 *   ('struct' | 'union') identifier_opt '{' struct-declaration+ '}'
 * struct-declaration:
 *   declaration-specifiers declarator (',' declarator)* ';'
 *   declaration-specifiers ';' (an anonymous struct or union definition)
 * (C11 6.7.2.1, excluding bit-fields and flexible array members.)
 */
static Type *parse_record_specifier(Parser *p) {
  Token loc = p->current;
  TypeKind kind = loc.kind == TOKEN_STRUCT ? TYPE_STRUCT : TYPE_UNION;
  const char *kind_name = kind == TYPE_STRUCT ? "struct" : "union";
  Token name = {0};
  Tag *tag = NULL;
  Type *type;
  Member **tail;
  int size = 0;

  parser_advance(p);
  if (p->current.kind == TOKEN_IDENTIFIER) {
    name = p->current;
    parser_advance(p);
    tag = find_tag(p, name,
                   p->current.kind == TOKEN_LBRACE ||
                       p->current.kind == TOKEN_SEMICOLON);
  } else if (p->current.kind != TOKEN_LBRACE) {
    error_at(p->current, "expect %s tag or '{'", kind_name);
  }

  if (tag) {
    if (tag->type->kind != kind)
      error_at(name, "tag '%.*s' declared as a different kind", name.len,
               name.start);
    type = tag->type;
  } else {
    type = record_type(kind);
    if (!type)
      error_at(loc, "out of memory");
    if (name.kind == TOKEN_IDENTIFIER) {
      tag = declare_tag(p, name, type);
    }
  }
  if (p->current.kind != TOKEN_LBRACE)
    return type;
  if (type->size >= 0 || (tag && tag->is_defining))
    error_at(name, "redefinition of %s '%.*s'", kind_name, name.len,
             name.start);
  if (tag)
    tag->is_defining = true;
  parser_advance(p);
  tail = &type->members;
  while (p->current.kind != TOKEN_RBRACE) {
    Type *base;
    bool anonymous;
    if (p->current.kind == TOKEN_EOF)
      error_at(p->current, "expect '}'");
    base = parse_declspecs(p, NULL, &anonymous);
    anonymous = anonymous && p->current.kind == TOKEN_SEMICOLON;
    for (;;) {
      *tail = parse_record_member(p, type, base, &size, anonymous);
      tail = &(*tail)->next;
      if (p->current.kind != TOKEN_COMMA)
        break;
      parser_advance(p);
    }
    parse_semicolon(p);
  }
  if (!type->members)
    error_at(p->current, "empty %ss are not supported", kind_name);
  int padding = (type->alignment - size % type->alignment) % type->alignment;
  if (size > INT_MAX - padding)
    error_at(loc, "%s size exceeds supported limit", kind_name);
  type->size = size + padding;
  if (tag)
    tag->is_defining = false;
  parser_advance(p);
  return type;
}

/*
 * declaration-specifiers:
 *   (storage-class-specifier | type-specifier | type-qualifier)+
 * (C11 6.7, supported subset).
 *
 * Consume storage classes, type specifiers and qualifiers in one loop. Passing
 * NULL forbids storage classes in type names, members and parameters. A storage
 * class belongs to the declaration, independently of its type. Once a base type
 * is consumed, a typedef name can instead be the declarator's name.
 * anonymous_record identifies an untagged struct or union definition, so member
 * declarations can distinguish anonymous members from typedef or tag names.
 */
static Type *parse_declspecs(Parser *p, StorageClass *storage_class,
                             bool *anonymous_record) {
  enum {
    DECLSPEC_NONE = 0,
    DECLSPEC_INT = 1 << 0,
    DECLSPEC_CHAR = 1 << 1,
    DECLSPEC_UNSIGNED = 1 << 2,
    DECLSPEC_LONG = 1 << 3,
    DECLSPEC_SHORT = 1 << 4,
    DECLSPEC_LONG_LONG = 1 << 5,
    DECLSPEC_VOID = 1 << 6,
    DECLSPEC_STRUCT = 1 << 7,
    DECLSPEC_ENUM = 1 << 8,
    DECLSPEC_TYPEDEF_NAME = 1 << 9,
    DECLSPEC_BOOL = 1 << 10,
    DECLSPEC_UNION = 1 << 11,
    DECLSPEC_EXCLUSIVE = DECLSPEC_VOID | DECLSPEC_STRUCT | DECLSPEC_ENUM |
        DECLSPEC_TYPEDEF_NAME | DECLSPEC_BOOL | DECLSPEC_UNION,
  };
  unsigned specs = DECLSPEC_NONE;
  Type *specified_type = NULL;
  Type *type;
  bool is_const = false;

  if (storage_class)
    *storage_class = STORAGE_NONE;
  if (anonymous_record)
    *anonymous_record = false;
  while (is_declspec(p, p->current)) {
    TokenKind kind = p->current.kind;
    unsigned flag;
    if (kind == TOKEN_CONST) {
      is_const = true;
      parser_advance(p);
      continue;
    }
    if (kind == TOKEN_TYPEDEF || kind == TOKEN_STATIC || kind == TOKEN_EXTERN) {
      StorageClass storage = STORAGE_EXTERN;
      if (kind == TOKEN_TYPEDEF)
        storage = STORAGE_TYPEDEF;
      else if (kind == TOKEN_STATIC)
        storage = STORAGE_STATIC;
      if (!storage_class)
        error_at(p->current, "%.*s is not allowed here", p->current.len,
                 p->current.start);
      if (*storage_class == storage)
        error_at(p->current, "duplicate %.*s specifier", p->current.len,
                 p->current.start);
      if (*storage_class != STORAGE_NONE)
        error_at(p->current, "multiple storage classes in declaration");
      *storage_class = storage;
      parser_advance(p);
      continue;
    }
    /*
     * In T T, the second typedef name is the declarator's identifier.
     */
    if (kind == TOKEN_IDENTIFIER && specs)
      break;
    switch (kind) {
    case TOKEN_BOOL:
      flag = DECLSPEC_BOOL;
      break;
    case TOKEN_INT:
      flag = DECLSPEC_INT;
      break;
    case TOKEN_CHAR:
      flag = DECLSPEC_CHAR;
      break;
    case TOKEN_UNSIGNED:
      flag = DECLSPEC_UNSIGNED;
      break;
    case TOKEN_LONG:
      flag = DECLSPEC_LONG;
      break;
    case TOKEN_SHORT:
      flag = DECLSPEC_SHORT;
      break;
    case TOKEN_VOID:
      flag = DECLSPEC_VOID;
      break;
    case TOKEN_STRUCT:
      flag = DECLSPEC_STRUCT;
      break;
    case TOKEN_UNION:
      flag = DECLSPEC_UNION;
      break;
    case TOKEN_ENUM:
      flag = DECLSPEC_ENUM;
      break;
    case TOKEN_IDENTIFIER:
      flag = DECLSPEC_TYPEDEF_NAME;
      break;
    default:
      error_at(p->current, "expect type specifier");
    }

    if (flag == DECLSPEC_LONG && (specs & DECLSPEC_LONG))
      flag = DECLSPEC_LONG_LONG;
    if (specs & flag) {
      error_at(p->current, "duplicate %.*s type specifier", p->current.len,
               p->current.start);
    }
    if ((specs & DECLSPEC_EXCLUSIVE) || ((flag & DECLSPEC_EXCLUSIVE) && specs))
      error_at(p->current, "invalid combination of type specifiers");
    specs |= flag;
    if (((specs & DECLSPEC_CHAR) &&
         (specs & (DECLSPEC_INT | DECLSPEC_LONG | DECLSPEC_SHORT))) ||
        ((specs & DECLSPEC_SHORT) && (specs & DECLSPEC_LONG)))
      error_at(p->current, "invalid combination of type specifiers");
    if (kind == TOKEN_STRUCT || kind == TOKEN_UNION) {
      if (anonymous_record)
        *anonymous_record = p->lookahead.kind == TOKEN_LBRACE;
      specified_type = parse_record_specifier(p);
    } else if (kind == TOKEN_ENUM)
      specified_type = parse_enum_specifier(p);
    else {
      if (kind == TOKEN_IDENTIFIER)
        specified_type = find_symbol(p, p->current)->d.typedef_type;
      parser_advance(p);
    }
  }

  switch (specs) {
  case DECLSPEC_BOOL:
    type = &builtin_type_bool;
    break;
  case DECLSPEC_VOID:
    type = &builtin_type_void;
    break;
  case DECLSPEC_STRUCT:
  case DECLSPEC_UNION:
  case DECLSPEC_ENUM:
  case DECLSPEC_TYPEDEF_NAME:
    type = specified_type;
    break;
  case DECLSPEC_INT:
    type = &builtin_type_int;
    break;
  case DECLSPEC_CHAR:
    type = &builtin_type_char;
    break;
  case DECLSPEC_UNSIGNED:
  case DECLSPEC_UNSIGNED | DECLSPEC_INT:
    type = &builtin_type_unsigned;
    break;
  case DECLSPEC_UNSIGNED | DECLSPEC_CHAR:
    type = &builtin_type_unsigned_char;
    break;
  case DECLSPEC_SHORT:
  case DECLSPEC_SHORT | DECLSPEC_INT:
    type = &builtin_type_short;
    break;
  case DECLSPEC_UNSIGNED | DECLSPEC_SHORT:
  case DECLSPEC_UNSIGNED | DECLSPEC_SHORT | DECLSPEC_INT:
    type = &builtin_type_unsigned_short;
    break;
  case DECLSPEC_LONG:
  case DECLSPEC_LONG | DECLSPEC_INT:
    type = &builtin_type_long;
    break;
  case DECLSPEC_UNSIGNED | DECLSPEC_LONG:
  case DECLSPEC_UNSIGNED | DECLSPEC_LONG | DECLSPEC_INT:
    type = &builtin_type_unsigned_long;
    break;
  case DECLSPEC_LONG | DECLSPEC_LONG_LONG:
  case DECLSPEC_LONG | DECLSPEC_LONG_LONG | DECLSPEC_INT:
    type = &builtin_type_long_long;
    break;
  case DECLSPEC_UNSIGNED | DECLSPEC_LONG | DECLSPEC_LONG_LONG:
  case DECLSPEC_UNSIGNED | DECLSPEC_LONG | DECLSPEC_LONG_LONG | DECLSPEC_INT:
    type = &builtin_type_unsigned_long_long;
    break;
  case DECLSPEC_NONE:
    error_at(p->current, "expect type specifier");
  default:
    error_at(p->current, "invalid combination of type specifiers");
  }
  if (is_const) {
    type = const_type(type);
    if (!type)
      error_at(p->current, "out of memory");
  }
  return type;
}

/*
 * declarator:
 *   pointer_opt direct-declarator
 * direct-declarator:
 *   identifier
 *   identifier '[' constant-expression_opt ']'
 * pointer:
 *   '*' type-qualifier-list_opt
 *   '*' type-qualifier-list_opt pointer
 * (C11 6.7.6, supported subset; _opt means optional.)
 *
 * The name may be omitted for a parameter declaration; callers enforce where
 * it is required. An omitted name retains the token at its expected position
 * for diagnostics, even if an array suffix is subsequently consumed.
 * Only one-dimensional arrays with constant or unknown bounds are supported.
 * Function and parenthesized declarators come later.
 */
static Type *parse_declarator(Parser *p, Type *type, Token *name) {
  while (p->current.kind == TOKEN_STAR) {
    type = pointer_to(type);
    if (!type)
      error_at(p->current, "out of memory");
    parser_advance(p);
    while (p->current.kind == TOKEN_CONST) {
      type = const_type(type);
      if (!type)
        error_at(p->current, "out of memory");
      parser_advance(p);
    }
  }
  *name = p->current;
  if (p->current.kind == TOKEN_IDENTIFIER) {
    parser_advance(p);
  }
  if (p->current.kind == TOKEN_LBRACKET) {
    Token loc = p->current;
    AstNode *bound;
    int64_t length = -1;
    parser_advance(p);
    if (type->kind == TYPE_VOID)
      error_at(loc, "array element has void type");
    if (type_size(type) < 0)
      error_at(loc, "array element has incomplete type");
    if (p->current.kind != TOKEN_RBRACKET) {
      bound = parse_conditional(p);
      if (!is_integer(bound->type))
        error_at(bound->loc, "array bound must have integer type");
      length = eval_const_expr(p, bound);
      if (length == 0 || (length < 0 && !bound->type->is_unsigned))
        error_at(bound->loc, "array bound must be positive");
      if ((uint64_t)length > (uint64_t)(INT_MAX / type_size(type)))
        error_at(bound->loc, "array size exceeds supported limit");
    }
    parse_expect(p, TOKEN_RBRACKET, "expect ']'");
    type = array_of(type, (int)length);
    if (!type)
      error_at(loc, "out of memory");
    if (p->current.kind == TOKEN_LBRACKET)
      error_at(p->current, "multidimensional arrays are not supported yet");
  }
  return type;
}

/*
 * type-name: specifier-qualifier-list abstract-declarator_opt (C11 6.7.7).
 * Our supported specifiers share parse_declspecs. Reuse pointer and fixed-array
 * declarators, but forbid an identifier. Parenthesized abstract declarators
 * are not supported yet.
 */
static Type *parse_type_name(Parser *p) {
  Token name;
  Type *type = parse_declspecs(p, NULL, NULL);
  type = parse_declarator(p, type, &name);
  if (name.kind == TOKEN_IDENTIFIER)
    error_at(name, "type name cannot contain an identifier");
  return type;
}

/*
 * declaration: declaration-specifiers declarator (',' declarator)* ';'
 * The declaration-specifiers contain typedef (C11 6.7, 6.7.8).
 * Aliases allocate no storage and use an empty declaration node in blocks.
 */
static AstNode *parse_typedef_declarators(Parser *p, Type *base) {
  AstNode *decl = new_ast_node(p, AST_DECL);
  if ((is_record(base) || base->kind == TYPE_ENUM) &&
      p->current.kind == TOKEN_SEMICOLON) {
    parser_advance(p);
    return decl;
  }
  for (;;) {
    Token name;
    Type *type = parse_declarator(p, base, &name);
    if (name.kind != TOKEN_IDENTIFIER)
      error_at(name, "expect typedef name");
    if (p->current.kind == TOKEN_ASSIGN)
      error_at(p->current, "typedef cannot have an initializer");
    if (p->current.kind == TOKEN_LPAREN)
      error_at(p->current, "function typedefs are not supported yet");
    declare_typedef(p, name, type);
    if (p->current.kind != TOKEN_COMMA)
      break;
    parser_advance(p);
  }
  parse_semicolon(p);
  return decl;
}

/*
 * initializer: assignment-expression | '{' initializer-list ','_opt '}'
 * initializer-list: designation_opt initializer
 *                   initializer-list ',' designation_opt initializer
 * designation: designator+ '='
 * designator: '[' constant-expression ']' | '.' identifier
 * (C11 6.7.9)
 */
static Designator *parse_designation(Parser *p) {
  Designator *head = NULL;
  Designator **tail = &head;
  while (p->current.kind == TOKEN_DOT || p->current.kind == TOKEN_LBRACKET) {
    Designator *designator = calloc(1, sizeof(Designator));
    if (!designator)
      error_at(p->current, "out of memory");
    designator->loc = p->current;
    parser_advance(p);
    if (designator->loc.kind == TOKEN_DOT) {
      if (p->current.kind != TOKEN_IDENTIFIER)
        error_at(p->current, "expect member name");
      designator->member = p->current;
      parser_advance(p);
    } else {
      designator->index = parse_conditional(p);
      parse_expect(p, TOKEN_RBRACKET, "expect ']'");
    }
    *tail = designator;
    tail = &designator->next;
  }
  if (head)
    parse_expect(p, TOKEN_ASSIGN, "expect '='");
  return head;
}

static Initializer *parse_initializer(Parser *p) {
  Initializer *init = calloc(1, sizeof(Initializer));
  Initializer **tail;
  if (!init)
    error_at(p->current, "out of memory");
  tail = &init->children;
  init->loc = p->current;
  if (p->current.kind != TOKEN_LBRACE) {
    init->expr = parse_assignment(p);
    return init;
  }
  parser_advance(p);
  if (p->current.kind == TOKEN_RBRACE)
    error_at(p->current, "empty initializer lists are not supported in C11");
  for (;;) {
    Designator *designators = parse_designation(p);
    *tail = parse_initializer(p);
    (*tail)->designators = designators;
    tail = &(*tail)->next;
    if (p->current.kind != TOKEN_COMMA)
      break;
    parser_advance(p);
    if (p->current.kind == TOKEN_RBRACE)
      break;
  }
  parse_expect(p, TOKEN_RBRACE, "expect '}'");
  return init;
}

/*
 * declaration:
 *   declaration-specifiers init-declarator (',' init-declarator)* ';'
 * init-declarator:
 *   declarator
 *   declarator '=' initializer
 * (C11 6.7. Each declarator is applied to the shared specifier type, so
 *  'int *a, b' declares a pointer and an int. The returned nodes are linked
 *  through AstNode.next.)
 */
static AstNode *parse_decl(Parser *p, bool allow_typedef) {
  AstNode *head = NULL;
  AstNode **tail = &head;
  Token loc = p->current;
  Type *base;
  StorageClass storage_class;

  base = parse_declspecs(p, &storage_class, NULL);
  if (storage_class == STORAGE_TYPEDEF) {
    if (!allow_typedef)
      error_at(loc, "typedef is not allowed in a for initializer");
    return parse_typedef_declarators(p, base);
  }
  if (storage_class == STORAGE_STATIC && !allow_typedef)
    error_at(loc, "static is not allowed in a for initializer");
  if (storage_class == STORAGE_EXTERN && !allow_typedef)
    error_at(loc, "extern is not allowed in a for initializer");
  if ((is_record(base) || base->kind == TYPE_ENUM) &&
      p->current.kind == TOKEN_SEMICOLON) {
    AstNode *decl = new_ast_node(p, AST_DECL);
    parser_advance(p);
    return decl;
  }

  for (;;) {
    Token name;
    Type *type = parse_declarator(p, base, &name);
    AstNode *decl;

    if (type->kind == TYPE_VOID)
      error_at((name.kind == TOKEN_IDENTIFIER ? name : p->current),
               "variable has void type");
    if (name.kind != TOKEN_IDENTIFIER)
      error_at(name, "expect variable name");
    if (storage_class == STORAGE_STATIC)
      error_at(name, "static local variables are not supported yet");
    if (storage_class == STORAGE_EXTERN)
      error_at(name, "block-scope extern declarations are not supported yet");
    if (p->current.kind == TOKEN_LPAREN)
      error_at(p->current,
               "function declarations in a declaration list are not "
               "supported yet");

    decl = new_ast_node(p, AST_DECL);
    decl->loc = name;
    sema_check_variable_name(p, name, false);
    decl->d.decl.var = new_variable(p, name, type);

    if (p->current.kind == TOKEN_ASSIGN) {
      parser_advance(p);
      decl->d.decl.init = sema_initialize_variable(p, decl->d.decl.var, name,
                                                   parse_initializer(p));
    }
    if (type_size(decl->d.decl.var->type) < 0)
      error_at(name, "variable has incomplete type");

    *tail = decl;
    tail = &decl->next;
    if (p->current.kind != TOKEN_COMMA)
      break;
    parser_advance(p);
  }
  parse_semicolon(p);
  return head;
}

/*
 * multiplicative-expression:
 *   cast-expression
 *   multiplicative-expression '*' cast-expression
 *   multiplicative-expression '/' cast-expression
 *   multiplicative-expression '%' cast-expression
 * (C11 6.5.5)
 */
static AstNode *parse_multiplicative(Parser *p) {
  AstNode *left;

  left = parse_cast(p);

  while (p->current.kind == TOKEN_STAR || p->current.kind == TOKEN_SLASH ||
         p->current.kind == TOKEN_PERCENT) {
    TokenKind op;
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    op = p->current.kind;
    /* Consume '*' or '/' or '%' */
    parser_advance(p);

    right = parse_cast(p);
    node = sema_binary(
        p, op == TOKEN_STAR ? AST_MUL : (op == TOKEN_SLASH ? AST_DIV : AST_MOD),
        left, right, op_tok);

    left = node;
  }

  return left;
}

/*
 * additive-expression:
 *   multiplicative-expression
 *   additive-expression '+' multiplicative-expression
 *   additive-expression '-' multiplicative-expression
 * (C11 6.5.6)
 */
static AstNode *parse_additive(Parser *p) {
  AstNode *left;

  left = parse_multiplicative(p);

  while (p->current.kind == TOKEN_PLUS || p->current.kind == TOKEN_MINUS) {
    TokenKind op;
    AstNode *right;
    AstNode *node;
    Token op_tok;

    op = p->current.kind;
    op_tok = p->current;
    /* Consume '+' or '-' */
    parser_advance(p);
    right = parse_multiplicative(p);

    node = sema_binary(p, op == TOKEN_PLUS ? AST_ADD : AST_SUB, left, right,
                       op_tok);

    left = node;
  }

  return left;
}

/*
 * shift-expression:
 *   additive-expression
 *   shift-expression '<<' additive-expression
 *   shift-expression '>>' additive-expression
 * (C11 6.5.7)
 */
static AstNode *parse_shift(Parser *p) {
  AstNode *left;

  left = parse_additive(p);

  while (p->current.kind == TOKEN_LSHIFT || p->current.kind == TOKEN_RSHIFT) {
    TokenKind op;
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    op = p->current.kind;
    /* Consume '<<' or '>>' */
    parser_advance(p);

    right = parse_additive(p);
    node = sema_binary(p, op == TOKEN_LSHIFT ? AST_LSHIFT : AST_RSHIFT, left,
                       right, op_tok);

    left = node;
  }

  return left;
}

/*
 * relational-expression:
 *   shift-expression
 *   relational-expression '<' shift-expression
 *   relational-expression '>' shift-expression
 *   relational-expression '<=' shift-expression
 *   relational-expression '>=' shift-expression
 * (C11 6.5.8)
 */
static AstNode *parse_relational(Parser *p) {
  AstNode *left;

  left = parse_shift(p);

  while (p->current.kind == TOKEN_LESS || p->current.kind == TOKEN_GREATER ||
         p->current.kind == TOKEN_LESS_EQ ||
         p->current.kind == TOKEN_GREATER_EQ) {
    AstKind ty;
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    switch (p->current.kind) {
    case TOKEN_LESS:
      ty = AST_LT;
      break;
    case TOKEN_GREATER:
      ty = AST_GT;
      break;
    case TOKEN_LESS_EQ:
      ty = AST_LE;
      break;
    case TOKEN_GREATER_EQ:
      ty = AST_GE;
      break;
    default:
      fprintf(stderr, "unreachable %s:%d", __FILE__, __LINE__);
      exit(1);
    }

    /* Consume '<' or '>' or '<=' or '>=' */
    parser_advance(p);

    right = parse_shift(p);
    node = sema_binary(p, ty, left, right, op_tok);

    left = node;
  }

  return left;
}

/*
 * equality-expression:
 *   relational-expression
 *   equality-expression '==' relational-expression
 *   equality-expression '!=' relational-expression
 * (C11 6.5.9)
 */
static AstNode *parse_equality(Parser *p) {
  AstNode *left;

  left = parse_relational(p);

  while (p->current.kind == TOKEN_EQ_EQ || p->current.kind == TOKEN_NOT_EQ) {
    TokenKind op;
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    op = p->current.kind;
    /* Consume '==' or '!=' */
    parser_advance(p);

    right = parse_relational(p);
    node = sema_binary(p, op == TOKEN_EQ_EQ ? AST_EQ : AST_NE, left, right,
                       op_tok);

    left = node;
  }

  return left;
}

/*
 * AND-expression:
 *   equality-expression
 *   AND-expression '&' equality-expression
 * (C11 6.5.10)
 */
static AstNode *parse_bitwise_and(Parser *p) {
  AstNode *left;

  left = parse_equality(p);

  while (p->current.kind == TOKEN_BIT_AND) {
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    /* Consume '&' */
    parser_advance(p);

    right = parse_equality(p);
    node = sema_binary(p, AST_BIT_AND, left, right, op_tok);

    left = node;
  }

  return left;
}

/*
 * exclusive-OR-expression:
 *   AND-expression
 *   exclusive-OR-expression '^' AND-expression
 * (C11 6.5.11)
 */
static AstNode *parse_bitwise_xor(Parser *p) {
  AstNode *left;

  left = parse_bitwise_and(p);

  while (p->current.kind == TOKEN_BIT_XOR) {
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    /* Consume '^' */
    parser_advance(p);

    right = parse_bitwise_and(p);
    node = sema_binary(p, AST_BIT_XOR, left, right, op_tok);

    left = node;
  }

  return left;
}

/*
 * inclusive-OR-expression:
 *   exclusive-OR-expression
 *   inclusive-OR-expression '|' exclusive-OR-expression
 * (C11 6.5.12)
 */
static AstNode *parse_bitwise_or(Parser *p) {
  AstNode *left;

  left = parse_bitwise_xor(p);

  while (p->current.kind == TOKEN_BIT_OR) {
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    /* Consume '|' */
    parser_advance(p);

    right = parse_bitwise_xor(p);
    node = sema_binary(p, AST_BIT_OR, left, right, op_tok);

    left = node;
  }

  return left;
}

/*
 * logical-AND-expression:
 *   inclusive-OR-expression
 *   logical-AND-expression '&&' inclusive-OR-expression
 * (C11 6.5.13)
 */
static AstNode *parse_logical_and(Parser *p) {
  AstNode *left;

  left = parse_bitwise_or(p);

  while (p->current.kind == TOKEN_AND_AND) {
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    /* Consume '&&' */
    parser_advance(p);

    right = parse_bitwise_or(p);
    node = sema_binary(p, AST_LOGICAL_AND, left, right, op_tok);

    left = node;
  }

  return left;
}

/*
 * logical-OR-expression:
 *   logical-AND-expression
 *   logical-OR-expression '||' logical-AND-expression
 * (C11 6.5.14)
 */
static AstNode *parse_logical_or(Parser *p) {
  AstNode *left;

  left = parse_logical_and(p);

  while (p->current.kind == TOKEN_OR_OR) {
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    /* Consume '||' */
    parser_advance(p);

    right = parse_logical_and(p);
    node = sema_binary(p, AST_LOGICAL_OR, left, right, op_tok);

    left = node;
  }

  return left;
}

/*
 * expression:
 *   assignment-expression
 *   expression ',' assignment-expression
 * (C11 6.5.17; the left operand is evaluated and its value discarded,
 *  its side effects kept, before the right operand is evaluated)
 */
static AstNode *parse_expression(Parser *p) {
  AstNode *left;

  left = parse_assignment(p);
  while (p->current.kind == TOKEN_COMMA) {
    AstNode *right;
    AstNode *node;
    Token op_tok = p->current;

    /* Consume ',' */
    parser_advance(p);
    right = parse_assignment(p);
    node = sema_binary(p, AST_COMMA, left, right, op_tok);
    left = node;
  }
  return left;
}

/*
 * Parse a controlling expression and apply scalar condition checks.
 * The caller handles its surrounding parentheses or semicolons.
 */
static AstNode *parse_condition(Parser *p) {
  return sema_check_condition(parse_expression(p));
}

/*
 * conditional-expression:
 *   logical-OR-expression
 *   logical-OR-expression '?' expression ':' conditional-expression
 * (C11 6.5.15; the middle operand is a full expression, the third a
 *  conditional-expression, which makes the operator right-associative)
 */
static AstNode *parse_conditional(Parser *p) {
  AstNode *node;

  node = parse_logical_or(p);
  if (p->current.kind == TOKEN_QUESTION) {
    Token op_tok = p->current;
    AstNode *cond = node;
    AstNode *then_expr;
    AstNode *else_expr;

    /* Consume '?' */
    parser_advance(p);
    then_expr = parse_expression(p);
    parse_expect(p, TOKEN_COLON, "expect ':'");
    else_expr = parse_conditional(p);

    node = sema_conditional(p, cond, then_expr, else_expr, op_tok);
  }
  return node;
}

/*
 * assignment-expression:
 *   conditional-expression
 *   conditional-expression assignment-operator assignment-expression
 * (C11 6.5.16; the left operand must be an lvalue. assignment-operator:
 *  = += -= *= /= %= <<= >>= &= ^= |=)
 */
static AstNode *parse_assignment(Parser *p) {
  AstNode *left = parse_conditional(p);
  if (is_assignment_op(p->current.kind)) {
    Token op = p->current;
    AstNode *rhs;
    parser_advance(p);
    rhs = parse_assignment(p);
    return sema_assignment(p, op, left, rhs);
  }
  return left;
}

/*
 * jump-statement:
 *   'return' expression_opt ';'
 * The function's return type determines whether a value is required.
 */
static AstNode *parse_return_stmt(Parser *p) {
  AstNode *ast;
  Token loc = p->current;
  parse_expect(p, TOKEN_RETURN, "expect 'return'");
  if (p->current.kind == TOKEN_SEMICOLON &&
      p->current_function->return_type->kind != TYPE_VOID)
    error_at(loc, "expect return expr");

  ast = new_ast_node(p, AST_RETURN);
  ast->loc = loc;
  if (p->current.kind != TOKEN_SEMICOLON)
    ast->d.ret.expr = parse_expression(p);
  sema_check_return(p, ast);
  parse_semicolon(p);

  return ast;
}

/*
 * compound-statement:
 *   '{' block-item* '}'
 * (C11 6.8.2)
 *
 * Parse in the current scope. A function body shares the scope already entered
 * for its parameters; nested blocks enter a new scope through parse_block.
 */
static AstNode *parse_compound_stmt(Parser *p) {
  AstNode *block;
  AstNode **tail;

  block = new_ast_node(p, AST_BLOCK);
  tail = &block->d.block.first_stmt;

  parse_expect(p, TOKEN_LBRACE, "expect '{'");
  while (p->current.kind != TOKEN_RBRACE) {
    if (p->current.kind == TOKEN_EOF)
      error_at(p->current, "expect '}'");

    *tail = parse_stmt(p, /*allow_decl=*/true);
    /* A declaration with several names is a chain of AST_DECL nodes. */
    while (*tail)
      tail = &(*tail)->next;
  }

  parse_expect(p, TOKEN_RBRACE, "expect '}'");
  return block;
}

static AstNode *parse_block(Parser *p) {
  AstNode *block;

  enter_scope(p);
  block = parse_compound_stmt(p);
  leave_scope(p);
  return block;
}

/*
 * Each declarator uses the same base type. Only the first definition or
 * tentative definition produces a storage AST node; extern-only declarations
 * and compatible redeclarations add no node.
 */
static AstNode *parse_global_declaration(Parser *p, Type *base, Type *type,
                                         Token name,
                                         StorageClass storage_class) {
  AstNode *head = NULL;
  AstNode **tail = &head;
  for (;;) {
    AstNode *decl;
    if (name.kind != TOKEN_IDENTIFIER)
      error_at(name, "expect variable name");
    if (p->current.kind == TOKEN_LPAREN)
      error_at(p->current,
               "function declarations in a declaration list are not "
               "supported yet");
    decl = declare_global_variable(p, name, type, storage_class,
                                   p->current.kind == TOKEN_ASSIGN);
    if (p->current.kind == TOKEN_ASSIGN) {
      Variable *var = find_symbol_in_scope(p, name, 0)->d.variable;
      parser_advance(p);
      Initializer *initializer = parse_initializer(p);
      sema_initialize_variable(p, var, name, initializer);
    }
    if (decl) {
      *tail = decl;
      tail = &decl->next;
    }
    if (p->current.kind != TOKEN_COMMA)
      break;
    parser_advance(p);
    type = parse_declarator(p, base, &name);
  }
  parse_semicolon(p);
  return head;
}

/*
 * Parse a function's parameter declarations and optional body after its return
 * type and name have been consumed.
 * parameter-type-list: parameter-list | parameter-list ',' '...' (C11 6.7.6.3).
 */
static AstNode *parse_function_declaration(Parser *p, Type *return_type,
                                           Token func_name, bool is_static) {
  AstNode *fn = new_ast_node(p, AST_FUNCTION);
  Function *func;
  Variable *params = NULL;
  Variable **param_tail = &params;
  Vector param_types;
  int nparams;
  int definition = 0;
  int explicit_params = 0;
  bool is_variadic = false;
  Token unnamed_param = {0};

  vector_init(&param_types, sizeof(Type *));
  fn->loc = func_name;
  if (return_type->kind == TYPE_ARRAY)
    error_at(func_name, "function cannot return an array");

  parse_expect(p, TOKEN_LPAREN, "expect '('");
  enter_scope(p);

  if (p->current.kind == TOKEN_VOID && p->lookahead.kind == TOKEN_RPAREN) {
    explicit_params = 1;
    parser_advance(p);
  } else if (p->current.kind != TOKEN_RPAREN) {
    explicit_params = 1;
    for (;;) {
      Variable *param;
      Token param_name;
      Token param_loc = p->current;
      Type *param_type;

      if (p->current.kind == TOKEN_ELLIPSIS) {
        if (param_types.len == 0)
          error_at(p->current, "expect parameter before '...'");
        is_variadic = true;
        parser_advance(p);
        break;
      }
      param_type = parse_declspecs(p, NULL, NULL);
      param_type = parse_declarator(p, param_type, &param_name);
      if (param_type->kind == TYPE_ARRAY) {
        param_type = pointer_to(param_type->base);
        if (!param_type)
          error_at(p->current, "out of memory");
      }
      if (param_type->kind == TYPE_VOID && !param_type->is_const &&
          param_types.len == 0 && param_name.kind != TOKEN_IDENTIFIER &&
          p->current.kind == TOKEN_RPAREN)
        break;
      if (param_type->kind == TYPE_VOID)
        error_at(
            (param_name.kind == TOKEN_IDENTIFIER ? param_name : p->current),
            "parameter has void type");
      if (param_types.len >= INT_MAX)
        error_at(p->current, "too many function parameters");
      if (!vector_push(&param_types, &param_type))
        error_at(p->current, "out of memory");

      if (param_name.kind == TOKEN_IDENTIFIER) {
        sema_check_variable_name(p, param_name, true);

        param = new_variable(p, param_name, param_type);
        param->is_parameter = true;
        *param_tail = param;
        param_tail = &param->next;
      } else {
        if (p->current.kind != TOKEN_COMMA && p->current.kind != TOKEN_RPAREN)
          error_at(p->current, "expect parameter name");
        if (!unnamed_param.start)
          unnamed_param = param_loc;
      }

      if (p->current.kind == TOKEN_COMMA) {
        parser_advance(p);
        continue;
      }
      break;
    }
  }
  parse_expect(p, TOKEN_RPAREN, "expect ')'");

  if (p->current.kind != TOKEN_SEMICOLON && p->current.kind != TOKEN_LBRACE)
    error_at(p->current, "expect ';' or '{'");

  definition = p->current.kind == TOKEN_LBRACE;
  if (definition && unnamed_param.start)
    error_at(unnamed_param, "expect parameter name in function definition");
  if (definition) {
    Variable *param;
    if (is_record(return_type) && type_size(return_type) < 0)
      error_at(func_name, "function return type is incomplete");
    for (param = params; param; param = param->next)
      if (type_size(param->type) < 0)
        error_at(param->name, "parameter has incomplete type");
  }

  nparams = (int)param_types.len;
  func = declare_function(p, func_name, return_type, param_types.data, nparams,
                          explicit_params || definition, is_variadic,
                          definition, is_static);
  vector_free(&param_types);

  if (!definition) {
    /* Consume ';' */
    parser_advance(p);
    leave_scope(p);
    return NULL;
  }

  p->current_function = func;
  p->last_parameter = params;
  while (p->last_parameter && p->last_parameter->next)
    p->last_parameter = p->last_parameter->next;
  fn->d.function.declaration = func;
  fn->d.function.params = params;
  fn->d.function.body = parse_compound_stmt(p);
  leave_scope(p);
  check_gotos(p);
  return fn;
}

/*
 * external-declaration: function-definition | declaration (C11 6.9).
 * A '(' after the declarator starts a function; otherwise parse objects.
 */
static AstNode *parse_external_declaration(Parser *p) {
  Type *base;
  Type *type;
  Token name;
  StorageClass storage_class;

  reset_function_state(p);
  base = parse_declspecs(p, &storage_class, NULL);
  if (storage_class == STORAGE_TYPEDEF) {
    parse_typedef_declarators(p, base);
    return NULL;
  }
  if ((is_record(base) || base->kind == TYPE_ENUM) &&
      p->current.kind == TOKEN_SEMICOLON) {
    parser_advance(p);
    return NULL;
  }
  type = parse_declarator(p, base, &name);
  if (name.kind != TOKEN_IDENTIFIER)
    error_at(name, "expect declaration name");
  if (p->current.kind == TOKEN_LPAREN)
    return parse_function_declaration(p, type, name,
                                      storage_class == STORAGE_STATIC);
  return parse_global_declaration(p, base, type, name, storage_class);
}

/*
 * selection-statement:
 *   'if' '(' expression ')' statement
 *   'if' '(' expression ')' statement 'else' statement
 * (C11 6.8.4.1; the recursive call to parse_stmt for the branches
 *  gives 'else' the C association with the nearest unmatched 'if')
 */
static AstNode *parse_if_stmt(Parser *p) {
  AstNode *if_node;

  parse_expect(p, TOKEN_IF, "expect 'if'");
  parse_expect(p, TOKEN_LPAREN, "expect '('");
  if_node = new_ast_node(p, AST_IF);
  if_node->d.if_stmt.cond = parse_condition(p);
  parse_expect(p, TOKEN_RPAREN, "expect ')'");
  if_node->d.if_stmt.then_stmt = parse_stmt(p, /*allow_decl=*/false);
  if (p->current.kind == TOKEN_ELSE) {
    /* Consume 'else' */
    parser_advance(p);
    if_node->d.if_stmt.else_stmt = parse_stmt(p, /*allow_decl=*/false);
  }
  return if_node;
}

/*
 * iteration-statement:
 *   'while' '(' expression ')' statement
 * (C11 6.8.5.1)
 */
static AstNode *parse_while_stmt(Parser *p) {
  AstNode *while_node;

  parse_expect(p, TOKEN_WHILE, "expect 'while'");
  parse_expect(p, TOKEN_LPAREN, "expect '('");
  while_node = new_ast_node(p, AST_WHILE);
  while_node->d.while_stmt.cond = parse_condition(p);
  parse_expect(p, TOKEN_RPAREN, "expect ')'");
  ++p->loop_depth;
  while_node->d.while_stmt.body = parse_stmt(p, /*allow_decl=*/false);
  --p->loop_depth;
  return while_node;
}

/*
 * iteration-statement:
 *   'for' '(' expression_opt ';' expression_opt ';' expression_opt ')'
 *       statement
 *   'for' '(' declaration expression_opt ';' expression_opt ')' statement
 * (C11 6.8.5.3; a declaration in the init clause is scoped to the loop,
 *  and an omitted condition means a nonzero constant)
 */
static AstNode *parse_for_stmt(Parser *p) {
  AstNode *for_node;

  parse_expect(p, TOKEN_FOR, "expect 'for'");
  parse_expect(p, TOKEN_LPAREN, "expect '('");

  for_node = new_ast_node(p, AST_FOR);

  /* A declaration in the init clause is scoped to the whole loop. */
  enter_scope(p);

  if (is_declspec(p, p->current)) {
    /* parse_decl consumes the declaration's own ';'. */
    for_node->d.for_stmt.init = parse_decl(p, false);
  } else if (p->current.kind == TOKEN_SEMICOLON) {
    /* Omitted init clause; consume the ';'. */
    parser_advance(p);
  } else {
    AstNode *init = new_ast_node(p, AST_EXPR_STMT);
    init->d.expr_stmt.expr = parse_expression(p);
    parse_expect(p, TOKEN_SEMICOLON, "expect ';'");
    for_node->d.for_stmt.init = init;
  }

  if (p->current.kind != TOKEN_SEMICOLON) {
    for_node->d.for_stmt.cond = parse_condition(p);
  }
  parse_expect(p, TOKEN_SEMICOLON, "expect ';'");

  if (p->current.kind != TOKEN_RPAREN)
    for_node->d.for_stmt.post = parse_expression(p);
  parse_expect(p, TOKEN_RPAREN, "expect ')'");

  ++p->loop_depth;
  for_node->d.for_stmt.body = parse_stmt(p, /*allow_decl=*/false);
  --p->loop_depth;
  leave_scope(p);

  return for_node;
}

/*
 * iteration-statement:
 *   'do' statement 'while' '(' expression ')' ';'
 * (C11 6.8.5.2)
 */
static AstNode *parse_do_stmt(Parser *p) {
  AstNode *do_node;

  parse_expect(p, TOKEN_DO, "expect 'do'");
  do_node = new_ast_node(p, AST_DO);
  ++p->loop_depth;
  do_node->d.do_stmt.body = parse_stmt(p, /*allow_decl=*/false);
  --p->loop_depth;
  parse_expect(p, TOKEN_WHILE, "expect 'while'");
  parse_expect(p, TOKEN_LPAREN, "expect '('");
  do_node->d.do_stmt.cond = parse_condition(p);
  parse_expect(p, TOKEN_RPAREN, "expect ')'");
  /* The trailing ';' is part of the do-statement itself. */
  parse_semicolon(p);
  return do_node;
}

/*
 * jump-statement:
 *   'break' ';'
 * (C11 6.8.6.3, valid only within a loop)
 */
static AstNode *parse_break_stmt(Parser *p) {
  /* Check before consuming so the error lands on 'break' itself. */
  if (p->loop_depth == 0 && !p->current_switch)
    error_at(p->current, "break statement not within loop or switch");
  parse_expect(p, TOKEN_BREAK, "expect 'break'");
  parse_semicolon(p);
  return new_ast_node(p, AST_BREAK);
}

/*
 * jump-statement:
 *   'continue' ';'
 * (C11 6.8.6.2, valid only within a loop)
 */
static AstNode *parse_continue_stmt(Parser *p) {
  /* Check before consuming so the error lands on 'continue' itself. */
  if (p->loop_depth == 0)
    error_at(p->current, "continue statement not within loop");
  parse_expect(p, TOKEN_CONTINUE, "expect 'continue'");
  parse_semicolon(p);
  return new_ast_node(p, AST_CONTINUE);
}

/*
 * jump-statement:
 *   'goto' identifier ';'
 * (C11 6.8.6.1; the target is validated after the function body is
 *  parsed, since a label may be declared after the goto that uses it)
 */
static AstNode *parse_goto_stmt(Parser *p) {
  AstNode *goto_node;
  GotoRef *ref;
  Token goto_tok;

  goto_tok = p->current;
  parse_expect(p, TOKEN_GOTO, "expect 'goto'");
  if (p->current.kind != TOKEN_IDENTIFIER)
    error_at(p->current, "expect label name");

  ref = (GotoRef *)calloc(1, sizeof(GotoRef));
  if (!ref)
    error_at(p->current, "out of memory");
  ref->name = p->current;
  ref->loc = goto_tok;
  ref->next = p->goto_refs;
  p->goto_refs = ref;

  goto_node = new_ast_node(p, AST_GOTO);
  goto_node->d.goto_stmt.name = p->current;
  /* Consume the label name. */
  parser_advance(p);
  parse_semicolon(p);
  return goto_node;
}

/*
 * labeled-statement:
 *   identifier ':' statement
 * (C11 6.8.1; labels have function scope, so the label table survives
 *  block exit, unlike ordinary identifier bindings)
 */
static AstNode *parse_label_stmt(Parser *p) {
  AstNode *label_node;
  Label *label;
  Token name = p->current;

  /*
   * The duplicate check runs while 'current' is still the label itself,
   * so the error lands on it.
   */
  for (label = p->labels; label; label = label->next)
    if (same_identifier(label->name, name))
      error_at(p->current, "duplicate label");

  /* Consume the identifier and ':'. */
  parser_advance(p);
  parse_expect(p, TOKEN_COLON, "expect ':'");

  label = (Label *)calloc(1, sizeof(Label));
  if (!label)
    error_at(p->current, "out of memory");
  label->name = name;
  label->next = p->labels;
  p->labels = label;

  label_node = new_ast_node(p, AST_LABEL);
  label_node->d.label_stmt.name = name;
  label_node->d.label_stmt.stmt = parse_stmt(p, /*allow_decl=*/false);
  return label_node;
}

/*
 * selection-statement:
 *   'switch' '(' expression ')' statement
 * (C11 6.8.4.2; 'case' and 'default' are valid only within the body,
 *  and 'break' exits the switch)
 */
static AstNode *parse_switch_stmt(Parser *p) {
  AstNode *switch_node;
  AstNode *outer_switch;

  parse_expect(p, TOKEN_SWITCH, "expect 'switch'");
  parse_expect(p, TOKEN_LPAREN, "expect '('");
  switch_node = new_ast_node(p, AST_SWITCH);
  switch_node->d.switch_stmt.cond = sema_switch_condition(parse_expression(p));
  parse_expect(p, TOKEN_RPAREN, "expect ')'");

  /*
   * Case labels in the body belong to this switch; nested switches save
   * and restore the pointer to get their own.
   */
  outer_switch = p->current_switch;
  p->current_switch = switch_node;

  switch_node->d.switch_stmt.body = parse_stmt(p, /*allow_decl=*/false);

  p->current_switch = outer_switch;

  return switch_node;
}

/*
 * labeled-statement:
 *   'case' constant-expression ':' statement
 * (C11 6.8.4.2, valid only within a switch)
 */
static AstNode *parse_case_stmt(Parser *p) {
  AstNode *case_node;
  AstNode *expr;
  CaseList *entry;
  int64_t val;
  Token case_tok;

  /* Check before consuming so the error lands on 'case' itself. */
  if (!p->current_switch)
    error_at(p->current, "case label not within a switch statement");

  case_tok = p->current;
  parse_expect(p, TOKEN_CASE, "expect 'case'");
  expr = parse_assignment(p);
  if (!is_integer(expr->type))
    error_at(expr->loc, "case label must have integer type");
  expr = sema_convert_expr(p, p->current_switch->d.switch_stmt.cond->type, expr,
                           case_tok, "case label");
  val = eval_const_expr(p, expr);

  for (entry = p->current_switch->d.switch_stmt.cases; entry;
       entry = entry->next)
    if (!entry->node->d.case_stmt.is_default &&
        entry->node->d.case_stmt.val == val) {
      p->current = case_tok;
      error_at(p->current, "duplicate case value");
    }

  parse_expect(p, TOKEN_COLON, "expect ':'");

  case_node = new_ast_node(p, AST_CASE);
  case_node->d.case_stmt.val = val;

  entry = (CaseList *)calloc(1, sizeof(CaseList));
  if (!entry)
    error_at(p->current, "out of memory");
  entry->node = case_node;
  entry->next = p->current_switch->d.switch_stmt.cases;
  p->current_switch->d.switch_stmt.cases = entry;

  case_node->d.case_stmt.stmt = parse_stmt(p, /*allow_decl=*/false);
  return case_node;
}

/*
 * labeled-statement:
 *   'default' ':' statement
 * (C11 6.8.4.2, valid only within a switch; represented as an AST_CASE
 *  with is_default set, like GCC's CASE_LABEL_EXPR)
 */
static AstNode *parse_default_stmt(Parser *p) {
  AstNode *default_node;
  CaseList *entry;

  /* Check before consuming so the error lands on 'default' itself. */
  if (!p->current_switch)
    error_at(p->current, "default label not within a switch statement");

  for (entry = p->current_switch->d.switch_stmt.cases; entry;
       entry = entry->next)
    if (entry->node->d.case_stmt.is_default)
      error_at(p->current, "multiple default labels in one switch");

  parse_expect(p, TOKEN_DEFAULT, "expect 'default'");
  parse_expect(p, TOKEN_COLON, "expect ':'");

  default_node = new_ast_node(p, AST_CASE);
  default_node->d.case_stmt.is_default = 1;

  entry = (CaseList *)calloc(1, sizeof(CaseList));
  if (!entry)
    error_at(p->current, "out of memory");
  entry->node = default_node;
  entry->next = p->current_switch->d.switch_stmt.cases;
  p->current_switch->d.switch_stmt.cases = entry;

  default_node->d.case_stmt.stmt = parse_stmt(p, /*allow_decl=*/false);
  return default_node;
}

/*
 * statement:
 *   jump-statement | selection-statement | iteration-statement
 *   labeled-statement | compound-statement | expression-statement | ';'
 * (C11 6.8; as in GCC and Clang, anything not dispatched above is
 *  attempted as an expression-statement, whose parser diagnoses
 *  tokens that cannot start an expression. Declarations are block items,
 *  not statements, so they are accepted only when allow_decl is set —
 *  i.e. directly inside a compound-statement, like Clang's
 *  ParsedStmtContext::AllowDeclarationsInC)
 */
static AstNode *parse_stmt(Parser *p, bool allow_decl) {
  AstNode *stmt;

  if (p->current.kind == TOKEN_IDENTIFIER && p->lookahead.kind == TOKEN_COLON)
    return parse_label_stmt(p);

  if (is_declspec(p, p->current)) {
    if (allow_decl)
      return parse_decl(p, true);
    error_at(p->current, "expect statement");
  }

  switch (p->current.kind) {
  case TOKEN_RETURN:
    return parse_return_stmt(p);
  case TOKEN_IF:
    return parse_if_stmt(p);
  case TOKEN_WHILE:
    return parse_while_stmt(p);
  case TOKEN_FOR:
    return parse_for_stmt(p);
  case TOKEN_DO:
    return parse_do_stmt(p);
  case TOKEN_BREAK:
    return parse_break_stmt(p);
  case TOKEN_CONTINUE:
    return parse_continue_stmt(p);
  case TOKEN_GOTO:
    return parse_goto_stmt(p);
  case TOKEN_SWITCH:
    return parse_switch_stmt(p);
  case TOKEN_CASE:
    return parse_case_stmt(p);
  case TOKEN_DEFAULT:
    return parse_default_stmt(p);
  case TOKEN_LBRACE:
    return parse_block(p);
  case TOKEN_SEMICOLON:
    stmt = new_ast_node(p, AST_EXPR_STMT);
    parser_advance(p);
    return stmt;
  default:
    stmt = new_ast_node(p, AST_EXPR_STMT);
    stmt->d.expr_stmt.expr = parse_expression(p);
    parse_semicolon(p);
    return stmt;
  }
}

/*
 * translation-unit:
 *   external-definition*
 * (C11 6.9)
 */
AstNode *parse_translation_unit(const SourceFile *file,
                                const Vector *include_paths) {
  Parser p;
  AstNode *head = NULL;
  AstNode **tail = &head;

  parser_init(&p, file, include_paths);

  /* Keep the empty-input diagnostics: the loop would just not run. */
  if (p.current.kind == TOKEN_EOF)
    error_at((p.current), "expect type specifier");

  while (p.current.kind != TOKEN_EOF) {
    *tail = parse_external_declaration(&p);
    while (*tail)
      tail = &(*tail)->next;
  }

  pp_check_end(&p.pp);
  sema_check_global_variables(&p);
  check_calls(&p);
  return head;
}
