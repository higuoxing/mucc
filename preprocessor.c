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

void cpp_init(Preprocessor *cpp, const SourceFile *file,
              const Vector *include_paths) {
  lexer_init(&cpp->lexer, file);
  cpp->include_frames = NULL;
  cpp->include_paths = include_paths;
  cpp->include_depth = 0;
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

static void push_include(Preprocessor *cpp, const SourceFile *file) {
  IncludeFrame *frame = malloc(sizeof(*frame));
  if (!frame)
    error_at(lexer_position(&cpp->lexer), "out of memory");
  frame->lexer = cpp->lexer;
  frame->outer = cpp->include_frames;
  cpp->include_frames = frame;
  lexer_init(&cpp->lexer, file);
  cpp->include_depth++;
}

/* Included buffers stay allocated: tokens point into them until exit. */
static bool pop_include(Preprocessor *cpp) {
  IncludeFrame *frame = cpp->include_frames;
  if (!frame)
    return false;
  cpp->lexer = frame->lexer;
  cpp->include_frames = frame->outer;
  cpp->include_depth--;
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
static void include_file(Preprocessor *cpp, const char *header, bool quoted,
                         SourcePosition loc) {
  const char *const *paths = cpp->include_paths->data;
  const SourceFile *file = NULL;
  size_t i;

  if (cpp->include_depth >= MAX_INCLUDE_DEPTH)
    error_at(loc, "include nesting is too deep");

  if (header[0] == '/') {
    file = try_path(copy_text(header, strlen(header)));
  } else {
    if (quoted) {
      char *dir = path_directory(file_name(cpp->lexer.file));
      if (!dir)
        error_at(loc, "out of memory");
      file = try_path(path_join(dir, header));
      free(dir);
    }
    for (i = 0; !file && i < cpp->include_paths->len; ++i)
      file = try_path(path_join(paths[i], header));
  }

  if (!file)
    error_at(loc, "cannot find include file '%s'", header);
  push_include(cpp, file);
}

/* Header names are literal text, not string literals: escapes stay intact. */
static char *read_header_name(Preprocessor *cpp, bool *quoted) {
  Lexer *l = &cpp->lexer;
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

static void finish_directive_line(Preprocessor *cpp) {
  Lexer *l = &cpp->lexer;
  lexer_skip_horizontal(l);
  if (*l->cursor != '\0' && *l->cursor != '\n' && *l->cursor != '\r')
    error_at(lexer_position(l), "extra tokens at end of #include directive");
  if (*l->cursor == '\n' || *l->cursor == '\r')
    lexer_advance(l);
}

/*
 * The lexer reports a '#' at the start of a line as TOKEN_HASH. This reads
 * the directive name that follows. Only #include is implemented. A '#' with
 * no directive name is a null directive and is ignored.
 */
static void cpp_directive(Preprocessor *cpp) {
  Lexer *l = &cpp->lexer;
  const char *name;
  SourcePosition name_loc;
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

  if (len == 7 && memcmp(name, "include", 7) == 0) {
    bool quoted = false;
    char *header;
    SourcePosition header_loc;
    lexer_skip_horizontal(l);
    header_loc = lexer_position(l);
    header = read_header_name(cpp, &quoted);
    finish_directive_line(cpp);
    include_file(cpp, header, quoted, header_loc);
    free(header);
    return;
  }

  error_at(name_loc, "preprocessor directive '%.*s' is not supported yet", len,
           name);
}

Token cpp_next_token(Preprocessor *cpp) {
  for (;;) {
    Token tok = lexer_next_token(&cpp->lexer);
    if (tok.kind == TOKEN_HASH) {
      cpp_directive(cpp);
      continue;
    }
    /* End of an included file: resume the file that included it. */
    if (tok.kind == TOKEN_EOF && pop_include(cpp))
      continue;
    return tok;
  }
}
