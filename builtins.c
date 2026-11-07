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

#include <string.h>

#include "builtins.h"
#include "sema.h"

/*
 * System V AMD64 va_list is an array of one record. Its fields are shared
 * with host compilers and libc, including functions such as vfprintf.
 */
static Member va_list_members[] = {
    {.name = {.kind = TOKEN_IDENTIFIER, .start = "gp_offset", .len = 9},
     .type = &builtin_type_unsigned,
     .offset = 0,
     .next = &va_list_members[1]},
    {.name = {.kind = TOKEN_IDENTIFIER, .start = "fp_offset", .len = 9},
     .type = &builtin_type_unsigned,
     .offset = 4,
     .next = &va_list_members[2]},
    {.name = {.kind = TOKEN_IDENTIFIER,
              .start = "overflow_arg_area",
              .len = 17},
     .type = &builtin_type_void_ptr,
     .offset = 8,
     .next = &va_list_members[3]},
    {.name = {.kind = TOKEN_IDENTIFIER, .start = "reg_save_area", .len = 13},
     .type = &builtin_type_void_ptr,
     .offset = 16},
};
static Type va_list_record = {.kind = TYPE_STRUCT,
                              .size = 24,
                              .members = va_list_members,
                              .alignment = 8};
Type builtin_type_va_list = {
    .kind = TYPE_ARRAY, .size = 24, .base = &va_list_record, .array_len = 1};

static const struct {
  const char *name;
  AstKind kind;
} builtins[] = {
    {"__builtin_va_start", AST_VA_START},
    {"__builtin_va_arg", AST_VA_ARG},
    {"__builtin_va_end", AST_VA_END},
    {"__builtin_va_copy", AST_VA_COPY},
};

AstKind builtin_kind(Token name) {
  size_t i;
  for (i = 0; i < sizeof(builtins) / sizeof(builtins[0]); ++i) {
    Token builtin_name = {.start = builtins[i].name,
                          .len = (int)strlen(builtins[i].name)};
    if (same_identifier(name, builtin_name))
      return builtins[i].kind;
  }
  return AST_CALL;
}

void declare_builtins(Parser *p) {
  Member *member;
  for (member = va_list_record.members; member; member = member->next)
    if (!hashtable_put(&va_list_record.member_names, member->name.start,
                       (size_t)member->name.len, member))
      error_at(member->name, "out of memory");
  Token va_list_name = {.kind = TOKEN_IDENTIFIER,
                        .start = "__builtin_va_list",
                        .len = sizeof("__builtin_va_list") - 1};
  add_symbol(p, va_list_name, SYMBOL_TYPEDEF, &builtin_type_va_list, 0);
}
