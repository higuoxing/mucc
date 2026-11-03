/*
 * Stack and argument layout for the self-hosted C compiler
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

#ifndef _LAYOUT_H_
#define _LAYOUT_H_

#include <stdint.h>

#include "parser.h"

extern int register_count(const Type *type);
extern bool return_in_memory(const Type *type);
/*
 * Return the first argument register, or -1 for a stack argument, and advance
 * the counters. A stack argument starts at stack_size's value before the call.
 */
extern int layout_argument(const Type *type, int *nregisters,
                           int64_t *stack_size);

/*
 * Assign parameter and local offsets and function stack sizes in a completed
 * translation unit. Report target stack-size limits before assembly emission.
 */
extern void assign_stack_offsets(const char *filename, AstNode *ast);

#endif
