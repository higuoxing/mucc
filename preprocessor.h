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

#ifndef _PREPROCESSOR_H_
#define _PREPROCESSOR_H_

#include "lexer.h"
#include "vector.h"

/* One saved scanner state per open include; `outer` links to the enclosing
 * file. */
typedef struct IncludeFrame {
  Lexer lexer;
  struct IncludeFrame *outer;
} IncludeFrame;

/* One active object-like macro: a replacement list of already-lexed tokens. */
typedef struct Macro {
  const char *name;
  int len;
  Vector tokens; /* The replacement list, in source order. */
  /* Set while this macro is being expanded, which stops direct recursion. */
  bool expanding;
  struct Macro *next;
} Macro;

/* A cursor into one macro's replacement list, innermost last. */
typedef struct {
  Macro *macro; /* Not const: popping the frame clears macro->expanding. */
  int index;    /* Next token of macro->tokens to replay. */
} MacroFrame;

/*
 * The parser asks for tokens here, never from the lexer. Directives are
 * consumed in this layer, so the parser sees only preprocessing tokens.
 */
typedef struct {
  Lexer lexer;                  /* The file currently being read. */
  IncludeFrame *include_frames; /* Innermost first; NULL at the top level. */
  const Vector *include_paths;  /* char * directory names, in search order. */
  int include_depth;
  Macro *macros;     /* Defined macros, most recent first. */
  Vector expansions; /* MacroFrame, innermost last. */
} Preprocessor;

extern void pp_init(Preprocessor *pp, const SourceFile *file,
                    const Vector *include_paths);
extern Token pp_next_token(Preprocessor *pp);

#endif
