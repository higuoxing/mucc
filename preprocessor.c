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

void pp_init(Preprocessor *pp, const SourceFile *file,
             const Vector *include_paths) {
  lexer_init(&pp->lexer, file);
  pp->include_frames = NULL;
  pp->include_paths = include_paths;
  pp->include_depth = 0;
  pp->macros = NULL;
  vector_init(&pp->expansions, sizeof(MacroFrame));
}

static Macro *find_macro(const Preprocessor *pp, Token name) {
  Macro *macro;
  for (macro = pp->macros; macro; macro = macro->next)
    if (macro->len == name.len &&
        memcmp(macro->name, name.start, (size_t)name.len) == 0)
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
  pp->include_frames = frame;
  lexer_init(&pp->lexer, file);
  pp->include_depth++;
}

/* Included buffers stay allocated: tokens point into them until exit. */
static bool pop_include(Preprocessor *pp) {
  IncludeFrame *frame = pp->include_frames;
  if (!frame)
    return false;
  pp->lexer = frame->lexer;
  pp->include_frames = frame->outer;
  pp->include_depth--;
  free(frame);
  return true;
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
 * returned vector owns its storage; each token points into the source.
 */
static void directive_tokens(Preprocessor *pp, Vector *out) {
  Lexer saved = pp->lexer;
  pp->lexer.in_directive = true;
  for (;;) {
    Token tok = lexer_next_token(&pp->lexer);
    if (tok.kind == TOKEN_EOF)
      break;
    if (!vector_push(out, &tok))
      error_at(tok, "out of memory");
  }
  /*
   * Directives end at the newline and are never part of an include or macro
   * directive flag and the cursor position changed.
   */
  pp->lexer.in_directive = saved.in_directive;
  if (*pp->lexer.cursor == '\n' || *pp->lexer.cursor == '\r')
    lexer_advance(&pp->lexer);
}

static void define_macro(Preprocessor *pp) {
  Lexer *l = &pp->lexer;
  SourcePosition name_loc;
  Token name;
  Vector tokens;
  Macro *macro;

  lexer_skip_horizontal(l);
  if (!(isalpha((unsigned char)*l->cursor) || *l->cursor == '_'))
    error_at(lexer_position(l), "expect macro name");
  name_loc = lexer_position(l);

  /* The name is a normal identifier token, so it carries a spelling. */
  name = lexer_next_token(l);
  name.file = name_loc.file;
  name.line = name_loc.line;
  name.col = name_loc.col;

  /*
   * A '(' immediately after the name, with no whitespace, makes this a
   * function-like macro. That form is not implemented yet.
   */
  if (*l->cursor == '(')
    error_at(lexer_position(l), "function-like macros are not supported yet");

  vector_init(&tokens, sizeof(Token));
  directive_tokens(pp, &tokens);

  macro = find_macro(pp, name);
  if (macro) {
    /* Redefining is allowed only when the replacement list is identical. */
    if (macro->tokens.len != tokens.len ||
        (tokens.len && memcmp(macro->tokens.data, tokens.data,
                              tokens.len * sizeof(Token)) != 0))
      error_at(name, "'%.*s' redefined", name.len, name.start);
    vector_free(&tokens);
    return;
  }

  macro = calloc(1, sizeof(*macro));
  if (!macro)
    error_at(name, "out of memory");
  macro->name = name.start;
  macro->len = name.len;
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
    if ((*link)->len == name.len &&
        memcmp((*link)->name, name.start, (size_t)name.len) == 0) {
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

/* The directives this preprocessor understands. */
typedef enum {
  DIRECTIVE_DEFINE,
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
    DIR("define", DIRECTIVE_DEFINE),
    DIR("include", DIRECTIVE_INCLUDE),
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
  if (!directive)
    error_at(name_loc, "preprocessor directive '%.*s' is not supported yet",
             len, name);

  switch (directive->kind) {
  case DIRECTIVE_DEFINE:
    define_macro(pp);
    break;
  case DIRECTIVE_INCLUDE:
    include_directive(pp);
    break;
  case DIRECTIVE_UNDEF:
    undef_macro(pp);
    break;
  }
}

/*
 * A replacement list is replayed one token at a time. Frames are nested, so a
 * list naming another macro expands inside the outer one. Reaching the end of a
 * frame clears its guard, which lets the same macro be used again later.
 */
static MacroFrame *top_frame(Preprocessor *pp) {
  if (!pp->expansions.len)
    return NULL;
  return &((MacroFrame *)pp->expansions.data)[pp->expansions.len - 1];
}

static bool pop_frame(Preprocessor *pp) {
  MacroFrame *frame = top_frame(pp);
  if (!frame)
    return false;
  if (frame->macro)
    frame->macro->expanding = false;
  pp->expansions.len--;
  return true;
}

/*
 * The next token from whichever source is active: a macro replacement list
 * being replayed, or the source file. A finished list is popped here. This is
 * "raw" because no expansion or directive handling has happened yet;
 * pp_next_token does that.
 */
static Token next_raw_token(Preprocessor *pp) {
  MacroFrame *frame = top_frame(pp);
  const Token *tokens;
  if (!frame)
    return lexer_next_token(&pp->lexer);
  if (frame->index >= (int)frame->macro->tokens.len) {
    pop_frame(pp);
    /* The list ended; whatever follows it is the next token. */
    return next_raw_token(pp);
  }
  tokens = frame->macro->tokens.data;
  return tokens[frame->index++];
}

/*
 * Start replaying a replacement list on top of the current expansions. The
 * caller loops after this, so a mention of another macro inside the list
 * expands on the next iteration. An empty list pushes nothing, which makes the
 * macro expand to no tokens at all.
 */
static void push_macro(Preprocessor *pp, Macro *macro) {
  MacroFrame frame;
  if (!macro->tokens.len)
    return;
  frame.macro = macro;
  frame.index = 0;
  if (!vector_push(&pp->expansions, &frame))
    error_at(pp->lexer, "out of memory");
  macro->expanding = true;
}

Token pp_next_token(Preprocessor *pp) {
  for (;;) {
    Token tok = next_raw_token(pp);
    if (tok.kind == TOKEN_HASH) {
      pp_directive(pp);
      continue;
    }
    /* End of an included file: resume the file that included it. */
    if (tok.kind == TOKEN_EOF && pop_include(pp))
      continue;
    if (tok.kind == TOKEN_IDENTIFIER) {
      Macro *macro = find_macro(pp, tok);
      if (macro && !macro->expanding) {
        /* The name is replaced, possibly by nothing (C11 6.10.3p4). */
        push_macro(pp, macro);
        continue;
      }
    }
    return tok;
  }
}
