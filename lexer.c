/*
 * Lexer for the self-hosted C compiler
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
#include <limits.h>
#include <stdio.h>
#include <string.h>

#include "error.h"
#include "lexer.h"
#include "vector.h"

typedef struct {
  const char *name;
  size_t len;
  TokenKind kind;
} Keyword;

/* C11 keywords */
#define KW(kw_spelling, kw_kind)                                               \
  {.name = kw_spelling, .len = sizeof(kw_spelling) - 1, .kind = kw_kind}

static const Keyword keywords[] = {
    KW("_Alignas", TOKEN_RESERVED),
    KW("_Alignof", TOKEN_RESERVED),
    KW("_Atomic", TOKEN_RESERVED),
    KW("_Bool", TOKEN_BOOL),
    KW("_Complex", TOKEN_RESERVED),
    KW("_Generic", TOKEN_RESERVED),
    KW("_Imaginary", TOKEN_RESERVED),
    KW("_Noreturn", TOKEN_RESERVED),
    KW("_Static_assert", TOKEN_RESERVED),
    KW("_Thread_local", TOKEN_RESERVED),
    KW("auto", TOKEN_RESERVED),
    KW("break", TOKEN_BREAK),
    KW("case", TOKEN_CASE),
    KW("char", TOKEN_CHAR),
    KW("const", TOKEN_CONST),
    KW("continue", TOKEN_CONTINUE),
    KW("default", TOKEN_DEFAULT),
    KW("do", TOKEN_DO),
    KW("double", TOKEN_RESERVED),
    KW("else", TOKEN_ELSE),
    KW("enum", TOKEN_ENUM),
    KW("extern", TOKEN_EXTERN),
    KW("float", TOKEN_RESERVED),
    KW("for", TOKEN_FOR),
    KW("goto", TOKEN_GOTO),
    KW("if", TOKEN_IF),
    KW("inline", TOKEN_RESERVED),
    KW("int", TOKEN_INT),
    KW("long", TOKEN_LONG),
    KW("register", TOKEN_RESERVED),
    KW("restrict", TOKEN_RESERVED),
    KW("return", TOKEN_RETURN),
    KW("short", TOKEN_SHORT),
    KW("signed", TOKEN_RESERVED),
    KW("sizeof", TOKEN_SIZEOF),
    KW("static", TOKEN_STATIC),
    KW("struct", TOKEN_STRUCT),
    KW("switch", TOKEN_SWITCH),
    KW("typedef", TOKEN_TYPEDEF),
    KW("union", TOKEN_UNION),
    KW("unsigned", TOKEN_UNSIGNED),
    KW("void", TOKEN_VOID),
    KW("volatile", TOKEN_RESERVED),
    KW("while", TOKEN_WHILE),
};

#undef KW

static TokenKind kw_token_type(const Token *tok) {
  size_t i;
  for (i = 0; i < sizeof(keywords) / sizeof(keywords[0]); ++i) {
    const Keyword *kw = &keywords[i];
    if ((size_t)tok->len == kw->len &&
        memcmp(tok->start, kw->name, kw->len) == 0)
      return kw->kind;
  }

  return TOKEN_IDENTIFIER;
}

bool same_identifier(Token a, Token b) {
  return a.len == b.len && strncmp(a.start, b.start, a.len) == 0;
}

/*
 * Every opened buffer is recorded here so a diagnostic can turn the file id
 * on a token back into a path. Files are never freed: tokens point into them
 * until exit. A file's id is its one-based index in this table.
 */
static Vector source_files = {.data = NULL,
                              .len = 0,
                              .capacity = 0,
                              .element_size = sizeof(SourceFile *)};

SourceFile *new_source_file(const char *filename) {
  FILE *stream;
  SourceFile *file;
  long len;
  size_t bytes_read;
  char *contents;

  stream = fopen(filename, "rb");
  if (!stream)
    return NULL;
  /*
   * Only an unopenable file is recoverable, so an include search can try the
   * next candidate. A file opened at this point must read completely.
   */
  if (fseek(stream, 0, SEEK_END) != 0) {
    fclose(stream);
    error_at_loc(filename, 0, 0, "failed to read file");
    exit(1);
  }
  len = ftell(stream);
  if (len < 0 || fseek(stream, 0, SEEK_SET) != 0) {
    fclose(stream);
    error_at_loc(filename, 0, 0, "failed to read file");
    exit(1);
  }
  contents = malloc((size_t)len + 1);
  if (!contents) {
    fclose(stream);
    error_at_loc(filename, 0, 0, "out of memory");
    exit(1);
  }
  bytes_read = fread(contents, 1, (size_t)len, stream);
  fclose(stream);
  if (bytes_read != (size_t)len) {
    error_at_loc(filename, 0, 0, "failed to read file");
    exit(1);
  }
  contents[bytes_read] = '\0';

  file = malloc(sizeof(*file));
  if (!file) {
    error_at_loc(filename, 0, 0, "out of memory");
    exit(1);
  }
  file->name = filename;
  file->contents = contents;
  file->length = (int)bytes_read;
  file->id = (int)source_files.len + 1;

  if (!vector_push(&source_files, &file)) {
    error_at_loc(filename, 0, 0, "out of memory");
    exit(1);
  }
  return file;
}

const char *file_name(int file) {
  if (file <= 0 || (size_t)file > source_files.len)
    return NULL;
  return ((SourceFile **)source_files.data)[file - 1]->name;
}

void lexer_init(Lexer *l, const SourceFile *file) {
  l->file = file->id;
  l->cursor = file->contents;
  l->line = 1;
  l->col = 1;
  l->at_bol = true;
}

SourcePosition lexer_position(const Lexer *l) {
  SourcePosition pos;
  pos.file = l->file;
  pos.line = l->line;
  pos.col = l->col;
  return pos;
}

void lexer_advance(Lexer *l) {
  char c = *l->cursor;
  if (c == '\0') {
    return;
  }

  l->cursor++;

  if (c == '\r' || c == '\n') {
    /* Handle \r\n */
    if (c == '\r' && *l->cursor == '\n') {
      l->cursor++;
    }

    l->line++;
    l->col = 1;
    l->at_bol = true;
  } else {
    l->col++;
  }
}

/*
 * Skip whitespace and comments (C11 6.4.9: each comment is replaced by one
 * space character).
 */
void skip_whitespace(Lexer *l) {
  for (;;) {
    if (*l->cursor == ' ' || *l->cursor == '\t' || *l->cursor == '\n' ||
        *l->cursor == '\r' || *l->cursor == '\f' || *l->cursor == '\v') {
      lexer_advance(l);
      continue;
    }

    if (*l->cursor == '/' && l->cursor[1] == '/') {
      /* Line comment: skip to the end of the line. */
      while (*l->cursor != '\0' && *l->cursor != '\n' && *l->cursor != '\r')
        lexer_advance(l);
      continue;
    }

    if (*l->cursor == '/' && l->cursor[1] == '*') {
      SourcePosition loc = lexer_position(l);
      /* Block comment: skip to the closing delimiter. */
      lexer_advance(l);
      lexer_advance(l);
      for (;;) {
        if (*l->cursor == '\0')
          error_at(loc, "unterminated comment");
        if (*l->cursor == '*' && l->cursor[1] == '/') {
          lexer_advance(l);
          lexer_advance(l);
          break;
        }
        lexer_advance(l);
      }
      continue;
    }

    return;
  }
}

/*
 * Integer suffixes allow one U and one L, LL, or ll, in either order.
 * Keep the flags on the token for literal type selection in the parser.
 */
static unsigned read_int_suffix(Lexer *l, Token loc) {
  unsigned suffix = 0;
  while (*l->cursor == 'u' || *l->cursor == 'U' || *l->cursor == 'l' ||
         *l->cursor == 'L') {
    if (*l->cursor == 'u' || *l->cursor == 'U') {
      if (suffix & INT_SUFFIX_UNSIGNED)
        error_at(loc, "invalid integer suffix");
      suffix |= INT_SUFFIX_UNSIGNED;
      lexer_advance(l);
    } else {
      char letter = *l->cursor;
      if (suffix & (INT_SUFFIX_LONG | INT_SUFFIX_LONG_LONG))
        error_at(loc, "invalid integer suffix");
      lexer_advance(l);
      if (*l->cursor == letter) {
        suffix |= INT_SUFFIX_LONG_LONG;
        lexer_advance(l);
      } else {
        suffix |= INT_SUFFIX_LONG;
      }
    }
  }
  if (isalnum((unsigned char)*l->cursor) || *l->cursor == '_')
    error_at(loc, "invalid integer suffix");
  return suffix;
}

static int hex_digit(unsigned char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

/*
 * Decode an escape after its backslash. Octal escapes consume up to three
 * digits; hexadecimal escapes consume all following hexadecimal digits.
 */
static int read_escape(Lexer *l, Token loc) {
  int value = 0;
  int c = (unsigned char)*l->cursor;
  if (c >= '0' && c <= '7') {
    int i;
    for (i = 0; i < 3 && *l->cursor >= '0' && *l->cursor <= '7'; ++i) {
      value = value * 8 + *l->cursor - '0';
      lexer_advance(l);
    }
    if (value > 255)
      error_at(loc, "character escape out of range");
    return value;
  }
  if (c == 'x') {
    int digit;
    lexer_advance(l);
    if (hex_digit((unsigned char)*l->cursor) < 0)
      error_at(loc, "expect hexadecimal digit in character escape");
    while ((digit = hex_digit((unsigned char)*l->cursor)) >= 0) {
      if (value > (255 - digit) / 16)
        error_at(loc, "character escape out of range");
      value = value * 16 + digit;
      lexer_advance(l);
    }
    return value;
  }

  if (c == '\0' || c == '\n' || c == '\r')
    error_at(loc, loc.start[0] == '"' ? "unterminated string literal"
                                      : "unterminated character literal");
  lexer_advance(l);
  switch (c) {
  case '\'':
    return '\'';
  case '"':
    return '"';
  case '?':
    return '?';
  case '\\':
    return '\\';
  case 'a':
    return '\a';
  case 'b':
    return '\b';
  case 'f':
    return '\f';
  case 'n':
    return '\n';
  case 'r':
    return '\r';
  case 't':
    return '\t';
  case 'v':
    return '\v';
  default:
    error_at(loc, loc.start[0] == '"'
                      ? "invalid escape sequence in string literal"
                      : "invalid escape sequence in character literal");
  }
}

/*
 * Ordinary single-byte character constants have type int. Interpret the
 * decoded byte as signed char, matching the target's plain char semantics.
 */
static Token read_char_literal(Lexer *l, Token tok) {
  int value;
  lexer_advance(l);
  if (*l->cursor == '\'')
    error_at(tok, "empty character literal");
  if (*l->cursor == '\0' || *l->cursor == '\n' || *l->cursor == '\r')
    error_at(tok, "unterminated character literal");

  if (*l->cursor == '\\') {
    lexer_advance(l);
    value = read_escape(l, tok);
  } else {
    value = (unsigned char)*l->cursor;
    lexer_advance(l);
  }
  if (*l->cursor == '\0' || *l->cursor == '\n' || *l->cursor == '\r')
    error_at(tok, "unterminated character literal");
  if (*l->cursor != '\'') {
    const char *end = l->cursor;
    while (*end && *end != '\n' && *end != '\r') {
      if (*end == '\'')
        error_at(tok, "multi-character literals not supported");
      if (*end == '\\' && end[1] && end[1] != '\n' && end[1] != '\r')
        ++end;
      ++end;
    }
    error_at(tok, "unterminated character literal");
  }
  lexer_advance(l);

  tok.kind = TOKEN_INT_LITERAL;
  tok.len = (int)(l->cursor - tok.start);
  tok.d.int_literal.val = value < 128 ? value : value - 256;
  return tok;
}

/*
 * Locate the closing quote before allocating: the source contents plus one
 * byte bound the decoded size, even with escapes. Keep embedded zero bytes
 * and append a separate terminator; strlen cannot describe the decoded data.
 */
static Token read_string_literal(Lexer *l, Token tok) {
  const char *end = l->cursor + 1;
  int length = 0;
  while (*end != '"') {
    if (*end == '\0' || *end == '\n' || *end == '\r')
      error_at(tok, "unterminated string literal");
    if (*end == '\\') {
      ++end;
      if (*end == '\0' || *end == '\n' || *end == '\r')
        error_at(tok, "unterminated string literal");
    }
    ++end;
  }
  if (end - tok.start >= INT_MAX)
    error_at(tok, "string literal is too long");
  tok.d.string_literal.val = malloc((size_t)(end - l->cursor));
  if (!tok.d.string_literal.val)
    error_at(tok, "out of memory");

  lexer_advance(l);
  while (l->cursor != end) {
    int value;
    if (*l->cursor == '\\') {
      lexer_advance(l);
      value = read_escape(l, tok);
    } else {
      value = (unsigned char)*l->cursor;
      lexer_advance(l);
    }
    tok.d.string_literal.val[length++] = (unsigned char)value;
  }
  tok.d.string_literal.val[length++] = 0;
  lexer_advance(l);

  tok.kind = TOKEN_STRING_LITERAL;
  tok.len = (int)(l->cursor - tok.start);
  tok.d.string_literal.len = length;
  return tok;
}

/*
 * Skip spaces and comments without crossing a newline. The preprocessor uses
 * this between the parts of a directive, where a newline ends the directive.
 */
void lexer_skip_horizontal(Lexer *l) {
  for (;;) {
    char c = *l->cursor;
    if (c == ' ' || c == '\t' || c == '\v' || c == '\f') {
      lexer_advance(l);
      continue;
    }
    if (c == '/' && l->cursor[1] == '/') {
      while (*l->cursor != '\0' && *l->cursor != '\n' && *l->cursor != '\r')
        lexer_advance(l);
      continue;
    }
    if (c == '/' && l->cursor[1] == '*') {
      SourcePosition loc = lexer_position(l);
      lexer_advance(l);
      lexer_advance(l);
      for (;;) {
        if (*l->cursor == '\0')
          error_at(loc, "unterminated comment");
        if (*l->cursor == '*' && l->cursor[1] == '/') {
          lexer_advance(l);
          lexer_advance(l);
          break;
        }
        lexer_advance(l);
      }
      continue;
    }
    return;
  }
}

Token lexer_next_token(Lexer *l) {
  Token tok;

  skip_whitespace(l);
  tok = (Token){0};
  tok.start = l->cursor;
  tok.file = l->file;
  tok.line = l->line;
  tok.col = l->col;
  if (*l->cursor == '\0') {
    tok.kind = TOKEN_EOF;
    return tok;
  }
  if (l->at_bol && *l->cursor == '#') {
    /*
     * '#' is not a C token, and this one starts a preprocessing directive.
     * Hand it to the preprocessor, which reads the directive and then asks
     * for the next token.
     */
    l->at_bol = false;
    tok.kind = TOKEN_HASH;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  }

  l->at_bol = false;
  tok.kind = TOKEN_UNKNOW;
  tok.len = 1;

  switch (*l->cursor) {
  case '"':
    return read_string_literal(l, tok);
  case '\'':
    return read_char_literal(l, tok);
  case ';':
    tok.kind = TOKEN_SEMICOLON;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case ':':
    tok.kind = TOKEN_COLON;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '?':
    tok.kind = TOKEN_QUESTION;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case ',':
    tok.kind = TOKEN_COMMA;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '+':
    lexer_advance(l);
    if (*l->cursor == '+') {
      lexer_advance(l);
      tok.kind = TOKEN_PLUS_PLUS;
      tok.len = 2;
    } else if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_PLUS_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_PLUS;
      tok.len = 1;
    }
    return tok;
  case '-':
    lexer_advance(l);
    if (*l->cursor == '>') {
      lexer_advance(l);
      tok.kind = TOKEN_ARROW;
      tok.len = 2;
    } else if (*l->cursor == '-') {
      lexer_advance(l);
      tok.kind = TOKEN_MINUS_MINUS;
      tok.len = 2;
    } else if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_MINUS_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_MINUS;
      tok.len = 1;
    }
    return tok;
  case '*':
    lexer_advance(l);
    if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_STAR_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_STAR;
      tok.len = 1;
    }
    return tok;
  case '/':
    lexer_advance(l);
    if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_SLASH_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_SLASH;
      tok.len = 1;
    }
    return tok;
  case '(':
    tok.kind = TOKEN_LPAREN;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case ')':
    tok.kind = TOKEN_RPAREN;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '{':
    tok.kind = TOKEN_LBRACE;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '}':
    tok.kind = TOKEN_RBRACE;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '[':
    tok.kind = TOKEN_LBRACKET;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case ']':
    tok.kind = TOKEN_RBRACKET;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '.':
    if (l->cursor[1] == '.' && l->cursor[2] == '.') {
      tok.kind = TOKEN_ELLIPSIS;
      tok.len = 3;
      lexer_advance(l);
      lexer_advance(l);
      lexer_advance(l);
      return tok;
    }
    tok.kind = TOKEN_DOT;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '~':
    tok.kind = TOKEN_TILDE;
    tok.len = 1;
    lexer_advance(l);
    return tok;
  case '!':
    lexer_advance(l);
    if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_NOT_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_BANG;
      tok.len = 1;
    }
    return tok;
  case '&':
    lexer_advance(l);
    if (*l->cursor == '&') {
      lexer_advance(l);
      tok.kind = TOKEN_AND_AND;
      tok.len = 2;
    } else if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_BIT_AND_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_BIT_AND;
      tok.len = 1;
    }
    return tok;
  case '|':
    lexer_advance(l);
    if (*l->cursor == '|') {
      lexer_advance(l);
      tok.kind = TOKEN_OR_OR;
      tok.len = 2;
    } else if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_BIT_OR_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_BIT_OR;
      tok.len = 1;
    }
    return tok;
  case '^':
    lexer_advance(l);
    if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_BIT_XOR_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_BIT_XOR;
      tok.len = 1;
    }
    return tok;
  case '=':
    lexer_advance(l);
    if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_EQ_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_ASSIGN;
      tok.len = 1;
    }
    return tok;
  case '<':
    lexer_advance(l);
    if (*l->cursor == '<') {
      lexer_advance(l);
      if (*l->cursor == '=') {
        lexer_advance(l);
        tok.kind = TOKEN_LSHIFT_EQ;
        tok.len = 3;
      } else {
        tok.kind = TOKEN_LSHIFT;
        tok.len = 2;
      }
    } else if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_LESS_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_LESS;
      tok.len = 1;
    }
    return tok;
  case '>':
    lexer_advance(l);
    if (*l->cursor == '>') {
      lexer_advance(l);
      if (*l->cursor == '=') {
        lexer_advance(l);
        tok.kind = TOKEN_RSHIFT_EQ;
        tok.len = 3;
      } else {
        tok.kind = TOKEN_RSHIFT;
        tok.len = 2;
      }
    } else if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_GREATER_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_GREATER;
      tok.len = 1;
    }
    return tok;
  case '%':
    lexer_advance(l);
    if (*l->cursor == '=') {
      lexer_advance(l);
      tok.kind = TOKEN_PERCENT_EQ;
      tok.len = 2;
    } else {
      tok.kind = TOKEN_PERCENT;
      tok.len = 1;
    }
    return tok;
  }

  if (isdigit((unsigned char)*l->cursor)) {
    uint64_t int_literal_val;
    int base;

    int_literal_val = 0;

    /* C11: a leading zero makes an integer constant octal. */
    base = *l->cursor == '0' ? 8 : 10;
    while (isdigit((unsigned char)*l->cursor)) {
      int digit;
      digit = *l->cursor - '0';

      if (base == 8 && digit >= 8)
        error_at(tok, "invalid digit in octal integer literal");
      if (int_literal_val > (UINT64_MAX - digit) / base)
        error_at(tok,
                 "integer literal out of range for 64-bit unsigned integer");
      int_literal_val = int_literal_val * base + digit;
      lexer_advance(l);
    }

    tok.d.int_literal.suffix = read_int_suffix(l, tok);
    tok.kind = TOKEN_INT_LITERAL;
    tok.len = (int)(l->cursor - tok.start);
    tok.d.int_literal.val = int_literal_val;
    return tok;
  }

  if (isalpha((unsigned char)*l->cursor) || *l->cursor == '_') {
    while (isalnum((unsigned char)*l->cursor) || *l->cursor == '_') {
      lexer_advance(l);
    }
    tok.len = (int)(l->cursor - tok.start);
    tok.kind = kw_token_type(&tok);

    return tok;
  }

  lexer_advance(l);

  return tok;
}
