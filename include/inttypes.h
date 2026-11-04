/*
 * Declarations required to compile mucc. This is not a complete libc header.
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

#ifndef _MUCC_INTTYPES_H_
#define _MUCC_INTTYPES_H_

/* LP64: int64_t is long, so the printf length modifier is l. */
#define PRId64 "ld"
#define PRIu64 "lu"
#define PRIu32 "u"

#endif
