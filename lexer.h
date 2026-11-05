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

#ifndef _LEXER_H_
#define _LEXER_H_

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef enum {
  TOKEN_UNKNOW = -1,
  TOKEN_EOF = 0,
  TOKEN_AND_AND,    /* '&&' */
  TOKEN_ARROW,      /* '->' */
  TOKEN_ASSIGN,     /* '=' */
  TOKEN_BANG,       /* '!' */
  TOKEN_BIT_AND,    /* '&' */
  TOKEN_BIT_AND_EQ, /* '&=' */
  TOKEN_BIT_OR,     /* '|' */
  TOKEN_BIT_OR_EQ,  /* '|=' */
  TOKEN_BIT_XOR,    /* '^' */
  TOKEN_BIT_XOR_EQ, /* '^=' */
  TOKEN_BOOL,       /* '_Bool' */
  TOKEN_BREAK,      /* 'break' */
  TOKEN_CASE,       /* 'case' */
  TOKEN_CHAR,       /* 'char' */
  TOKEN_COLON,      /* ':' */
  TOKEN_COMMA,      /* ',' */
  TOKEN_CONST,      /* 'const' */
  TOKEN_CONTINUE,   /* 'continue' */
  TOKEN_DEFAULT,    /* 'default' */
  TOKEN_DO,         /* 'do' */
  TOKEN_DOT,        /* '.' */
  TOKEN_ELLIPSIS,   /* '...' */
  TOKEN_ELSE,       /* 'else' */
  TOKEN_ENUM,       /* 'enum' */
  TOKEN_EQ_EQ,      /* '==' */
  TOKEN_EXTERN,     /* 'extern' */
  TOKEN_FOR,        /* 'for' */
  TOKEN_GOTO,       /* 'goto' */
  TOKEN_GREATER,    /* '>' */
  TOKEN_GREATER_EQ, /* '>=' */
  TOKEN_HASH,       /* '#' at line start: a preprocessing directive. */
  TOKEN_IDENTIFIER,
  TOKEN_IF,  /* 'if' */
  TOKEN_INT, /* 'int' */
  TOKEN_INT_LITERAL,
  TOKEN_LBRACE,      /* '{' */
  TOKEN_LBRACKET,    /* '[' */
  TOKEN_LESS,        /* '<' */
  TOKEN_LESS_EQ,     /* '<=' */
  TOKEN_LONG,        /* 'long' */
  TOKEN_LPAREN,      /* '(' */
  TOKEN_LSHIFT,      /* '<<' */
  TOKEN_LSHIFT_EQ,   /* '<<=' */
  TOKEN_MINUS,       /* '-' */
  TOKEN_MINUS_EQ,    /* '-=' */
  TOKEN_MINUS_MINUS, /* '--' */
  TOKEN_NOT_EQ,      /* '!=' */
  TOKEN_OR_OR,       /* '||' */
  TOKEN_PERCENT,     /* '%' */
  TOKEN_PERCENT_EQ,  /* '%=' */
  TOKEN_PLUS,        /* '+' */
  TOKEN_PLUS_EQ,     /* '+=' */
  TOKEN_PLUS_PLUS,   /* '++' */
  TOKEN_QUESTION,    /* '?' */
  TOKEN_RBRACE,      /* '}' */
  TOKEN_RBRACKET,    /* ']' */
  TOKEN_RESERVED,
  TOKEN_RETURN,
  TOKEN_RPAREN,    /* ')' */
  TOKEN_RSHIFT,    /* '>>' */
  TOKEN_RSHIFT_EQ, /* '>>=' */
  TOKEN_SEMICOLON,
  TOKEN_SHORT,    /* 'short' */
  TOKEN_SIZEOF,   /* 'sizeof' */
  TOKEN_SLASH,    /* '/' */
  TOKEN_SLASH_EQ, /* '/=' */
  TOKEN_STAR,     /* '*' */
  TOKEN_STAR_EQ,  /* '*=' */
  TOKEN_STATIC,   /* 'static' */
  TOKEN_STRING_LITERAL,
  TOKEN_STRUCT,   /* 'struct' */
  TOKEN_SWITCH,   /* 'switch' */
  TOKEN_TILDE,    /* '~' */
  TOKEN_TYPEDEF,  /* 'typedef' */
  TOKEN_UNION,    /* 'union' */
  TOKEN_UNSIGNED, /* 'unsigned' */
  TOKEN_VOID,     /* 'void' */
  TOKEN_WHILE,    /* 'while' */
} TokenKind;

enum {
  INT_SUFFIX_UNSIGNED = 1 << 0,
  INT_SUFFIX_LONG = 1 << 1,
  INT_SUFFIX_LONG_LONG = 1 << 2,
};

/*
 * One opened source buffer. Tokens and locations refer to it by the small
 * integer id, so a token costs one int rather than a name pointer.
 */
typedef struct SourceFile {
  const char *name;     /* Path as opened, for diagnostics. */
  const char *contents; /* NUL-terminated file contents. */
  int length;           /* Bytes, excluding the final NUL. */
  int id;               /* One-based index in the source file table. */
} SourceFile;

/*
 * Where something is, for diagnostics. A token can be reported directly; this
 * is for a position that has to be remembered before the cursor moves.
 */
typedef struct {
  int file; /* Source file id; 0 means no file (a synthesized token). */
  int line; /* One-based. */
  int col;  /* One-based byte column; tabs count as one byte. */
} SourcePosition;

typedef struct {
  TokenKind kind;
  const char *start; /* Points into the file this token was scanned from. */
  int len;
  int file; /* Source file id. */
  int line;
  int col;

  union {
    struct {
      uint64_t val;
      unsigned suffix; /* INT_SUFFIX_* flags. */
    } int_literal;
    struct {
      unsigned char *val; /* Owned decoded bytes, including final zero. */
      int len;            /* Decoded byte count, including final zero. */
    } string_literal;
  } d;
} Token;

/*
 * Scanner state for one source buffer. Line and column are maintained as the
 * cursor advances, so a diagnostic never has to rescan the file. The whole
 * struct is copied to save a position across an include.
 */
typedef struct {
  int file;           /* Source file id. */
  int line;           /* One-based. */
  int col;            /* One-based byte column; tabs count as one byte. */
  const char *cursor; /* Next byte to read. */
  /* The preprocessor treats '#' in this position as a directive. */
  bool at_bol;
  /*
   * Reading a directive: whitespace does not cross a newline, and running out
   * of line reports TOKEN_EOF so the caller can end the directive.
   */
  bool in_directive;
} Lexer;

extern bool same_identifier(Token a, Token b);
/* Read the lexer's current position, for a diagnostic reported later. */
extern SourcePosition lexer_position(const Lexer *l);
/*
 * Read a source file into a descriptor. NULL means it cannot be opened, so an
 * include search can try the next directory. Never freed: tokens point into it.
 */
extern SourceFile *new_source_file(const char *filename);
/* Path for a source file id, or NULL when the id is not one we opened. */
extern const char *file_name(int file);
extern void lexer_init(Lexer *l, const SourceFile *file);
extern void lexer_advance(Lexer *l);
extern void lexer_skip_horizontal(Lexer *l);
extern Token lexer_next_token(Lexer *l);

#endif
