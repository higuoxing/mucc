/*
 * Preprocessor for the self-hosted C compiler
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

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "error.h"
#include "preprocessor.h"

/* Match GCC and Clang's default limit */
#define MAX_INCLUDE_DEPTH 200

/*
 * One saved scanner state per open include; `outer` links to the enclosing
 * file.
 */
struct IncludeFrame {
  Lexer lexer;
  struct IncludeFrame *outer;
  /*
   * Conditionals cannot span a file boundary, so the depth at entry is
   * recorded and checked when the file ends.
   */
  int conditional_depth;
};

/* One conditional-compilation level, from #if to its #endif. */
typedef struct {
  bool active;        /* This branch is being compiled. */
  SourcePosition loc; /* The opening directive, for diagnostics. */
} ConditionalFrame;

/*
 * A macro stores its parameter names and unexpanded replacement tokens.
 */
struct Macro {
  Token name;
  bool function_like;
  Vector params; /* Token elements; empty for object-like macros. */
  Vector tokens; /* The replacement list, in source order. */
  struct Macro *next;
};

/*
 * A token's hide set records macros that cannot expand it again. Keeping this
 * on tokens preserves recursion suppression across argument substitution.
 */
typedef struct HideSet HideSet;
struct HideSet {
  Macro *macro;
  const HideSet *next;
};

struct MacroToken {
  Token token;
  const HideSet *hideset;
  MacroToken *next;
};

/*
 * An argument or #if expression ends at its own EOF. Ordinary expansion can
 * continue into source tokens after exhausting a replacement list.
 */
typedef struct {
  Preprocessor *pp;
  MacroToken *pending;
  bool read_source;
  bool condition;
  Token end;
} TokenStream;

typedef struct {
  MacroToken *tokens;
  MacroToken *expanded;
  bool expanded_ready;
} MacroArgument;

/*
 * State for evaluating a controlling constant expression (C11 6.10.1p4), used
 * by #if. The tokens are already lexed, so this is a cursor over them.
 */
typedef struct {
  const Vector *tokens; /* Token elements; not owned. */
  int index;            /* Next token to read. */
  Token end;            /* Location just past the last token. */
} PPExpression;

/*
 * Preprocessing identifiers include C keywords. Keyword classification is
 * relevant to the parser, but must not prevent macro lookup or defined().
 */
static bool is_pp_identifier(Token tok) {
  return tok.len > 0 &&
         (isalpha((unsigned char)tok.start[0]) || tok.start[0] == '_');
}

/*
 * Values use target-width bits, with signedness retained through conversions.
 */
typedef struct {
  uint64_t bits;
  bool is_unsigned;
} PPValue;

void pp_init(Preprocessor *pp, const SourceFile *file,
             const Vector *include_paths) {
  lexer_init(&pp->lexer, file);
  pp->include_frames = NULL;
  pp->include_paths = include_paths;
  pp->include_depth = 0;
  pp->macros = NULL;
  pp->pending = NULL;
  vector_init(&pp->conditionals, sizeof(ConditionalFrame));
}

static Macro *find_macro(const Preprocessor *pp, Token name) {
  Macro *macro;
  for (macro = pp->macros; macro; macro = macro->next)
    if (same_identifier(macro->name, name))
      return macro;
  return NULL;
}

static char *copy_text(const char *text, size_t len) {
  char *copy = malloc(len + 1);
  if (!copy)
    return NULL;
  memcpy(copy, text, len);
  copy[len] = '\0';
  return copy;
}

static char *path_join(const char *dir, const char *name) {
  size_t dir_len = strlen(dir);
  size_t name_len = strlen(name);
  int need_slash = dir_len > 0 && dir[dir_len - 1] != '/';
  char *path = malloc(dir_len + (size_t)need_slash + name_len + 1);
  if (!path)
    return NULL;
  memcpy(path, dir, dir_len);
  if (need_slash)
    path[dir_len] = '/';
  memcpy(path + dir_len + (size_t)need_slash, name, name_len + 1);
  return path;
}

static char *path_directory(const char *path) {
  const char *slash = strrchr(path, '/');
  if (!slash)
    return copy_text(".", 1);
  if (slash == path)
    return copy_text("/", 1);
  return copy_text(path, (size_t)(slash - path));
}

static void push_include(Preprocessor *pp, const SourceFile *file) {
  IncludeFrame *frame = malloc(sizeof(*frame));
  if (!frame)
    error_at(lexer_position(&pp->lexer), "out of memory");
  frame->lexer = pp->lexer;
  frame->outer = pp->include_frames;
  frame->conditional_depth = (int)pp->conditionals.len;
  pp->include_frames = frame;
  lexer_init(&pp->lexer, file);
  pp->include_depth++;
}

/* A #if cannot span files, so any level still open here began inside. */
static ConditionalFrame *top_conditional(const Preprocessor *pp) {
  if (!pp->conditionals.len)
    return NULL;
  return &((ConditionalFrame *)pp->conditionals.data)[pp->conditionals.len - 1];
}

/* Included buffers stay allocated: tokens point into them until exit. */
static bool pop_include(Preprocessor *pp) {
  IncludeFrame *frame = pp->include_frames;
  ConditionalFrame *open;
  if (!frame)
    return false;
  open = top_conditional(pp);
  if (open && (int)pp->conditionals.len > frame->conditional_depth)
    error_at(open->loc, "unterminated conditional directive");
  pp->lexer = frame->lexer;
  pp->include_frames = frame->outer;
  pp->include_depth--;
  free(frame);
  return true;
}

/* True when every enclosing conditional is taking its branch. */
static bool conditionals_active(const Preprocessor *pp) {
  ConditionalFrame *frame = top_conditional(pp);
  return !frame || frame->active;
}

static void push_conditional(Preprocessor *pp, bool active,
                             SourcePosition loc) {
  ConditionalFrame frame;
  frame.active = active;
  frame.loc = loc;
  if (!vector_push(&pp->conditionals, &frame))
    error_at(pp->lexer, "out of memory");
}

static void pop_conditional(Preprocessor *pp, SourcePosition loc) {
  if (!pp->conditionals.len)
    error_at(loc, "#endif without #if");
  pp->conditionals.len--;
}

/* Try one candidate path, returning NULL when it cannot be opened. */
static SourceFile *try_path(const char *path) {
  SourceFile *file = new_source_file(path);
  if (!file)
    free((char *)path);
  return file;
}

/*
 * "..." searches the including file's directory, then each -I directory.
 * <...> searches only the -I directories. An absolute name is opened as given.
 */
static void include_file(Preprocessor *pp, const char *header, bool quoted,
                         SourcePosition loc) {
  const char *const *paths = pp->include_paths->data;
  const SourceFile *file = NULL;
  size_t i;

  if (pp->include_depth >= MAX_INCLUDE_DEPTH)
    error_at(loc, "include nesting is too deep");

  if (header[0] == '/') {
    file = try_path(copy_text(header, strlen(header)));
  } else {
    if (quoted) {
      char *dir = path_directory(file_name(pp->lexer.file));
      if (!dir)
        error_at(loc, "out of memory");
      file = try_path(path_join(dir, header));
      free(dir);
    }
    for (i = 0; !file && i < pp->include_paths->len; ++i)
      file = try_path(path_join(paths[i], header));
  }

  if (!file)
    error_at(loc, "cannot find include file '%s'", header);
  push_include(pp, file);
}

/* Header names are literal text, not string literals: escapes stay intact. */
static char *read_header_name(Preprocessor *pp, bool *quoted) {
  Lexer *l = &pp->lexer;
  char open;
  char close;
  const char *start;
  const char *end;
  char *name;
  SourcePosition loc = lexer_position(l);

  open = *l->cursor;
  if (open == '"') {
    *quoted = true;
    close = '"';
  } else if (open == '<') {
    *quoted = false;
    close = '>';
  } else {
    error_at(loc, "#include expects a header name");
  }
  lexer_advance(l);
  start = l->cursor;
  while (*l->cursor != close) {
    if (*l->cursor == '\0' || *l->cursor == '\n' || *l->cursor == '\r')
      error_at(loc, "unterminated header name");
    lexer_advance(l);
  }
  end = l->cursor;
  lexer_advance(l);
  if (start == end)
    error_at(loc, "empty include file name");
  name = copy_text(start, (size_t)(end - start));
  if (!name)
    error_at(loc, "out of memory");
  return name;
}

static void finish_directive_line(Preprocessor *pp) {
  Lexer *l = &pp->lexer;
  lexer_skip_horizontal(l);
  if (*l->cursor != '\0' && *l->cursor != '\n' && *l->cursor != '\r')
    error_at(lexer_position(l), "extra tokens at end of #include directive");
  if (*l->cursor == '\n' || *l->cursor == '\r')
    lexer_advance(l);
}

/*
 * Read the rest of a directive as preprocessing tokens. The lexer's directive
 * mode stops at the newline, so the caller must consume that newline. The
 * vector owns its storage; each token points into the source. Return the end
 * token to preserve the physical location of a continued directive's end.
 */
static Token directive_tokens(Preprocessor *pp, Vector *out) {
  Lexer saved = pp->lexer;
  Token tok;
  pp->lexer.in_directive = true;
  for (;;) {
    tok = lexer_next_token(&pp->lexer);
    if (tok.kind == TOKEN_EOF)
      break;
    if (!vector_push(out, &tok))
      error_at(tok, "out of memory");
  }
  /*
   * Restore the caller's directive mode and consume the logical newline.
   */
  pp->lexer.in_directive = saved.in_directive;
  if (*pp->lexer.cursor == '\n' || *pp->lexer.cursor == '\r')
    lexer_advance(&pp->lexer);
  return tok;
}

/*
 * Redefinitions compare spelling and whitespace between tokens, not locations,
 * decoded payload pointers, or padding bytes in the Token representation.
 * Leading and trailing whitespace and the amount of separating space do not
 * matter. Definition tokens still point into their original source buffer.
 */
static bool is_same_replacement(const Vector *a, const Vector *b) {
  const Token *left = a->data;
  const Token *right = b->data;
  size_t i;
  if (a->len != b->len)
    return false;
  for (i = 0; i < a->len; ++i) {
    if (left[i].kind != right[i].kind || left[i].len != right[i].len ||
        memcmp(left[i].start, right[i].start, (size_t)left[i].len) != 0)
      return false;
    if (i > 0) {
      bool left_space = left[i].start != left[i - 1].start + left[i - 1].len;
      bool right_space =
          right[i].start != right[i - 1].start + right[i - 1].len;
      if (left_space != right_space)
        return false;
    }
  }
  return true;
}

/*
 * The opening parenthesis is adjacent to the macro name. Return the first
 * replacement-token index, after the closing parenthesis.
 */
static size_t parse_macro_params(const Vector *tokens, Token end,
                                 Vector *params) {
  const Token *items = tokens->data;
  size_t i = 1;
  if (i < tokens->len && items[i].kind == TOKEN_RPAREN)
    return i + 1;
  for (;;) {
    size_t j;
    Token name = i < tokens->len ? items[i] : end;
    if (name.kind == TOKEN_ELLIPSIS)
      error_at(name, "variadic macros are not supported yet");
    if (!is_pp_identifier(name))
      error_at(name, "expect macro parameter name");
    for (j = 0; j < params->len; ++j)
      if (same_identifier(((Token *)params->data)[j], name))
        error_at(name, "duplicate macro parameter '%.*s'", name.len,
                 name.start);
    if (!vector_push(params, &name))
      error_at(name, "out of memory");
    ++i;
    Token separator = i < tokens->len ? items[i] : end;
    if (separator.kind == TOKEN_RPAREN)
      return i + 1;
    if (separator.kind != TOKEN_COMMA)
      error_at(separator, "expect ',' or ')' in macro parameter list");
    ++i;
  }
}

static bool is_same_parameters(const Vector *a, const Vector *b) {
  size_t i;
  if (a->len != b->len)
    return false;
  for (i = 0; i < a->len; ++i)
    if (!same_identifier(((Token *)a->data)[i], ((Token *)b->data)[i]))
      return false;
  return true;
}

static void define_macro(Preprocessor *pp) {
  Lexer *l = &pp->lexer;
  Token name;
  Token end;
  Vector params;
  Vector tokens;
  Macro *macro;
  bool function_like;
  size_t i;

  lexer_skip_horizontal(l);
  if (!(isalpha((unsigned char)*l->cursor) || *l->cursor == '_'))
    error_at(lexer_position(l), "expect macro name");
  name = lexer_next_token(l);
  function_like = *l->cursor == '(';
  vector_init(&params, sizeof(Token));
  vector_init(&tokens, sizeof(Token));
  end = directive_tokens(pp, &tokens);
  if (function_like) {
    size_t first = parse_macro_params(&tokens, end, &params);
    tokens.len -= first;
    for (i = 0; i < tokens.len; ++i)
      ((Token *)tokens.data)[i] = ((Token *)tokens.data)[i + first];
  }
  for (i = 0; i < tokens.len; ++i) {
    Token tok = ((Token *)tokens.data)[i];
    if (tok.len == 1 && tok.start[0] == '#')
      error_at(tok,
               "macro stringification and token pasting are not supported yet");
  }

  macro = find_macro(pp, name);
  if (macro) {
    if (macro->function_like != function_like ||
        !is_same_parameters(&macro->params, &params) ||
        !is_same_replacement(&macro->tokens, &tokens))
      error_at(name, "'%.*s' redefined", name.len, name.start);
    vector_free(&params);
    vector_free(&tokens);
    return;
  }

  macro = calloc(1, sizeof(*macro));
  if (!macro)
    error_at(name, "out of memory");
  macro->name = name;
  macro->function_like = function_like;
  macro->params = params;
  macro->tokens = tokens;
  macro->next = pp->macros;
  pp->macros = macro;
}

static void undef_macro(Preprocessor *pp) {
  Lexer *l = &pp->lexer;
  Token name;
  Macro **link;

  lexer_skip_horizontal(l);
  if (!(isalpha((unsigned char)*l->cursor) || *l->cursor == '_'))
    error_at(lexer_position(l), "expect macro name");
  name = lexer_next_token(l);
  /* Undefining a name that is not defined is not an error (C11 6.10.3.5). */
  for (link = &pp->macros; *link; link = &(*link)->next)
    if (same_identifier((*link)->name, name)) {
      *link = (*link)->next;
      break;
    }
  lexer_skip_horizontal(l);
  if (*l->cursor != '\0' && *l->cursor != '\n' && *l->cursor != '\r')
    error_at(lexer_position(l), "extra tokens at end of #undef directive");
  if (*l->cursor == '\n' || *l->cursor == '\r')
    lexer_advance(l);
}

/* #include "..." or #include <...> */
static void include_directive(Preprocessor *pp) {
  bool quoted = false;
  char *header;
  SourcePosition header_loc;

  lexer_skip_horizontal(&pp->lexer);
  header_loc = lexer_position(&pp->lexer);
  header = read_header_name(pp, &quoted);
  finish_directive_line(pp);
  include_file(pp, header, quoted, header_loc);
  free(header);
}

/* Discard the rest of a directive, including its newline. */
static void skip_directive_line(Preprocessor *pp) {
  Lexer *l = &pp->lexer;
  while (*l->cursor != '\0' && *l->cursor != '\n' && *l->cursor != '\r')
    lexer_advance(l);
  if (*l->cursor == '\n' || *l->cursor == '\r')
    lexer_advance(l);
}

/* The name after #ifdef or #ifndef. */
static Token conditional_name(Preprocessor *pp) {
  Lexer *l = &pp->lexer;
  Token name;
  lexer_skip_horizontal(l);
  if (!(isalpha((unsigned char)*l->cursor) || *l->cursor == '_'))
    error_at(lexer_position(l), "expect macro name");
  name = lexer_next_token(l);
  finish_directive_line(pp);
  return name;
}

static void ifdef_directive(Preprocessor *pp, bool expect_defined) {
  SourcePosition loc = lexer_position(&pp->lexer);
  Token name = conditional_name(pp);
  bool defined = find_macro(pp, name) != NULL;
  /*
   * An inactive outer branch keeps everything inside it inactive, whatever
   * this condition says.
   */
  bool active = conditionals_active(pp) && (defined == expect_defined);
  push_conditional(pp, active, loc);
}

static void endif_directive(Preprocessor *pp) {
  SourcePosition loc = lexer_position(&pp->lexer);
  finish_directive_line(pp);
  pop_conditional(pp, loc);
}

/*
 * #if takes a controlling constant expression (C11 6.10.1p4). `defined` is
 * resolved here, and any identifier that survives expansion evaluates to 0.
 * Precedence follows the C operators; the operands are intmax_t and uintmax_t
 * values, which for our target are the 64-bit long types.
 */

static Token pp_expr_peek(const PPExpression *expr) {
  if ((size_t)expr->index >= expr->tokens->len)
    return expr->end;
  return ((Token *)expr->tokens->data)[expr->index];
}

static Token pp_expr_advance(PPExpression *expr) {
  Token tok = pp_expr_peek(expr);
  if ((size_t)expr->index < expr->tokens->len)
    expr->index++;
  return tok;
}

static bool pp_is_keyword(Token tok, const char *word) {
  size_t len = strlen(word);
  return is_pp_identifier(tok) && (size_t)tok.len == len &&
         memcmp(tok.start, word, len) == 0;
}

/* defined X or defined(X). The operand is a name, never macro-expanded. */
static bool pp_parse_defined(PPExpression *expr, Preprocessor *pp) {
  bool parenthesized = false;
  Token tok;

  if (pp_expr_peek(expr).kind == TOKEN_LPAREN) {
    pp_expr_advance(expr);
    parenthesized = true;
  }
  tok = pp_expr_advance(expr);
  if (!is_pp_identifier(tok))
    error_at(tok, "expect macro name in 'defined'");
  if (parenthesized) {
    Token close = pp_expr_advance(expr);
    if (close.kind != TOKEN_RPAREN)
      error_at(close, "expect ')' after macro name in 'defined'");
  }
  return find_macro(pp, tok) != NULL;
}

static PPValue pp_expr_conditional(PPExpression *expr, Preprocessor *pp,
                                   bool evaluate);

static PPValue pp_expr_primary(PPExpression *expr, Preprocessor *pp,
                               bool evaluate) {
  Token tok = pp_expr_advance(expr);
  PPValue value = {0};
  if (pp_is_keyword(tok, "defined")) {
    value.bits = pp_parse_defined(expr, pp);
    return value;
  }
  if (tok.kind == TOKEN_INT_LITERAL) {
    value.bits = tok.d.int_literal.val;
    value.is_unsigned = (tok.d.int_literal.suffix & INT_SUFFIX_UNSIGNED) != 0 ||
                        (tok.start[0] != '\'' && value.bits > INT64_MAX);
    return value;
  }
  /*
   * Any remaining preprocessing identifier, including a C keyword, is zero.
   */
  if (is_pp_identifier(tok))
    return value;
  if (tok.kind == TOKEN_LPAREN) {
    Token close;
    value = pp_expr_conditional(expr, pp, evaluate);
    close = pp_expr_advance(expr);
    if (close.kind != TOKEN_RPAREN)
      error_at(close, "expect ')' in #if expression");
    return value;
  }
  error_at(tok, "invalid #if expression");
}

static PPValue pp_expr_unary(PPExpression *expr, Preprocessor *pp,
                             bool evaluate) {
  Token op = pp_expr_peek(expr);
  PPValue value;
  if (op.kind != TOKEN_PLUS && op.kind != TOKEN_MINUS &&
      op.kind != TOKEN_BANG && op.kind != TOKEN_TILDE)
    return pp_expr_primary(expr, pp, evaluate);
  pp_expr_advance(expr);
  value = pp_expr_unary(expr, pp, evaluate);
  if (op.kind == TOKEN_BANG) {
    value.bits = !value.bits;
    value.is_unsigned = false;
  } else if (evaluate && op.kind == TOKEN_MINUS) {
    if (!value.is_unsigned && value.bits == (uint64_t)INT64_MAX + 1)
      error_at(op, "integer overflow in #if expression");
    value.bits = 0 - value.bits;
  } else if (evaluate && op.kind == TOKEN_TILDE) {
    value.bits = ~value.bits;
  }
  return value;
}

/*
 * Arithmetic uses unsigned bits to avoid overflowing the compiler's own C
 * operations. Signed overflow is checked before a value is used. Dead operands
 * are still parsed and retain their type, but do not perform arithmetic.
 */
static PPValue pp_apply_binary(Token op, PPValue lhs, PPValue rhs,
                               bool evaluate) {
  PPValue result = {0};
  bool comparison = op.kind == TOKEN_LESS || op.kind == TOKEN_LESS_EQ ||
                    op.kind == TOKEN_GREATER || op.kind == TOKEN_GREATER_EQ ||
                    op.kind == TOKEN_EQ_EQ || op.kind == TOKEN_NOT_EQ;
  bool logical = op.kind == TOKEN_AND_AND || op.kind == TOKEN_OR_OR;
  bool shift = op.kind == TOKEN_LSHIFT || op.kind == TOKEN_RSHIFT;
  bool is_unsigned = lhs.is_unsigned || rhs.is_unsigned;
  uint64_t a = lhs.bits;
  uint64_t b = rhs.bits;
  bool overflow = false;
  result.is_unsigned =
      !comparison && !logical && (shift ? lhs.is_unsigned : is_unsigned);
  if (!evaluate)
    return result;
  switch (op.kind) {
  case TOKEN_PLUS:
    result.bits = a + b;
    overflow = ((a ^ result.bits) & (b ^ result.bits)) >> 63;
    break;
  case TOKEN_MINUS:
    result.bits = a - b;
    overflow = ((a ^ b) & (a ^ result.bits)) >> 63;
    break;
  case TOKEN_STAR: {
    uint64_t abs_a = (int64_t)a < 0 ? 0 - a : a;
    uint64_t abs_b = (int64_t)b < 0 ? 0 - b : b;
    uint64_t limit = (uint64_t)INT64_MAX + ((a ^ b) >> 63);
    result.bits = a * b;
    overflow = abs_b && abs_a > limit / abs_b;
    break;
  }
  case TOKEN_SLASH:
  case TOKEN_PERCENT:
    if (!b)
      error_at(op, "division by zero in #if expression");
    if (!is_unsigned && a == (uint64_t)INT64_MAX + 1 && b == UINT64_MAX)
      error_at(op, "integer overflow in #if expression");
    if (op.kind == TOKEN_SLASH)
      result.bits = is_unsigned ? a / b : (uint64_t)((int64_t)a / (int64_t)b);
    else
      result.bits = is_unsigned ? a % b : (uint64_t)((int64_t)a % (int64_t)b);
    break;
  case TOKEN_LSHIFT:
  case TOKEN_RSHIFT:
    if (b >= 64)
      error_at(op, "invalid shift count in #if expression");
    if (op.kind == TOKEN_LSHIFT) {
      if (!lhs.is_unsigned &&
          ((int64_t)a < 0 || a > ((uint64_t)INT64_MAX >> b)))
        error_at(op, "integer overflow in #if expression");
      result.bits = a << b;
    } else {
      result.bits = lhs.is_unsigned ? a >> b : (uint64_t)((int64_t)a >> b);
    }
    break;
  case TOKEN_LESS:
    result.bits = is_unsigned ? a < b : (int64_t)a < (int64_t)b;
    break;
  case TOKEN_GREATER:
    result.bits = is_unsigned ? a > b : (int64_t)a > (int64_t)b;
    break;
  case TOKEN_LESS_EQ:
    result.bits = is_unsigned ? a <= b : (int64_t)a <= (int64_t)b;
    break;
  case TOKEN_GREATER_EQ:
    result.bits = is_unsigned ? a >= b : (int64_t)a >= (int64_t)b;
    break;
  case TOKEN_EQ_EQ:
    result.bits = a == b;
    break;
  case TOKEN_NOT_EQ:
    result.bits = a != b;
    break;
  case TOKEN_BIT_AND:
    result.bits = a & b;
    break;
  case TOKEN_BIT_XOR:
    result.bits = a ^ b;
    break;
  case TOKEN_BIT_OR:
    result.bits = a | b;
    break;
  case TOKEN_AND_AND:
    result.bits = a && b;
    break;
  case TOKEN_OR_OR:
    result.bits = a || b;
    break;
  default:
    error_at(op, "invalid #if expression");
  }
  if (!is_unsigned && overflow)
    error_at(op, "integer overflow in #if expression");
  return result;
}

/*
 * Higher values bind more tightly; zero ends a binary expression.
 */
static int pp_binary_precedence(TokenKind kind) {
  switch (kind) {
  case TOKEN_OR_OR:
    return 1;
  case TOKEN_AND_AND:
    return 2;
  case TOKEN_BIT_OR:
    return 3;
  case TOKEN_BIT_XOR:
    return 4;
  case TOKEN_BIT_AND:
    return 5;
  case TOKEN_EQ_EQ:
  case TOKEN_NOT_EQ:
    return 6;
  case TOKEN_LESS:
  case TOKEN_LESS_EQ:
  case TOKEN_GREATER:
  case TOKEN_GREATER_EQ:
    return 7;
  case TOKEN_LSHIFT:
  case TOKEN_RSHIFT:
    return 8;
  case TOKEN_PLUS:
  case TOKEN_MINUS:
    return 9;
  case TOKEN_STAR:
  case TOKEN_SLASH:
  case TOKEN_PERCENT:
    return 10;
  default:
    return 0;
  }
}

/*
 * Precedence climbing: consume operators at or above min_precedence. Parsing
 * the RHS at precedence + 1 groups tighter operators first and leaves equal
 * precedence operators for this loop, making binary operators left-associative.
 */
static PPValue pp_expr_binary(PPExpression *expr, Preprocessor *pp,
                              int min_precedence, bool evaluate) {
  PPValue lhs = pp_expr_unary(expr, pp, evaluate);
  for (;;) {
    Token op = pp_expr_peek(expr);
    int precedence = pp_binary_precedence(op.kind);
    bool evaluate_rhs = evaluate;
    PPValue rhs;
    if (precedence < min_precedence)
      return lhs;
    pp_expr_advance(expr);
    if ((op.kind == TOKEN_AND_AND && lhs.bits == 0) ||
        (op.kind == TOKEN_OR_OR && lhs.bits != 0))
      evaluate_rhs = false;
    rhs = pp_expr_binary(expr, pp, precedence + 1, evaluate_rhs);
    lhs = pp_apply_binary(op, lhs, rhs, evaluate);
  }
}

static PPValue pp_expr_conditional(PPExpression *expr, Preprocessor *pp,
                                   bool evaluate) {
  PPValue cond = pp_expr_binary(expr, pp, 1, evaluate);
  if (pp_expr_peek(expr).kind == TOKEN_QUESTION) {
    PPValue then_value;
    PPValue else_value;
    PPValue result;
    Token colon;
    pp_expr_advance(expr);
    then_value = pp_expr_conditional(expr, pp, evaluate && cond.bits != 0);
    colon = pp_expr_advance(expr);
    if (colon.kind != TOKEN_COLON)
      error_at(colon, "expect ':' in #if expression");
    else_value = pp_expr_conditional(expr, pp, evaluate && cond.bits == 0);
    result = cond.bits ? then_value : else_value;
    result.is_unsigned = then_value.is_unsigned || else_value.is_unsigned;
    return result;
  }
  return cond;
}

static void pp_expand_condition(Preprocessor *pp, const Vector *in, Token end,
                                Vector *out);

/* Evaluate the tokens and require that all of them were consumed. */
static bool pp_evaluate_condition(Preprocessor *pp, const Vector *tokens,
                                  SourcePosition loc, Token end) {
  PPExpression expr;
  bool value;
  if (!tokens->len)
    error_at(loc, "expect #if expression");
  expr.tokens = tokens;
  expr.index = 0;
  expr.end = end;
  value = pp_expr_conditional(&expr, pp, true).bits != 0;
  if ((size_t)expr.index != tokens->len)
    error_at(((Token *)tokens->data)[expr.index], "invalid #if expression");
  return value;
}

static void if_directive(Preprocessor *pp, SourcePosition loc) {
  Vector tokens;
  Vector expanded;
  Token end;
  bool active;

  vector_init(&tokens, sizeof(Token));
  end = directive_tokens(pp, &tokens);
  /*
   * A skipped outer branch evaluates nothing, so a syntax error inside dead
   * code is not reported. That matches how other directives behave there.
   */
  if (!conditionals_active(pp)) {
    vector_free(&tokens);
    push_conditional(pp, false, loc);
    return;
  }
  vector_init(&expanded, sizeof(Token));
  pp_expand_condition(pp, &tokens, end, &expanded);
  active = pp_evaluate_condition(pp, &expanded, loc, end);
  vector_free(&expanded);
  vector_free(&tokens);
  push_conditional(pp, active, loc);
}

/* The directives this preprocessor understands. */
typedef enum {
  DIRECTIVE_UNKNOWN, /* Not in the table; an unimplemented directive. */
  DIRECTIVE_DEFINE,
  DIRECTIVE_ENDIF,
  DIRECTIVE_IF,
  DIRECTIVE_IFDEF,
  DIRECTIVE_IFNDEF,
  DIRECTIVE_INCLUDE,
  DIRECTIVE_UNDEF,
} DirectiveKind;

/*
 * Directive names, in alphabetical order. Adding a directive means adding a
 * case to pp_directive and one row here.
 */
typedef struct {
  const char *name;
  int len;
  DirectiveKind kind;
} Directive;

#define DIR(name, kind) {name, sizeof(name) - 1, kind}

static const Directive directives[] = {
    DIR("define", DIRECTIVE_DEFINE), DIR("endif", DIRECTIVE_ENDIF),
    DIR("if", DIRECTIVE_IF),         DIR("ifdef", DIRECTIVE_IFDEF),
    DIR("ifndef", DIRECTIVE_IFNDEF), DIR("include", DIRECTIVE_INCLUDE),
    DIR("undef", DIRECTIVE_UNDEF),
};

#undef DIR

static const Directive *find_directive(const char *name, int len) {
  size_t i;
  for (i = 0; i < sizeof(directives) / sizeof(directives[0]); ++i)
    if (directives[i].len == len &&
        memcmp(directives[i].name, name, (size_t)len) == 0)
      return &directives[i];
  return NULL;
}

/*
 * The lexer reports a '#' at the start of a line as TOKEN_HASH. This reads
 * the directive name that follows. A '#' with no directive name is a null
 * directive and is ignored.
 */
static void pp_directive(Preprocessor *pp) {
  Lexer *l = &pp->lexer;
  const char *name;
  SourcePosition name_loc;
  const Directive *directive;
  int len;

  lexer_skip_horizontal(l);
  if (*l->cursor == '\0' || *l->cursor == '\n' || *l->cursor == '\r') {
    if (*l->cursor != '\0')
      lexer_advance(l);
    return;
  }
  if (!(isalpha((unsigned char)*l->cursor) || *l->cursor == '_'))
    error_at(lexer_position(l), "expect preprocessor directive");

  name_loc = lexer_position(l);
  name = l->cursor;
  while (isalnum((unsigned char)*l->cursor) || *l->cursor == '_')
    lexer_advance(l);
  len = (int)(l->cursor - name);
  directive = find_directive(name, len);

  /*
   * In a skipped branch only the conditionals matter, since they track the
   * nesting. Any other directive, known or not, is discarded without being
   * interpreted, which is how dead code can hold arbitrary text.
   */
  if (!conditionals_active(pp)) {
    switch (directive ? directive->kind : DIRECTIVE_UNKNOWN) {
    case DIRECTIVE_IF:
      if_directive(pp, name_loc);
      return;
    case DIRECTIVE_IFDEF:
      ifdef_directive(pp, true);
      return;
    case DIRECTIVE_IFNDEF:
      ifdef_directive(pp, false);
      return;
    case DIRECTIVE_ENDIF:
      endif_directive(pp);
      return;
    default:
      skip_directive_line(pp);
      return;
    }
  }

  if (!directive)
    error_at(name_loc, "preprocessor directive '%.*s' is not supported yet",
             len, name);

  switch (directive->kind) {
  case DIRECTIVE_IF:
    if_directive(pp, name_loc);
    return;
  case DIRECTIVE_IFDEF:
    ifdef_directive(pp, true);
    return;
  case DIRECTIVE_IFNDEF:
    ifdef_directive(pp, false);
    return;
  case DIRECTIVE_ENDIF:
    endif_directive(pp);
    return;
  case DIRECTIVE_DEFINE:
    define_macro(pp);
    return;
  case DIRECTIVE_INCLUDE:
    include_directive(pp);
    return;
  case DIRECTIVE_UNDEF:
    undef_macro(pp);
    return;
  case DIRECTIVE_UNKNOWN:
    break; /* Not stored in the table. */
  }
}

/*
 * Read source tokens and handle directives before macro expansion. Replacement
 * tokens never enter this path, so they cannot introduce directives.
 */
static Token next_source_token(Preprocessor *pp) {
  for (;;) {
    Token tok = lexer_next_token(&pp->lexer);
    if (tok.kind == TOKEN_HASH) {
      pp_directive(pp);
      continue;
    }
    if (tok.kind == TOKEN_EOF) {
      if (pop_include(pp))
        continue;
      pp_check_end(pp);
      return tok;
    }
    if (conditionals_active(pp))
      return tok;
  }
}

static bool hideset_contains(const HideSet *set, const Macro *macro) {
  for (; set; set = set->next)
    if (set->macro == macro)
      return true;
  return false;
}

/*
 * Hide sets are immutable and shared by token copies for the translation unit.
 */
static const HideSet *hide_macro(const HideSet *set, Macro *macro) {
  HideSet *entry;
  if (hideset_contains(set, macro))
    return set;
  entry = malloc(sizeof(*entry));
  if (!entry)
    error_at(macro->name, "out of memory");
  entry->macro = macro;
  entry->next = set;
  return entry;
}

static const HideSet *hideset_union(const HideSet *a, const HideSet *b) {
  for (; a; a = a->next)
    b = hide_macro(b, a->macro);
  return b;
}

static const HideSet *hideset_intersection(const HideSet *a, const HideSet *b) {
  const HideSet *result = NULL;
  for (; a; a = a->next)
    if (hideset_contains(b, a->macro))
      result = hide_macro(result, a->macro);
  return result;
}

static MacroToken *new_macro_token(Token token, const HideSet *hideset) {
  MacroToken *node = calloc(1, sizeof(*node));
  if (!node)
    error_at(token, "out of memory");
  node->token = token;
  node->hideset = hideset;
  return node;
}

static void free_macro_tokens(MacroToken *tokens) {
  while (tokens) {
    MacroToken *next = tokens->next;
    free(tokens);
    tokens = next;
  }
}

static MacroToken *peek_macro_token(TokenStream *stream) {
  if (!stream->pending) {
    Token tok =
        stream->read_source ? next_source_token(stream->pp) : stream->end;
    stream->pending = new_macro_token(tok, NULL);
  }
  return stream->pending;
}

static MacroToken take_macro_token(TokenStream *stream) {
  MacroToken *node = peek_macro_token(stream);
  MacroToken result = *node;
  stream->pending = node->next;
  result.next = NULL;
  free(node);
  return result;
}

static MacroToken expand_next(TokenStream *stream);

static MacroToken *expand_argument(Preprocessor *pp, MacroToken *tokens,
                                   Token end) {
  TokenStream stream = {0};
  MacroToken *result = NULL;
  MacroToken **tail = &result;
  stream.pp = pp;
  stream.pending = tokens;
  stream.end = end;
  stream.end.kind = TOKEN_EOF;
  stream.end.len = 0;
  for (;;) {
    MacroToken tok = expand_next(&stream);
    if (tok.token.kind == TOKEN_EOF)
      return result;
    *tail = new_macro_token(tok.token, tok.hideset);
    tail = &(*tail)->next;
  }
}

/*
 * Collect unexpanded arguments. Only parentheses protect commas; braces and
 * brackets do not. A single empty argument is valid, and F() supplies zero
 * arguments only when F has no parameters.
 */
static MacroToken read_macro_arguments(TokenStream *stream, Macro *macro,
                                       Token name, Vector *args) {
  MacroArgument arg = {0};
  MacroToken **tail = &arg.tokens;
  int depth = 0;
  take_macro_token(stream);
  for (;;) {
    MacroToken tok = take_macro_token(stream);
    if (tok.token.kind == TOKEN_EOF)
      error_at(name, "unterminated invocation of macro '%.*s'", name.len,
               name.start);
    if (tok.token.kind == TOKEN_RPAREN && !depth) {
      if (macro->params.len || args->len || arg.tokens)
        if (!vector_push(args, &arg))
          error_at(name, "out of memory");
      if (args->len != macro->params.len)
        error_at(name, "wrong number of arguments to macro '%.*s'", name.len,
                 name.start);
      return tok;
    }
    if (tok.token.kind == TOKEN_COMMA && !depth) {
      if (!vector_push(args, &arg))
        error_at(name, "out of memory");
      arg = (MacroArgument){0};
      tail = &arg.tokens;
      continue;
    }
    if (tok.token.kind == TOKEN_LPAREN)
      ++depth;
    else if (tok.token.kind == TOKEN_RPAREN)
      --depth;
    *tail = new_macro_token(tok.token, tok.hideset);
    tail = &(*tail)->next;
  }
}

static int macro_parameter_index(const Macro *macro, Token token) {
  size_t i;
  if (is_pp_identifier(token))
    for (i = 0; i < macro->params.len; ++i)
      if (same_identifier(((Token *)macro->params.data)[i], token))
        return (int)i;
  return -1;
}

static MacroToken *substitute_macro(Preprocessor *pp, Macro *macro,
                                    Vector *args, const HideSet *hideset,
                                    Token name) {
  MacroToken *result = NULL;
  MacroToken **tail = &result;
  size_t i;
  for (i = 0; i < macro->tokens.len; ++i) {
    Token token = ((Token *)macro->tokens.data)[i];
    int index = macro_parameter_index(macro, token);
    if (index >= 0) {
      MacroArgument *arg = &((MacroArgument *)args->data)[index];
      MacroToken *item;
      /*
       * Expand a used argument once, before disabling the invoked macro.
       * Unused arguments are collected but never expanded.
       */
      if (!arg->expanded_ready) {
        arg->expanded = expand_argument(pp, arg->tokens, name);
        arg->tokens = NULL;
        arg->expanded_ready = true;
      }
      for (item = arg->expanded; item; item = item->next) {
        *tail =
            new_macro_token(item->token, hideset_union(item->hideset, hideset));
        tail = &(*tail)->next;
      }
    } else {
      *tail = new_macro_token(token, hideset);
      tail = &(*tail)->next;
    }
  }
  return result;
}

static MacroToken expand_next(TokenStream *stream) {
  for (;;) {
    MacroToken tok = take_macro_token(stream);
    Macro *macro;
    const HideSet *hideset;
    Vector args;
    MacroToken *replacement;
    MacroToken **tail;
    size_t i;
    if (tok.token.kind == TOKEN_EOF || !is_pp_identifier(tok.token) ||
        (stream->condition && pp_is_keyword(tok.token, "defined")))
      return tok;
    macro = find_macro(stream->pp, tok.token);
    if (!macro || hideset_contains(tok.hideset, macro))
      return tok;
    if (macro->function_like &&
        peek_macro_token(stream)->token.kind != TOKEN_LPAREN)
      return tok;

    vector_init(&args, sizeof(MacroArgument));
    hideset = tok.hideset;
    if (macro->function_like) {
      MacroToken close = read_macro_arguments(stream, macro, tok.token, &args);
      /*
       * Only suppression shared by both ends of the invocation survives.
       * The closing ')' can come from outside the current replacement list.
       */
      hideset = hideset_intersection(hideset, close.hideset);
    }
    hideset = hide_macro(hideset, macro);
    replacement =
        substitute_macro(stream->pp, macro, &args, hideset, tok.token);
    for (i = 0; i < args.len; ++i) {
      MacroArgument *arg = &((MacroArgument *)args.data)[i];
      free_macro_tokens(arg->tokens);
      free_macro_tokens(arg->expanded);
    }
    vector_free(&args);

    /*
     * Rescan together with following tokens, so an expansion that ends in a
     * function-like macro name can consume '(' from the surrounding source.
     */
    tail = &replacement;
    while (*tail)
      tail = &(*tail)->next;
    *tail = stream->pending;
    stream->pending = replacement;
  }
}

static void pp_expand_condition(Preprocessor *pp, const Vector *in, Token end,
                                Vector *out) {
  TokenStream stream = {0};
  MacroToken **tail = &stream.pending;
  size_t i;
  stream.pp = pp;
  stream.condition = true;
  stream.end = end;
  for (i = 0; i < in->len; ++i) {
    *tail = new_macro_token(((Token *)in->data)[i], NULL);
    tail = &(*tail)->next;
  }
  for (;;) {
    MacroToken tok = expand_next(&stream);
    bool parenthesized;
    if (tok.token.kind == TOKEN_EOF)
      return;
    if (!vector_push(out, &tok.token))
      error_at(tok.token, "out of memory");
    if (!pp_is_keyword(tok.token, "defined"))
      continue;
    /*
     * Copy defined's operand without expansion, in either spelling.
     */
    tok = take_macro_token(&stream);
    parenthesized = tok.token.kind == TOKEN_LPAREN;
    if (!vector_push(out, &tok.token))
      error_at(tok.token, "out of memory");
    if (parenthesized) {
      tok = take_macro_token(&stream);
      if (!vector_push(out, &tok.token))
        error_at(tok.token, "out of memory");
      tok = take_macro_token(&stream);
      if (!vector_push(out, &tok.token))
        error_at(tok.token, "out of memory");
    }
  }
}

Token pp_next_token(Preprocessor *pp) {
  TokenStream stream = {0};
  Token tok;
  stream.pp = pp;
  stream.pending = pp->pending;
  stream.read_source = true;
  tok = expand_next(&stream).token;
  pp->pending = stream.pending;
  /*
   * Replacement and argument tokens share immutable decoded string bytes.
   * Give the parser its own copy, since it consumes and frees this payload.
   */
  if (tok.kind == TOKEN_STRING_LITERAL) {
    unsigned char *bytes = malloc((size_t)tok.d.string_literal.len);
    if (!bytes)
      error_at(tok, "out of memory");
    memcpy(bytes, tok.d.string_literal.val, (size_t)tok.d.string_literal.len);
    tok.d.string_literal.val = bytes;
  }
  return tok;
}

void pp_check_end(const Preprocessor *pp) {
  ConditionalFrame *open = top_conditional(pp);
  if (open)
    error_at(open->loc, "unterminated conditional directive");
}
