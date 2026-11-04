/*
 * Builtin declarations for the self-hosted C compiler
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

#ifndef _BUILTINS_H_
#define _BUILTINS_H_

#include "parser.h"

extern Type builtin_type_va_list;

/*
 * Register predefined types and declarations in the translation-unit scope.
 */
extern void declare_builtins(Parser *p);

/*
 * Return the builtin's AST kind, or AST_CALL for an ordinary function name.
 */
extern AstKind builtin_kind(Token name);

#endif
