/*
 * Sema for the self-hosted C compiler
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

#include "builtins.h"
#include "sema.h"
#include "type.h"
#include "vector.h"

Symbol *find_symbol(Parser *p, Token name) {
  int depth;
  for (depth = p->scope_depth; depth >= 0; --depth) {
    Symbol *sym = find_symbol_in_scope(p, name, depth);
    if (sym)
      return sym;
  }
  return NULL;
}

Symbol *find_symbol_in_scope(Parser *p, Token name, int scope_depth) {
  Scope *scope = &((Scope *)p->scopes.data)[scope_depth];
  return hashtable_get(&scope->symbols, name.start, (size_t)name.len);
}

/*
 * Callers check redeclarations before binding a new name. Select the requested
 * scope directly: a function is bound at file scope even while its parameters
 * occupy an inner scope. The declaration pointer refers to the kind's object.
 */
Symbol *add_symbol(Parser *p, Token name, SymbolKind kind, void *declaration,
                   int scope_depth) {
  Scope *scope = &((Scope *)p->scopes.data)[scope_depth];
  Symbol *sym = calloc(1, sizeof(Symbol));
  if (!sym)
    error_at(name, "out of memory");
  sym->name = name;
  sym->kind = kind;
  switch (kind) {
  case SYMBOL_VARIABLE:
    sym->d.variable = declaration;
    break;
  case SYMBOL_FUNCTION:
    sym->d.function = declaration;
    break;
  case SYMBOL_TYPEDEF:
    sym->d.typedef_type = declaration;
    break;
  case SYMBOL_ENUMERATOR:
    sym->d.enumerator = declaration;
    break;
  }
  if (!hashtable_put(&scope->symbols, name.start, (size_t)name.len, sym))
    error_at(name, "out of memory");
  sym->next = scope->declarations;
  scope->declarations = sym;
  return sym;
}

static const char *symbol_kind_name(SymbolKind kind) {
  switch (kind) {
  case SYMBOL_VARIABLE:
    return "variable";
  case SYMBOL_FUNCTION:
    return "function";
  case SYMBOL_TYPEDEF:
    return "typedef";
  case SYMBOL_ENUMERATOR:
    return "enumerator";
  }
  return "identifier";
}

void sema_check_variable_name(Parser *p, Token name, bool is_parameter) {
  Symbol *prev_sym = find_symbol_in_scope(p, name, p->scope_depth);
  if (!prev_sym)
    return;
  if (prev_sym->kind == SYMBOL_VARIABLE) {
    if (!is_parameter && prev_sym->d.variable->is_parameter)
      error_at(name, "redefinition of parameter '%.*s'", name.len, name.start);
    error_at(name, "duplicate local variable");
  }
  error_at(name, "%s conflicts with %s '%.*s'",
           is_parameter ? "parameter" : "variable",
           symbol_kind_name(prev_sym->kind), name.len, name.start);
}

static AstNode *new_expr(AstKind kind, Type *type, Token loc);

/*
 * allow_addr permits symbolic addresses in static initializers. Integer
 * constant expressions disable it, including for evaluated subexpressions.
 */
static bool eval_constant_expr(Parser *p, AstNode *expr, bool allow_addr,
                               int64_t *result);
static bool eval_address_constant(Parser *p, AstNode *expr,
                                  AddressConstant *address);
static bool eval_constant_condition(Parser *p, AstNode *expr, bool allow_addr,
                                    bool *result);

/*
 * Create a variable and register its name in the current scope. Callers check
 * redeclarations first and assign storage information after creation.
 */
Variable *new_variable(Parser *p, Token name, Type *type) {
  Variable *var = calloc(1, sizeof(Variable));
  if (!var)
    error_at(name, "out of memory");
  var->name = name;
  var->type = type;
  add_symbol(p, name, SYMBOL_VARIABLE, var, p->scope_depth);
  return var;
}

/*
 * A file-scope object without an initializer is a tentative definition unless
 * declared extern (C11 6.9.2). A later initializer can provide its definition.
 * Compatible declarations share one variable, with a storage AST node created
 * only when a definition or tentative definition first appears.
 * An incomplete record with external linkage may be completed later in the
 * translation unit.
 */
AstNode *declare_global_variable(Parser *p, Token name, Type *type,
                                 StorageClass storage_class,
                                 bool has_initializer) {
  Symbol *prev_sym = find_symbol_in_scope(p, name, 0);
  Variable *var;
  AstNode *decl = NULL;
  bool is_static = storage_class == STORAGE_STATIC;
  bool is_definition = storage_class != STORAGE_EXTERN || has_initializer;
  if (type->kind == TYPE_VOID)
    error_at(name, "variable has void type");
  if (prev_sym) {
    if (prev_sym->kind != SYMBOL_VARIABLE)
      error_at(name, "variable conflicts with %s '%.*s'",
               symbol_kind_name(prev_sym->kind), name.len, name.start);
    var = prev_sym->d.variable;
    /*
     * An extern declaration inherits visible prior linkage (C11 6.2.2p4).
     */
    if (storage_class == STORAGE_EXTERN)
      is_static = var->is_static;
    if (var->is_static != is_static)
      error_at(name, "%s declaration of '%.*s' follows %s declaration",
               is_static ? "static" : "non-static", name.len, name.start,
               var->is_static ? "static" : "non-static");
    if (var->type->kind == TYPE_ARRAY && type->kind == TYPE_ARRAY &&
        same_type(var->type->base, type->base) &&
        (var->type->array_len < 0 || type->array_len < 0)) {
      if (var->type->array_len < 0 && type->array_len >= 0)
        var->type = type;
    } else if (!same_type(var->type, type)) {
      error_at(name, "conflicting declaration of variable '%.*s'", name.len,
               name.start);
    }
  } else {
    var = new_variable(p, name, type);
    var->is_global = true;
    var->is_static = is_static;
  }
  if (is_definition && !var->is_defined) {
    var->is_defined = true;
    var->name = name;
    decl = new_expr(AST_DECL, &builtin_type_void, name);
    decl->d.decl.var = var;
  }
  /*
   * Internal-linkage tentative definitions require a complete type here
   * (C11 6.9.2p3). An initializer may complete an unknown array bound.
   */
  if (is_static && storage_class != STORAGE_EXTERN && !has_initializer &&
      type_size(var->type) < 0)
    error_at(name, "static variable has incomplete type");
  return decl;
}

static Initializer *new_initializer(Type *type, Token loc) {
  Initializer *init = calloc(1, sizeof(Initializer));
  if (!init)
    error_at(loc, "out of memory");
  init->type = type;
  init->loc = loc;
  return init;
}

static Member *initializer_member(Type *type, int index, Token loc) {
  Member *member = unqualified_type(type)->members;
  int remaining = index;
  while (member && remaining > 0) {
    member = member->next;
    --remaining;
  }
  if (index < 0 || !member)
    error_at(loc, "invalid initializer member index %d", index);
  return member;
}

/*
 * Keep only explicitly initialized children, in subobject order. This avoids
 * allocating an entry for every zero in a large, sparsely initialized array.
 * Selecting a different union member replaces the previously selected member.
 */
static Initializer *initializer_child(Initializer *parent, int index,
                                      Token loc) {
  Initializer **link = &parent->children;
  Initializer *child;
  Type *type = parent->type;
  int offset;
  if (type->kind == TYPE_ARRAY) {
    int size = type_size(type->base);
    if (index < 0 || index >= INT_MAX / size)
      error_at(loc, "array initializer exceeds supported size");
    if (type->array_len >= 0 && index >= type->array_len)
      error_at(loc, "array designator index is out of bounds");
    offset = index * size;
    type = type->base;
  } else {
    Member *member = initializer_member(type, index, loc);
    if (type->kind == TYPE_UNION && *link && (*link)->index != index)
      *link = NULL;
    offset = member->offset;
    type = member->type;
  }
  while (*link && (*link)->index < index)
    link = &(*link)->next;
  if (*link && (*link)->index == index)
    return *link;
  child = new_initializer(type, loc);
  child->index = index;
  child->offset = offset;
  child->next = *link;
  *link = child;
  return child;
}

/*
 * A position names the next subobject without creating its initializer. The
 * path allows initialization after .inner.x to continue at .inner.y, then at
 * the next member of the enclosing record.
 */
typedef struct {
  Initializer *parent;
  int index;
} InitializerPosition;

static void push_initializer_position(Vector *path, Initializer *parent,
                                      int index, Token loc) {
  InitializerPosition position = {.parent = parent, .index = index};
  if (!vector_push(path, &position))
    error_at(loc, "out of memory");
}

static void advance_initializer_position(Vector *path) {
  while (path->len) {
    InitializerPosition *position =
        &((InitializerPosition *)path->data)[path->len - 1];
    Type *type = position->parent->type;
    if (type->kind != TYPE_UNION) {
      if (type->kind == TYPE_ARRAY) {
        ++position->index;
        if (type->array_len < 0 || position->index < type->array_len)
          return;
      } else {
        Member *member =
            initializer_member(type, position->index, position->parent->loc);
        if (member->next) {
          ++position->index;
          return;
        }
      }
    }
    --path->len;
  }
}

static void designate_initializer(Parser *p, Initializer *root, Vector *path,
                                  const Designator *designator) {
  Initializer *parent = root;
  path->len = 0;
  for (; designator; designator = designator->next) {
    int index = 0;
    if (designator->index) {
      int64_t value;
      if (parent->type->kind != TYPE_ARRAY)
        error_at(designator->loc, "array designator requires an array");
      if (!is_integer(designator->index->type))
        error_at(designator->index->loc,
                 "array designator index must have integer type");
      if (!eval_constant_expr(p, designator->index, /*allow_addr=*/false,
                              &value))
        error_at(designator->index->loc, "not an integer constant expression");
      if (value < 0 || (uint64_t)value >= INT_MAX)
        error_at(designator->index->loc,
                 "array designator index is out of range");
      index = (int)value;
    } else {
      Member *member;
      if (!is_record(parent->type))
        error_at(designator->loc,
                 "member designator requires a struct or union");
      /* Anonymous members add intermediate steps to the subobject path. */
      for (;;) {
        Member *found = find_member(parent->type, designator->member);
        if (!found)
          error_at(designator->member, "no member named '%.*s'",
                   designator->member.len, designator->member.start);
        index = 0;
        for (member = unqualified_type(parent->type)->members; member != found;
             member = member->next)
          ++index;
        if (found->name.kind == TOKEN_IDENTIFIER)
          break;
        push_initializer_position(path, parent, index, designator->loc);
        parent = initializer_child(parent, index, designator->loc);
      }
    }
    push_initializer_position(path, parent, index, designator->loc);
    parent = initializer_child(parent, index, designator->loc);
  }
}

/*
 * A string initializes character array elements, including its terminator
 * when space permits. Complete the object's type without changing a typedef.
 */
static void initialize_string_array(Initializer *init, AstNode *expr) {
  Type *type = init->type;
  int length;
  if (type->base->kind != TYPE_CHAR)
    error_at(expr->loc, "string initializer requires a character array");
  if (expr->kind != AST_STRING_LITERAL)
    error_at(expr->loc, "character array initializer must be a string literal");
  length = expr->type->array_len;
  if (type->array_len < 0) {
    init->type = array_of(type->base, length);
    if (!init->type)
      error_at(expr->loc, "out of memory");
  } else if (type->array_len < length - 1) {
    error_at(expr->loc, "string literal is too long for character array");
  }
  init->expr = expr;
}

/* Evaluate each static scalar after conversion to its destination type. */
static void initialize_expression(Parser *p, Initializer *init, AstNode *expr,
                                  bool is_global) {
  init->expr = NULL;
  init->children = NULL;
  init->zero_fill = false;
  if (init->type->kind == TYPE_ARRAY) {
    initialize_string_array(init, expr);
    return;
  }
  if (is_global && is_record(init->type))
    error_at(init->loc, "global initializer requires a scalar type");
  expr = sema_convert_expr(p, init->type, expr, init->loc, "initializer");
  init->expr = expr;
  if (!is_global)
    return;
  if (init->type->kind == TYPE_PTR) {
    if (!eval_address_constant(p, expr, &init->constant.address))
      error_at(expr->loc, "global initializer is not a constant expression");
  } else if (!eval_constant_expr(p, expr, /*allow_addr=*/true,
                                 &init->constant.value)) {
    error_at(expr->loc, "global initializer is not a constant expression");
  }
}

static void initialize_object(Parser *p, Initializer *init,
                              const Initializer **input, bool allow_elision,
                              bool is_global);

static void initialize_list(Parser *p, Initializer *init,
                            const Initializer **input, bool braced,
                            bool is_global) {
  Vector path;
  bool first = true;
  vector_init(&path, sizeof(InitializerPosition));
  push_initializer_position(&path, init, 0, init->loc);
  while (*input) {
    InitializerPosition *position;
    Initializer *child;
    /* A designator after an elided list belongs to the enclosing braces. */
    if ((*input)->designators && (braced || !first)) {
      if (!braced)
        break;
      designate_initializer(p, init, &path, (*input)->designators);
    }
    if (!path.len)
      break;
    position = &((InitializerPosition *)path.data)[path.len - 1];
    child = initializer_child(position->parent, position->index, (*input)->loc);
    child->loc = (*input)->loc;
    initialize_object(p, child, input, true, is_global);
    advance_initializer_position(&path);
    first = false;
  }
  vector_free(&path);
}

static bool initializes_whole_object(Type *type, AstNode *expr) {
  if (type->kind == TYPE_ARRAY)
    return type->base->kind == TYPE_CHAR && expr->kind == AST_STRING_LITERAL;
  if (is_record(type))
    return same_type(unqualified_type(type), unqualified_type(expr->type));
  return true;
}

/*
 * An explicit brace pair limits its own list. Without braces, an aggregate
 * consumes just enough entries to initialize its subobjects (C11 6.7.9p20).
 */
static void initialize_object(Parser *p, Initializer *init,
                              const Initializer **input, bool allow_elision,
                              bool is_global) {
  const Initializer *parsed = *input;
  Type *type = init->type;
  if (type_size(type) < 0 &&
      !(type->kind == TYPE_ARRAY && type_size(type->base) > 0))
    error_at(parsed->loc, "initializer has incomplete type");
  if (!parsed->expr) {
    const Initializer *entry = parsed->children;
    init->expr = NULL;
    init->children = NULL;
    init->zero_fill = true;
    if (type->kind == TYPE_ARRAY && type->base->kind == TYPE_CHAR &&
        entry->expr && entry->expr->kind == AST_STRING_LITERAL &&
        !entry->designators) {
      initialize_string_array(init, entry->expr);
      entry = entry->next;
    } else if (type->kind == TYPE_ARRAY || is_record(type)) {
      initialize_list(p, init, &entry, true, is_global);
    } else {
      if (entry->designators)
        error_at(entry->designators->loc,
                 "designator is not allowed in a scalar initializer");
      if (!entry->expr)
        error_at(entry->loc, "too many braces around scalar initializer");
      initialize_object(p, init, &entry, false, is_global);
    }
    if (entry)
      error_at(entry->loc, "excess elements in initializer");
    *input = parsed->next;
    return;
  }
  if (allow_elision && !initializes_whole_object(type, parsed->expr)) {
    init->expr = NULL;
    init->children = NULL;
    init->zero_fill = true;
    initialize_list(p, init, input, false, is_global);
    return;
  }
  initialize_expression(p, init, parsed->expr, is_global);
  *input = parsed->next;
}

Initializer *sema_initialize_variable(Parser *p, Variable *var, Token name,
                                      const Initializer *parsed) {
  Initializer *init;
  if (var->initializer)
    error_at(name, "redefinition of variable '%.*s'", name.len, name.start);
  init = new_initializer(var->type, name);
  initialize_object(p, init, &parsed, false, var->is_global);
  if (init->type->kind == TYPE_ARRAY && init->type->array_len < 0) {
    Initializer *last = init->children;
    while (last->next)
      last = last->next;
    init->type = array_of(init->type->base, last->index + 1);
    if (!init->type)
      error_at(init->loc, "out of memory");
  }
  var->type = init->type;
  var->initializer = init;
  return init;
}

/*
 * Compound literals are lvalues backed by unnamed automatic objects. Do not
 * add them to the symbol table; their AST nodes retain the checked initializer
 * and receive storage from stack layout just like named local variables.
 */
AstNode *sema_compound_literal(Parser *p, Type *type,
                               const Initializer *initializer, Token loc) {
  Variable *var;
  AstNode *node;
  if (!p->current_function)
    error_at(loc, "file-scope compound literals are not supported yet");
  if (type->kind == TYPE_VOID)
    error_at(loc, "compound literal has void type");
  if (type_size(type) < 0 &&
      !(type->kind == TYPE_ARRAY && type_size(type->base) > 0))
    error_at(loc, "compound literal has incomplete type");
  var = calloc(1, sizeof(Variable));
  if (!var)
    error_at(loc, "out of memory");
  var->name = loc;
  var->type = type;
  sema_initialize_variable(p, var, loc, initializer);
  node = new_expr(AST_COMPOUND_LITERAL, var->type, loc);
  node->d.variable.var = var;
  return node;
}

void sema_check_global_variables(Parser *p) {
  Symbol *sym;
  for (sym = ((Scope *)p->scopes.data)[0].declarations; sym; sym = sym->next) {
    Variable *var;
    if (sym->kind != SYMBOL_VARIABLE)
      continue;
    var = sym->d.variable;
    if (!var->is_defined)
      continue;
    /*
     * A tentative definition with an unknown bound becomes one element
     * when no declaration completes it before the end of the translation unit.
     */
    if (var->type->kind == TYPE_ARRAY && var->type->array_len < 0) {
      var->type = array_of(var->type->base, 1);
      if (!var->type)
        error_at(var->name, "out of memory");
    }
    if (type_size(var->type) < 0)
      error_at(var->name, "variable has incomplete type");
  }
}

/*
 * C11 permits a typedef to be repeated in the same scope for the same type.
 * An enum and its compatible integer type are still distinct types here.
 */
static bool same_typedef_type(Type *a, Type *b) {
  if (a->kind != b->kind || a->is_const != b->is_const)
    return false;
  if (a->kind == TYPE_PTR || a->kind == TYPE_ARRAY)
    return (a->kind != TYPE_ARRAY || a->array_len == b->array_len) &&
           same_typedef_type(a->base, b->base);
  return same_type(a, b);
}

void declare_typedef(Parser *p, Token name, Type *type) {
  Symbol *prev_sym = find_symbol_in_scope(p, name, p->scope_depth);
  if (prev_sym) {
    if (prev_sym->kind != SYMBOL_TYPEDEF)
      error_at(name, "typedef conflicts with %s '%.*s'",
               symbol_kind_name(prev_sym->kind), name.len, name.start);
    if (!same_typedef_type(prev_sym->d.typedef_type, type))
      error_at(name, "conflicting typedef for '%.*s'", name.len, name.start);
    return;
  }
  add_symbol(p, name, SYMBOL_TYPEDEF, type, p->scope_depth);
}

Enum *declare_enumerator(Parser *p, Token name, AstNode *initializer,
                         int64_t next_value) {
  Enum *enumerator;
  Symbol *prev_sym = find_symbol_in_scope(p, name, p->scope_depth);
  int64_t value = next_value;
  if (prev_sym && prev_sym->kind == SYMBOL_TYPEDEF)
    error_at(name, "enumerator conflicts with typedef '%.*s'", name.len,
             name.start);
  if (initializer) {
    if (!is_integer(initializer->type))
      error_at(initializer->loc, "enumerator value must have integer type");
    value = eval_const_expr(p, initializer);
  }
  if (value < INT32_MIN || value > INT32_MAX ||
      (initializer && initializer->type->is_unsigned &&
       (uint64_t)value > INT32_MAX))
    error_at(name, "enumerator value is outside the range of int");
  if (prev_sym) {
    if (prev_sym->kind == SYMBOL_ENUMERATOR)
      error_at(name, "duplicate enumerator '%.*s'", name.len, name.start);
    error_at(name, "enumerator conflicts with %s '%.*s'",
             symbol_kind_name(prev_sym->kind), name.len, name.start);
  }
  enumerator = calloc(1, sizeof(Enum));
  if (!enumerator)
    error_at(name, "out of memory");
  enumerator->name = name;
  enumerator->value = (int)value;
  add_symbol(p, name, SYMBOL_ENUMERATOR, enumerator, p->scope_depth);
  return enumerator;
}

AstNode *sema_enumerator_expr(Enum *enumerator, Token loc) {
  AstNode *node = new_expr(AST_INT_LITERAL, &builtin_type_int, loc);
  node->d.int_literal.val = (uint64_t)enumerator->value;
  return node;
}

/*
 * Convert an operand used as a value without promoting its integer type.
 * Arrays decay to pointers. Value conversion removes the top-level const
 * qualifier while preserving the qualifiers of any pointed-to type.
 * Record conversions materialize a copy; codegen represents it by its address.
 */
static AstNode *convert_to_value(AstNode *expr) {
  AstNode *node;
  Type *type;
  if (is_record(expr->type)) {
    if (type_size(expr->type) < 0)
      error_at(expr->loc, "aggregate value has incomplete type");
    /*
     * These expressions already refer to a materialized value. Assignment
     * results still refer to their destination and need a copy when consumed.
     */
    if (expr->kind == AST_CAST || expr->kind == AST_COMMA ||
        expr->kind == AST_CONDITIONAL || expr->kind == AST_CALL ||
        expr->kind == AST_VA_ARG)
      return expr;
    type = unqualified_type(expr->type);
  } else if (expr->type->kind == TYPE_ARRAY)
    type = pointer_to(expr->type->base);
  else if (expr->type->is_const)
    type = unqualified_type(expr->type);
  else
    return expr;
  if (!type)
    error_at(expr->loc, "out of memory");
  node = new_expr(AST_CAST, type, expr->loc);
  node->d.unary.operand = expr;
  return node;
}

/*
 * Controlling expressions must have scalar type. Array operands first
 * convert to pointers; preserve integer widths for codegen's zero test.
 */
AstNode *sema_check_condition(AstNode *expr) {
  expr = convert_to_value(expr);
  sema_check_nonvoid_expr(expr);
  if (!is_integer(expr->type) && expr->type->kind != TYPE_PTR)
    error_at(expr->loc, "condition must have scalar type");
  return expr;
}

static AstNode *integer_promotion(AstNode *expr) {
  AstNode *node;
  Type *type = integer_promotion_type(expr->type);
  if (type == expr->type)
    return expr;
  node = new_expr(AST_CAST, type, expr->loc);
  node->d.unary.operand = expr;
  return node;
}

/*
 * Arithmetic operands and default arguments also undergo integer promotion.
 */
static AstNode *promote_operand(AstNode *expr) {
  return integer_promotion(convert_to_value(expr));
}

AstNode *sema_switch_condition(AstNode *expr) {
  sema_check_nonvoid_expr(expr);
  if (!is_integer(expr->type))
    error_at(expr->loc, "switch condition must have integer type");
  return integer_promotion(expr);
}

Function *declare_function(Parser *p, Token name, Type *return_type,
                           Type **param_types, int nparams, bool has_prototype,
                           bool is_variadic, bool definition, bool is_static) {
  Symbol *prev_sym = find_symbol_in_scope(p, name, 0);
  Function *func = NULL;
  int i;
  /*
   * Parameter objects keep const, but it is ignored in the function's type.
   */
  for (i = 0; i < nparams; ++i)
    param_types[i] = unqualified_type(param_types[i]);
  if (prev_sym) {
    if (prev_sym->kind != SYMBOL_FUNCTION)
      error_at(name, "function conflicts with %s '%.*s'",
               symbol_kind_name(prev_sym->kind), name.len, name.start);
    func = prev_sym->d.function;
  }
  if (func) {
    /*
     * Extern and function declarations without a storage class inherit prior
     * linkage (C11 6.2.2p4-5). A later static declaration cannot change
     * external linkage.
     */
    if (is_static && !func->is_static)
      error_at(name,
               "static declaration of '%.*s' follows non-static declaration",
               name.len, name.start);
    if (definition && func->is_defined)
      error_at(name, "redefinition of function '%.*s'", name.len, name.start);
    if (!same_type(func->return_type, return_type))
      error_at(name, "conflicting declaration of function '%.*s'", name.len,
               name.start);
    if (func->has_prototype != has_prototype) {
      Type **types = func->has_prototype ? func->param_types : param_types;
      int count = func->has_prototype ? func->nparams : nparams;
      if (func->is_variadic || is_variadic)
        error_at(name, "conflicting declaration of function '%.*s'", name.len,
                 name.start);
      for (i = 0; i < count; ++i)
        if (!same_type(types[i], integer_promotion_type(types[i])))
          error_at(name, "conflicting declaration of function '%.*s'", name.len,
                   name.start);
    }
    if (func->has_prototype && has_prototype) {
      if (func->nparams != nparams || func->is_variadic != is_variadic)
        error_at(name, "conflicting declaration of function '%.*s'", name.len,
                 name.start);
      for (i = 0; i < nparams; ++i)
        if (!same_type(func->param_types[i], param_types[i]))
          error_at(name, "conflicting declaration of function '%.*s'", name.len,
                   name.start);
    }
  } else {
    func = calloc(1, sizeof(Function));
    if (!func)
      error_at(name, "out of memory");
    func->name = name;
    func->return_type = return_type;
    func->is_static = is_static;
    add_symbol(p, name, SYMBOL_FUNCTION, func, 0);
  }
  if (has_prototype && !func->has_prototype) {
    if (nparams) {
      func->param_types = calloc(nparams, sizeof(Type *));
      if (!func->param_types)
        error_at(name, "out of memory");
    }
    func->has_prototype = 1;
    func->is_variadic = is_variadic;
    func->nparams = nparams;
    for (i = 0; i < nparams; ++i)
      func->param_types[i] = param_types[i];
  }
  if (definition)
    func->is_defined = 1;
  return func;
}

void sema_check_nonvoid_expr(AstNode *expr) {
  if (expr->type->kind == TYPE_VOID)
    error_at(expr->loc, "void expression used as a value");
}

static bool null_pointer_constant(Parser *p, AstNode *expr) {
  int64_t value;
  if (expr->kind == AST_CAST && expr->type->kind == TYPE_PTR &&
      expr->type->base->kind == TYPE_VOID && !expr->type->base->is_const)
    expr = expr->d.unary.operand;
  return eval_constant_expr(p, expr, /*allow_addr=*/false, &value) &&
         value == 0;
}

static void add_address_offset(AddressConstant *address, int64_t offset,
                               Token loc) {
  if ((offset > 0 && address->offset > INT64_MAX - offset) ||
      (offset < 0 && address->offset < INT64_MIN - offset))
    error_at(loc, "address offset exceeds supported range");
  address->offset += offset;
}

/*
 * Form an object's address without reading its value. Subscripts and '->'
 * already use pointer arithmetic and dereference nodes in the typed AST.
 */
static bool eval_lvalue_address(Parser *p, AstNode *expr,
                                AddressConstant *address) {
  switch (expr->kind) {
  case AST_VAR:
    if (!expr->d.variable.var->is_global)
      return false;
    address->base = expr;
    address->offset = 0;
    return true;
  case AST_STRING_LITERAL:
    address->base = expr;
    address->offset = 0;
    return true;
  case AST_MEMBER:
    if (!eval_lvalue_address(p, expr->d.member.base, address) ||
        (!address->base && address->offset == 0))
      return false;
    add_address_offset(address, expr->d.member.member->offset, expr->loc);
    return true;
  case AST_DEREF:
    return eval_address_constant(p, expr->d.unary.operand, address);
  default:
    return false;
  }
}

static bool address_nonzero(const AddressConstant *address) {
  return address->base != NULL || address->offset != 0;
}

/*
 * Pointer expressions keep their symbolic base and byte offset. Their integer
 * operands and conditions use the same recursive evaluator as scalar values.
 */
static bool eval_address_constant(Parser *p, AstNode *expr,
                                  AddressConstant *address) {
  if (expr->type->kind != TYPE_PTR)
    return false;
  switch (expr->kind) {
  case AST_CAST: {
    AstNode *operand = expr->d.unary.operand;
    int64_t value;
    if (operand->type->kind == TYPE_ARRAY)
      return eval_lvalue_address(p, operand, address) &&
             address_nonzero(address);
    if (operand->type->kind == TYPE_PTR)
      return eval_address_constant(p, operand, address);
    if (!eval_constant_expr(p, operand, /*allow_addr=*/true, &value))
      return false;
    *address = (AddressConstant){.offset = value};
    return true;
  }
  case AST_ADDR:
    return eval_lvalue_address(p, expr->d.unary.operand, address);
  case AST_CONDITIONAL: {
    bool condition;
    if (!eval_constant_condition(p, expr->d.conditional.cond,
                                 /*allow_addr=*/true, &condition))
      return false;
    return eval_address_constant(p,
                                 condition ? expr->d.conditional.then_expr
                                           : expr->d.conditional.else_expr,
                                 address);
  }
  case AST_PTR_ADD:
  case AST_PTR_SUB: {
    AstNode *index = expr->d.binary.rhs;
    int size = type_size(expr->d.binary.lhs->type->base);
    int64_t offset;
    if (!eval_address_constant(p, expr->d.binary.lhs, address) ||
        !address_nonzero(address) ||
        !eval_constant_expr(p, index, /*allow_addr=*/false, &offset))
      return false;
    if (index->type->is_unsigned && (uint64_t)offset > INT64_MAX)
      error_at(expr->loc, "address offset exceeds supported range");
    if (expr->kind == AST_PTR_SUB) {
      if (offset == INT64_MIN)
        error_at(expr->loc, "address offset exceeds supported range");
      offset = -offset;
    }
    if (offset > INT64_MAX / size || offset < INT64_MIN / size)
      error_at(expr->loc, "address offset exceeds supported range");
    add_address_offset(address, offset * size, expr->loc);
    return true;
  }
  default:
    return false;
  }
}

AstNode *sema_convert_expr(Parser *p, Type *target, AstNode *expr, Token loc,
                           const char *context) {
  AstNode *node;
  target = unqualified_type(target);
  expr = convert_to_value(expr);
  sema_check_nonvoid_expr(expr);
  if (same_type(target, expr->type))
    return expr;
  if (!(is_integer(target) && is_integer(expr->type)) &&
      !(target->kind == TYPE_BOOL && expr->type->kind == TYPE_PTR) &&
      !(compatible_pointers(target, expr->type) &&
        (!expr->type->base->is_const || target->base->is_const)) &&
      !(target->kind == TYPE_PTR && null_pointer_constant(p, expr)))
    error_at(loc, "incompatible %s type", context);
  node = new_expr(AST_CAST, target, expr->loc);
  node->d.unary.operand = expr;
  return node;
}

/*
 * Explicit casts permit scalar conversions beyond assignment compatibility.
 * Keep a node even for an unchanged type, since a cast never yields an lvalue.
 * Casting to void preserves the operand's side effects while discarding it.
 */
AstNode *sema_cast(Type *target, AstNode *expr, Token loc) {
  AstNode *node;
  if (target->kind != TYPE_VOID) {
    if (!is_integer(target) && target->kind != TYPE_PTR)
      error_at(loc, "cast target must be a scalar type or void");
    if (!is_integer(expr->type) && expr->type->kind != TYPE_PTR &&
        expr->type->kind != TYPE_ARRAY)
      error_at(expr->loc, "cast operand must have scalar type");
  }
  if (!is_record(expr->type))
    expr = convert_to_value(expr);
  node = new_expr(AST_CAST, target, loc);
  node->d.unary.operand = expr;
  return node;
}

void sema_check_call(Parser *p, Function *func, AstNode *call, int nargs) {
  AstNode **link;
  int i = 0;
  if (is_record(call->type) && type_size(call->type) < 0)
    error_at(call->loc, "function return type is incomplete");
  if (func->has_prototype &&
      (nargs < func->nparams || (!func->is_variadic && nargs > func->nparams)))
    error_at(call->loc, "wrong number of arguments to function '%.*s'",
             func->name.len, func->name.start);
  for (link = &call->d.call.args; *link; link = &(*link)->next, ++i) {
    AstNode *arg = *link;
    AstNode *next = arg->next;
    arg->next = NULL;
    sema_check_nonvoid_expr(arg);
    if (func->has_prototype && i < func->nparams)
      *link =
          sema_convert_expr(p, func->param_types[i], arg, arg->loc, "argument");
    else
      *link = promote_operand(arg);
    (*link)->next = next;
  }
}

void sema_check_return(Parser *p, AstNode *stmt) {
  Type *return_type = p->current_function->return_type;
  AstNode *expr = stmt->d.ret.expr;
  if (return_type->kind == TYPE_VOID) {
    if (expr)
      error_at(stmt->loc, "return with a value in void function");
    return;
  }
  stmt->d.ret.expr =
      sema_convert_expr(p, return_type, expr, stmt->loc, "return");
}

static bool is_lvalue(const AstNode *expr) {
  /*
   * A '.' member is an lvalue only if its record operand is an lvalue
   * (C11 6.5.2.3). A member of a record returned by value is not an lvalue.
   * We represent p->member as (*p).member; AST_DEREF is an lvalue.
   */
  if (expr->kind == AST_MEMBER)
    return is_lvalue(expr->d.member.base);
  return expr->kind == AST_VAR || expr->kind == AST_COMPOUND_LITERAL ||
         expr->kind == AST_DEREF || expr->kind == AST_STRING_LITERAL;
}

static bool is_modifiable_lvalue(const AstNode *expr) {
  return is_lvalue(expr) && expr->type->kind != TYPE_ARRAY &&
         type_size(expr->type) >= 0 && !contains_const(expr->type);
}

static bool is_increment_op(AstKind ty) {
  return ty == AST_PRE_INCREMENT || ty == AST_POST_INCREMENT;
}

static AstNode *new_expr(AstKind kind, Type *type, Token loc) {
  AstNode *node = calloc(1, sizeof(AstNode));
  if (!node)
    error_at(loc, "out of memory");
  node->kind = kind;
  node->type = type;
  node->loc = loc;
  return node;
}

static AstNode *check_va_list(AstNode *expr, bool writable) {
  expr = convert_to_value(expr);
  if (expr->type->kind != TYPE_PTR ||
      !same_type(unqualified_type(expr->type->base), builtin_type_va_list.base))
    error_at(expr->loc, "expect va_list argument");
  if (writable && contains_const(expr->type->base))
    error_at(expr->loc, "va_list argument is const-qualified");
  return expr;
}

AstNode *sema_builtin_va(Parser *p, AstKind kind, AstNode *first,
                         AstNode *second, Type *type, Token loc) {
  AstNode *node;
  if (kind == AST_VA_START) {
    if (!p->current_function || !p->current_function->is_variadic)
      error_at(loc, "va_start requires a variadic function");
    if (second->kind != AST_VAR || second->d.variable.var != p->last_parameter)
      error_at(second->loc, "va_start requires the last fixed parameter");
  }
  first = check_va_list(first, true);
  if (kind == AST_VA_COPY)
    second = check_va_list(second, false);
  if (kind == AST_VA_ARG) {
    if ((!is_integer(type) && type->kind != TYPE_PTR && !is_record(type)) ||
        type_size(type) < 0)
      error_at(loc,
               "va_arg requires a complete object type other than an array");
    if (is_integer(type) &&
        !same_type(unqualified_type(type), integer_promotion_type(type)))
      error_at(loc, "va_arg type is changed by default argument promotions");
    /*
     * The result is a value. Drop a top-level qualifier so a const aggregate
     * can initialize an object or be passed as the unqualified type.
     */
    type = unqualified_type(type);
  }
  node = new_expr(kind, type, loc);
  if (kind == AST_VA_START || kind == AST_VA_COPY) {
    node->d.binary.lhs = first;
    node->d.binary.rhs = second;
  } else {
    node->d.unary.operand = first;
  }
  return node;
}

/*
 * Select the first supported type that holds the literal (C11 6.4.4.1).
 * Decimal constants without U use signed types; octal may use unsigned.
 * Character constants always have type int.
 */
AstNode *sema_integer_literal(Token loc) {
  uint64_t value = loc.d.int_literal.val;
  bool is_unsigned = (loc.d.int_literal.suffix & INT_SUFFIX_UNSIGNED) != 0;
  bool is_long = (loc.d.int_literal.suffix & INT_SUFFIX_LONG) != 0;
  bool is_long_long = (loc.d.int_literal.suffix & INT_SUFFIX_LONG_LONG) != 0;
  bool decimal = loc.start[0] != '0';
  Type *type;
  AstNode *node;

  if (loc.start[0] == '\'')
    type = &builtin_type_int;
  else if (is_long_long) {
    if (is_unsigned || (!decimal && value > INT64_MAX))
      type = &builtin_type_unsigned_long_long;
    else if (value <= INT64_MAX)
      type = &builtin_type_long_long;
    else
      error_at(loc, "integer literal out of range for supported signed types");
  } else if (is_unsigned)
    type = !is_long && value <= UINT32_MAX ? &builtin_type_unsigned
                                           : &builtin_type_unsigned_long;
  else if (!is_long && value <= INT32_MAX)
    type = &builtin_type_int;
  else if (!is_long && !decimal && value <= UINT32_MAX)
    type = &builtin_type_unsigned;
  else if (value <= INT64_MAX)
    type = &builtin_type_long;
  else if (!decimal)
    type = &builtin_type_unsigned_long;
  else
    error_at(loc, "integer literal out of range for supported signed types");

  node = new_expr(AST_INT_LITERAL, type, loc);
  node->d.int_literal.val = value;
  return node;
}

AstNode *sema_string_literal(Token loc) {
  Type *type = array_of(&builtin_type_char, loc.d.string_literal.len);
  AstNode *node;
  if (!type)
    error_at(loc, "out of memory");
  node = new_expr(AST_STRING_LITERAL, type, loc);
  node->d.string_literal.val = loc.d.string_literal.val;
  return node;
}

/*
 * sizeof preserves the operand's type without value conversion or promotion.
 * All supported complete object types have constant size. size_t is unsigned
 * long on our LP64 target. Discard the operand tree so codegen cannot evaluate
 * it.
 */
AstNode *sema_sizeof(Type *type, Token loc) {
  AstNode *node;
  if (type->kind == TYPE_VOID)
    error_at(loc, "sizeof cannot be applied to void");
  if (type_size(type) < 0)
    error_at(loc, "sizeof cannot be applied to an incomplete type");
  node = new_expr(AST_INT_LITERAL, &builtin_type_unsigned_long, loc);
  node->d.int_literal.val = (uint64_t)type_size(type);
  return node;
}

AstNode *sema_unary(AstKind op, AstNode *operand, Token loc) {
  AstNode *node;
  Type *type;
  sema_check_nonvoid_expr(operand);

  switch (op) {
  case AST_NEG:
  case AST_BITWISE_NOT:
    operand = promote_operand(operand);
    if (!is_integer(operand->type))
      error_at(loc, "invalid operand to unary %s", op == AST_NEG ? "-" : "~");
    type = operand->type;
    break;
  case AST_LOGICAL_NOT:
    operand = sema_check_condition(operand);
    type = &builtin_type_int;
    break;
  case AST_DEREF:
    operand = convert_to_value(operand);
    if (operand->type->kind != TYPE_PTR ||
        operand->type->base->kind == TYPE_VOID)
      error_at(loc, "invalid deref target");
    type = operand->type->base;
    break;
  case AST_ADDR:
    if (!is_lvalue(operand))
      error_at(loc, "invalid address-of target");
    type = pointer_to(operand->type);
    if (!type)
      error_at(loc, "out of memory");
    break;
  case AST_PRE_INCREMENT:
  case AST_PRE_DECREMENT:
  case AST_POST_INCREMENT:
  case AST_POST_DECREMENT:
    if (!is_modifiable_lvalue(operand) || is_record(operand->type))
      error_at(loc, "invalid %s target",
               is_increment_op(op) ? "increment" : "decrement");
    if (operand->type->kind == TYPE_PTR &&
        operand->type->base->kind == TYPE_VOID)
      error_at(loc, "pointer arithmetic on void pointer");
    if (operand->type->kind == TYPE_PTR && type_size(operand->type->base) < 0)
      error_at(loc, "pointer arithmetic on incomplete type");
    type = operand->type;
    break;
  default:
    error_at(loc, "invalid unary operator");
  }

  node = new_expr(op, type, loc);
  node->d.unary.operand = operand;
  return node;
}

static AstNode *new_binary_expr(AstKind kind, AstNode *left, AstNode *right,
                                Type *type, Token loc) {
  AstNode *node = new_expr(kind, type, loc);
  node->d.binary.lhs = left;
  node->d.binary.rhs = right;
  return node;
}

/*
 * Promote integer operands and convert both to their common arithmetic type.
 * Shifts use separate promotions and must not use this common-type conversion.
 */
static Type *convert_integer_operands(Parser *p, AstNode **left,
                                      AstNode **right, Token loc) {
  Type *type;
  *left = promote_operand(*left);
  *right = promote_operand(*right);
  if (!is_integer((*left)->type) || !is_integer((*right)->type))
    error_at(loc, "invalid operands to integer operator");
  type = common_integer_type((*left)->type, (*right)->type);
  *left = sema_convert_expr(p, type, *left, loc, "operand");
  *right = sema_convert_expr(p, type, *right, loc, "operand");
  return type;
}

/*
 * Addition and subtraction select integer arithmetic, scaled pointer offsets,
 * or pointer difference. Normalize integer + pointer to pointer + integer.
 */
static AstNode *sema_additive(Parser *p, AstKind kind, AstNode *left,
                              AstNode *right, Token loc) {
  Type *type;
  if (is_integer(left->type) && is_integer(right->type)) {
    type = convert_integer_operands(p, &left, &right, loc);
    return new_binary_expr(kind, left, right, type, loc);
  }

  left = promote_operand(left);
  right = promote_operand(right);
  if ((left->type->kind == TYPE_PTR && left->type->base->kind == TYPE_VOID) ||
      (right->type->kind == TYPE_PTR && right->type->base->kind == TYPE_VOID))
    error_at(loc, "pointer arithmetic on void pointer");
  if ((left->type->kind == TYPE_PTR && type_size(left->type->base) < 0) ||
      (right->type->kind == TYPE_PTR && type_size(right->type->base) < 0))
    error_at(loc, "pointer arithmetic on incomplete type");
  if (kind == AST_ADD && left->type->kind != TYPE_PTR &&
      right->type->kind == TYPE_PTR) {
    AstNode *tmp = left;
    left = right;
    right = tmp;
  }

  if (left->type->kind == TYPE_PTR && right->type->kind == TYPE_PTR) {
    if (kind != AST_SUB)
      error_at(loc, "invalid operands to binary +");
    if (!same_type(unqualified_type(left->type->base),
                   unqualified_type(right->type->base)))
      error_at(loc, "pointer subtraction requires compatible types");
    /* Pointer difference has type ptrdiff_t, signed long on our target. */
    kind = AST_PTR_DIFF;
    type = &builtin_type_long;
  } else if (left->type->kind == TYPE_PTR) {
    if (!is_integer(right->type))
      error_at(loc, "pointer offset must have integer type");
    kind = kind == AST_ADD ? AST_PTR_ADD : AST_PTR_SUB;
    type = left->type;
  } else {
    error_at(loc, "invalid operands to binary %s", kind == AST_ADD ? "+" : "-");
  }
  return new_binary_expr(kind, left, right, type, loc);
}

AstNode *sema_binary(Parser *p, AstKind kind, AstNode *left, AstNode *right,
                     Token loc) {
  Type *type;
  if (kind != AST_COMMA) {
    sema_check_nonvoid_expr(left);
    sema_check_nonvoid_expr(right);
  }

  switch (kind) {
  case AST_COMMA:
    left = convert_to_value(left);
    right = convert_to_value(right);
    type = right->type;
    break;
  case AST_LOGICAL_AND:
  case AST_LOGICAL_OR:
    left = sema_check_condition(left);
    right = sema_check_condition(right);
    type = &builtin_type_int;
    break;
  case AST_MUL:
  case AST_DIV:
  case AST_MOD:
  case AST_BIT_AND:
  case AST_BIT_OR:
  case AST_BIT_XOR:
    type = convert_integer_operands(p, &left, &right, loc);
    break;
  case AST_LSHIFT:
  case AST_RSHIFT:
    left = promote_operand(left);
    right = promote_operand(right);
    if (!is_integer(left->type) || !is_integer(right->type))
      error_at(loc, "invalid operands to integer operator");
    type = left->type;
    break;
  case AST_ADD:
  case AST_SUB:
    return sema_additive(p, kind, left, right, loc);
  case AST_LT:
  case AST_LE:
  case AST_GT:
  case AST_GE:
  case AST_EQ:
  case AST_NE:
    if (is_record(left->type) || is_record(right->type))
      error_at(loc, "invalid operands to comparison");
    if (is_integer(left->type) && is_integer(right->type)) {
      convert_integer_operands(p, &left, &right, loc);
    } else {
      left = promote_operand(left);
      right = promote_operand(right);
    }
    type = &builtin_type_int;
    break;
  default:
    error_at(loc, "invalid binary operator");
  }
  return new_binary_expr(kind, left, right, type, loc);
}

/* C11 6.5.2.1: E1[E2] is identical to *((E1) + (E2)). */
AstNode *sema_subscript(Parser *p, AstNode *base, AstNode *index, Token loc) {
  base = convert_to_value(base);
  index = convert_to_value(index);
  if (!((base->type->kind == TYPE_PTR && is_integer(index->type)) ||
        (is_integer(base->type) && index->type->kind == TYPE_PTR)))
    error_at(loc, "subscript requires a pointer and an integer");
  return sema_unary(AST_DEREF, sema_binary(p, AST_ADD, base, index, loc), loc);
}

/*
 * C11 6.5.2.3: p->member is (*p).member. Keep record and array member
 * types intact so further member access, address-of, and array decay work.
 */
AstNode *sema_member(AstNode *base, Token op, Token name) {
  if (op.kind == TOKEN_ARROW) {
    base = convert_to_value(base);
    if (base->type->kind != TYPE_PTR || !is_record(base->type->base))
      error_at(op, "'->' requires a pointer to struct or union");
    base = sema_unary(AST_DEREF, base, op);
  } else if (!is_record(base->type)) {
    error_at(op, "'.' requires a struct or union operand");
  } else if (!is_lvalue(base)) {
    base = convert_to_value(base);
  }
  if (type_size(base->type) < 0)
    error_at(op, "member access on incomplete %s",
             base->type->kind == TYPE_STRUCT ? "struct" : "union");
  for (;;) {
    Member *member = find_member(base->type, name);
    AstNode *node;
    if (!member)
      error_at(name, "no member named '%.*s' in %s", name.len, name.start,
               base->type->kind == TYPE_STRUCT ? "struct" : "union");
    node = new_expr(AST_MEMBER, member->type, op);
    if (base->type->is_const) {
      node->type = const_type(node->type);
      if (!node->type)
        error_at(op, "out of memory");
    }
    node->d.member.base = base;
    node->d.member.member = member;
    if (member->name.kind == TOKEN_IDENTIFIER)
      return node;
    /*
     * Preserve each anonymous container so layout offsets and const
     * qualification apply at every step of the member path.
     */
    base = node;
  }
}

AstNode *sema_assignment(Parser *p, Token operator, AstNode *left,
                         AstNode *rhs) {
  TokenKind op = operator.kind;
  Token loc = operator;
  AstNode *node;
  if (!is_modifiable_lvalue(left))
    error_at(loc, "invalid assignment target");
  sema_check_nonvoid_expr(rhs);
  if (op != TOKEN_ASSIGN) {
    if (left->type->kind == TYPE_PTR && left->type->base->kind == TYPE_VOID)
      error_at(loc, "pointer arithmetic on void pointer");
    if (left->type->kind == TYPE_PTR && type_size(left->type->base) < 0)
      error_at(loc, "pointer arithmetic on incomplete type");
    AstNode *binop;
    AstKind binop_ty;

    switch (op) {
    case TOKEN_PLUS_EQ:
      /* p += 1 on a pointer steps by the pointee's size. */
      binop_ty = AST_ADD;
      break;
    case TOKEN_MINUS_EQ:
      binop_ty = AST_SUB;
      break;
    case TOKEN_STAR_EQ:
      binop_ty = AST_MUL;
      break;
    case TOKEN_SLASH_EQ:
      binop_ty = AST_DIV;
      break;
    case TOKEN_PERCENT_EQ:
      binop_ty = AST_MOD;
      break;
    case TOKEN_LSHIFT_EQ:
      binop_ty = AST_LSHIFT;
      break;
    case TOKEN_RSHIFT_EQ:
      binop_ty = AST_RSHIFT;
      break;
    case TOKEN_BIT_AND_EQ:
      binop_ty = AST_BIT_AND;
      break;
    case TOKEN_BIT_XOR_EQ:
      binop_ty = AST_BIT_XOR;
      break;
    case TOKEN_BIT_OR_EQ:
      binop_ty = AST_BIT_OR;
      break;
    default:
      error_at(loc, "invalid assignment operator");
    }

    /*
     * Reuse binary operand checks and conversions, then validate assignment
     * back to the target type. Keep the original lvalue separately so codegen
     * evaluates its address once (C11 6.5.16.2), without emitting binop's lhs.
     */
    binop = sema_binary(p, binop_ty, left, rhs, loc);
    sema_convert_expr(p, left->type, binop, loc, "assignment");
    node = new_expr(AST_COMPOUND_ASSIGN, left->type, loc);
    node->d.compound_assign.lhs = left;
    node->d.compound_assign.rhs = binop->d.binary.rhs;
    node->d.compound_assign.op = binop->kind;
    node->d.compound_assign.operation_type = binop->type;
    return node;
  }

  rhs = sema_convert_expr(p, left->type, rhs, loc, "assignment");
  node = new_expr(AST_ASSIGN, unqualified_type(left->type), loc);
  node->d.binary.lhs = left;
  node->d.binary.rhs = rhs;
  return node;
}

AstNode *sema_conditional(Parser *p, AstNode *cond, AstNode *then_expr,
                          AstNode *else_expr, Token loc) {
  Type *type;
  AstNode *node;
  cond = sema_check_condition(cond);
  if (is_integer(then_expr->type) && is_integer(else_expr->type)) {
    then_expr = promote_operand(then_expr);
    else_expr = promote_operand(else_expr);
  } else {
    then_expr = convert_to_value(then_expr);
    else_expr = convert_to_value(else_expr);
  }
  type = then_expr->type;
  if (is_integer(type) && is_integer(else_expr->type)) {
    type = common_integer_type(type, else_expr->type);
  } else if (!same_type(type, else_expr->type)) {
    if (type->kind == TYPE_PTR && null_pointer_constant(p, else_expr)) {
      /* The pointer branch determines the result type. */
    } else if (else_expr->type->kind == TYPE_PTR &&
               null_pointer_constant(p, then_expr)) {
      type = else_expr->type;
    } else if (compatible_pointers(type, else_expr->type)) {
      Type *base = type->base;
      if (else_expr->type->base->kind == TYPE_VOID)
        base = else_expr->type->base;
      if (type->base->is_const || else_expr->type->base->is_const)
        base = const_type(base);
      if (!base)
        error_at(loc, "out of memory");
      type = pointer_to(base);
      if (!type)
        error_at(loc, "out of memory");
    } else {
      error_at(loc, "incompatible conditional operand types");
    }
  }
  if (type->kind != TYPE_VOID) {
    then_expr =
        sema_convert_expr(p, type, then_expr, loc, "conditional operand");
    else_expr =
        sema_convert_expr(p, type, else_expr, loc, "conditional operand");
  }
  node = new_expr(AST_CONDITIONAL, type, loc);
  node->d.conditional.cond = cond;
  node->d.conditional.then_expr = then_expr;
  node->d.conditional.else_expr = else_expr;
  return node;
}

/*
 * Constant values use int64_t to carry signed values or unsigned bit patterns.
 * Convert high unsigned values without relying on an out-of-range signed cast.
 */
static int64_t integer_from_bits(uint64_t bits) {
  return bits <= INT64_MAX ? (int64_t)bits : -1 - (int64_t)(UINT64_MAX - bits);
}

/*
 * Arithmetic is promoted to int or long. Unsigned results wrap to the type's
 * width; signed 64-bit overflow is checked before performing the operation.
 */
static int64_t checked_integer(Parser *p, Type *type, int64_t val) {
  if (type->size == 8)
    return val;
  if (type->is_unsigned)
    return (uint32_t)val;
  if (val < INT32_MIN || val > INT32_MAX)
    error_at(p->current, "integer overflow in constant expression");
  return val;
}

/*
 * Both evaluation contexts share integer arithmetic, including target-width
 * wrapping and diagnostics for undefined operations.
 */
static int64_t eval_integer_binary(Parser *p, AstNode *expr, int64_t lhs,
                                   int64_t rhs) {
  int width = expr->type->size * 8;
  bool unsigned_comparison = expr->d.binary.lhs->type->is_unsigned;

  switch (expr->kind) {
  case AST_ADD:
    if (expr->type->is_unsigned)
      return checked_integer(p, expr->type,
                             integer_from_bits((uint64_t)lhs + (uint64_t)rhs));
    if ((rhs > 0 && lhs > INT64_MAX - rhs) ||
        (rhs < 0 && lhs < INT64_MIN - rhs))
      error_at(p->current, "integer overflow in constant expression");
    return checked_integer(p, expr->type, lhs + rhs);
  case AST_SUB:
    if (expr->type->is_unsigned)
      return checked_integer(p, expr->type,
                             integer_from_bits((uint64_t)lhs - (uint64_t)rhs));
    if ((rhs > 0 && lhs < INT64_MIN + rhs) ||
        (rhs < 0 && lhs > INT64_MAX + rhs))
      error_at(p->current, "integer overflow in constant expression");
    return checked_integer(p, expr->type, lhs - rhs);
  case AST_MUL: {
    if (expr->type->is_unsigned)
      return checked_integer(p, expr->type,
                             integer_from_bits((uint64_t)lhs * (uint64_t)rhs));
    bool negative = (lhs < 0) != (rhs < 0);
    uint64_t a = lhs < 0 ? 0 - (uint64_t)lhs : (uint64_t)lhs;
    uint64_t b = rhs < 0 ? 0 - (uint64_t)rhs : (uint64_t)rhs;
    uint64_t limit = (uint64_t)INT64_MAX + negative;
    if (b && a > limit / b)
      error_at(p->current, "integer overflow in constant expression");
    uint64_t product = a * b;
    return checked_integer(p, expr->type,
                           integer_from_bits(negative ? 0 - product : product));
  }
  case AST_DIV:
  case AST_MOD:
    if (rhs == 0)
      error_at(p->current, "division by zero in constant expression");
    if (expr->type->is_unsigned)
      return checked_integer(
          p, expr->type,
          integer_from_bits(expr->kind == AST_DIV
                                ? (uint64_t)lhs / (uint64_t)rhs
                                : (uint64_t)lhs % (uint64_t)rhs));
    if (lhs == (width == 64 ? INT64_MIN : INT32_MIN) && rhs == -1)
      error_at(p->current, "integer overflow in constant expression");
    return checked_integer(p, expr->type,
                           expr->kind == AST_DIV ? lhs / rhs : lhs % rhs);
  case AST_LSHIFT:
    if (rhs < 0 || rhs >= width)
      error_at(p->current, "invalid shift count in constant expression");
    if (!expr->type->is_unsigned) {
      if (lhs < 0)
        error_at(p->current,
                 "left shift of negative value in constant expression");
      uint64_t limit = width == 64 ? INT64_MAX : INT32_MAX;
      if ((uint64_t)lhs > (limit >> rhs))
        error_at(p->current, "integer overflow in constant expression");
    }
    return checked_integer(p, expr->type,
                           integer_from_bits((uint64_t)lhs << rhs));
  case AST_RSHIFT:
    if (rhs < 0 || rhs >= width)
      error_at(p->current, "invalid shift count in constant expression");
    if (expr->type->is_unsigned || lhs >= 0)
      return checked_integer(p, expr->type,
                             integer_from_bits((uint64_t)lhs >> rhs));
    return checked_integer(p, expr->type,
                           integer_from_bits(~(~(uint64_t)lhs >> rhs)));
  case AST_LT:
    return unsigned_comparison ? (uint64_t)lhs < (uint64_t)rhs : lhs < rhs;
  case AST_LE:
    return unsigned_comparison ? (uint64_t)lhs <= (uint64_t)rhs : lhs <= rhs;
  case AST_GT:
    return unsigned_comparison ? (uint64_t)lhs > (uint64_t)rhs : lhs > rhs;
  case AST_GE:
    return unsigned_comparison ? (uint64_t)lhs >= (uint64_t)rhs : lhs >= rhs;
  case AST_EQ:
    return lhs == rhs;
  case AST_NE:
    return lhs != rhs;
  case AST_BIT_AND:
    return checked_integer(p, expr->type, lhs & rhs);
  case AST_BIT_XOR:
    return checked_integer(p, expr->type, lhs ^ rhs);
  case AST_BIT_OR:
    return checked_integer(p, expr->type, lhs | rhs);
  default:
    error_at(p->current, "invalid constant expression");
  }
}

/*
 * Conditions accept either an integer result or, when allowed, an address.
 * The expression's type selects the evaluator, so no result tag is needed.
 */
static bool eval_constant_condition(Parser *p, AstNode *expr, bool allow_addr,
                                    bool *result) {
  if (expr->type->kind == TYPE_PTR) {
    AddressConstant address;
    if (!allow_addr || !eval_address_constant(p, expr, &address))
      return false;
    *result = address_nonzero(&address);
    return true;
  }
  int64_t value;
  if (!eval_constant_expr(p, expr, /*allow_addr=*/allow_addr, &value))
    return false;
  *result = value != 0;
  return true;
}

/*
 * Separate AST_VAR expressions can name the same object. Distinct string
 * literals may be merged by the implementation, so do not assume inequality.
 */
static bool same_address_base(AstNode *a, AstNode *b) {
  return a == b || (a && b && a->kind == AST_VAR && b->kind == AST_VAR &&
                    a->d.variable.var == b->d.variable.var);
}

/*
 * A pointer comparison may also have an integer zero as its null operand.
 */
static bool eval_comparison_address(Parser *p, AstNode *expr,
                                    AddressConstant *address) {
  if (expr->type->kind == TYPE_PTR)
    return eval_address_constant(p, expr, address);
  int64_t value;
  if (!eval_constant_expr(p, expr, /*allow_addr=*/true, &value) || value != 0)
    return false;
  *address = (AddressConstant){0};
  return true;
}

static bool eval_address_comparison(Parser *p, AstNode *expr, int64_t *result) {
  AstNode *lhs = expr->d.binary.lhs;
  AstNode *rhs = expr->d.binary.rhs;
  AddressConstant left, right;
  bool equality = expr->kind == AST_EQ || expr->kind == AST_NE;
  if (!equality && (lhs->type->kind != TYPE_PTR || rhs->type->kind != TYPE_PTR))
    return false;
  if (!eval_comparison_address(p, lhs, &left) ||
      !eval_comparison_address(p, rhs, &right))
    return false;
  if (!same_address_base(left.base, right.base)) {
    if (!equality || (address_nonzero(&left) && address_nonzero(&right)))
      return false;
    *result = expr->kind == AST_NE;
    return true;
  }
  if (equality) {
    bool equal = left.offset == right.offset;
    *result = expr->kind == AST_EQ ? equal : !equal;
    return true;
  }
  /*
   * Relational comparisons are folded only within the same static object.
   */
  if (!left.base)
    return false;
  switch (expr->kind) {
  case AST_LT:
    *result = left.offset < right.offset;
    return true;
  case AST_LE:
    *result = left.offset <= right.offset;
    return true;
  case AST_GT:
    *result = left.offset > right.offset;
    return true;
  case AST_GE:
    *result = left.offset >= right.offset;
    return true;
  default:
    return false;
  }
}

/*
 * Evaluate integer results recursively. With allow_addr, casts to _Bool,
 * comparisons and conditions may consume addresses through the pointer
 * evaluator. Calls, reads and side effects fail in evaluated branches.
 */
static bool eval_constant_expr(Parser *p, AstNode *expr, bool allow_addr,
                               int64_t *result) {
  int64_t left, right;
  bool condition;
  if (!is_integer(expr->type))
    return false;
  switch (expr->kind) {
  case AST_INT_LITERAL:
    *result = integer_from_bits(expr->d.int_literal.val);
    return true;
  case AST_CAST: {
    AstNode *operand = expr->d.unary.operand;
    if (expr->type->kind == TYPE_BOOL) {
      if (!eval_constant_condition(p, operand, /*allow_addr=*/allow_addr,
                                   &condition))
        return false;
      *result = condition;
      return true;
    }
    if (!eval_constant_expr(p, operand, /*allow_addr=*/allow_addr, &left))
      return false;
    if (expr->type->size < 8) {
      int width = expr->type->size * 8;
      int64_t modulus = INT64_C(1) << width;
      left = (uint64_t)left & (uint64_t)(modulus - 1);
      if (!expr->type->is_unsigned && left >= modulus / 2)
        left -= modulus;
    }
    *result = left;
    return true;
  }
  case AST_CONDITIONAL:
    if (!eval_constant_condition(p, expr->d.conditional.cond,
                                 /*allow_addr=*/allow_addr, &condition))
      return false;
    return eval_constant_expr(p,
                              condition ? expr->d.conditional.then_expr
                                        : expr->d.conditional.else_expr,
                              /*allow_addr=*/allow_addr, result);
  case AST_LOGICAL_AND:
  case AST_LOGICAL_OR:
    if (!eval_constant_condition(p, expr->d.binary.lhs,
                                 /*allow_addr=*/allow_addr, &condition))
      return false;
    if ((expr->kind == AST_LOGICAL_AND && !condition) ||
        (expr->kind == AST_LOGICAL_OR && condition)) {
      *result = condition;
      return true;
    }
    if (!eval_constant_condition(p, expr->d.binary.rhs,
                                 /*allow_addr=*/allow_addr, &condition))
      return false;
    *result = condition;
    return true;
  case AST_LOGICAL_NOT:
    if (!eval_constant_condition(p, expr->d.unary.operand,
                                 /*allow_addr=*/allow_addr, &condition))
      return false;
    *result = !condition;
    return true;
  case AST_NEG:
  case AST_BITWISE_NOT:
    if (!eval_constant_expr(p, expr->d.unary.operand, /*allow_addr=*/allow_addr,
                            &left))
      return false;
    if (expr->kind == AST_NEG) {
      if (!expr->type->is_unsigned && left == INT64_MIN)
        error_at(p->current, "integer overflow in constant expression");
      *result =
          checked_integer(p, expr->type, integer_from_bits(0 - (uint64_t)left));
    } else {
      *result = checked_integer(p, expr->type, ~left);
    }
    return true;
  case AST_LT:
  case AST_LE:
  case AST_GT:
  case AST_GE:
  case AST_EQ:
  case AST_NE:
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
    if (expr->d.binary.lhs->type->kind == TYPE_PTR ||
        expr->d.binary.rhs->type->kind == TYPE_PTR)
      return allow_addr && eval_address_comparison(p, expr, result);
    if (!eval_constant_expr(p, expr->d.binary.lhs, /*allow_addr=*/allow_addr,
                            &left) ||
        !eval_constant_expr(p, expr->d.binary.rhs, /*allow_addr=*/allow_addr,
                            &right))
      return false;
    *result = eval_integer_binary(p, expr, left, right);
    return true;
  default:
    return false;
  }
}

/* Evaluate an integer constant expression (C11 6.6). */
int64_t eval_const_expr(Parser *p, AstNode *expr) {
  int64_t value;
  if (!eval_constant_expr(p, expr, /*allow_addr=*/false, &value))
    error_at(p->current, "not an integer constant expression");
  return value;
}

/*
 * (C11 6.5.2.2) A function declaration is sufficient for code generation:
 * definitions may be in another translation unit.
 */
void check_calls(Parser *p) {
  CallRef *ref;

  for (ref = p->call_refs; ref; ref = ref->next)
    sema_check_call(p, ref->call->d.call.function, ref->call, ref->nargs);
}

/*
 * Every 'goto' must refer to a label declared somewhere in the function;
 * labels have function scope and may be declared after the goto.
 */
void check_gotos(Parser *p) {
  GotoRef *ref;

  for (ref = p->goto_refs; ref; ref = ref->next) {
    if (!hashtable_contains(&p->labels, ref->name.start,
                            (size_t)ref->name.len)) {
      error_at(ref->loc, "label '%.*s' not defined", ref->name.len,
               ref->name.start);
    }
  }
}
