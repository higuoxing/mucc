/*
 * Diagnostics for the self-hosted C compiler
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

#ifndef _ERROR_H_
#define _ERROR_H_

#include "lexer.h"

/* Print "filename:line:col: error: ..." and exit. */
extern void error_at_loc(const char *filename, int line, int col,
                         const char *fmt, ...);

/*
 * Report at a token, a SourcePosition, or an inline expression giving file,
 * line, and column. Keeping the field names identical lets one macro serve
 * all three.
 */
#define error_at(where, ...)                                                   \
  do {                                                                         \
    error_at_loc(file_name((where).file), (where).line, (where).col,           \
                 __VA_ARGS__);                                                 \
    exit(1);                                                                   \
  } while (0)

#endif
