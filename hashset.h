/*
 * Hash sets for the self-hosted C compiler
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

#ifndef _HASHSET_H_
#define _HASHSET_H_

#include <stdbool.h>
#include <stddef.h>

/*
 * A set of non-null object pointers, compared by address. The set owns its
 * table, but not the pointed-to objects. Initialize before use. Empty slots
 * are NULL; insertion may grow the table and invalidate pointers into it.
 */
typedef struct {
  const void **entries;
  size_t len;
  size_t capacity;
} HashSet;

extern void hashset_init(HashSet *set);
extern bool hashset_contains(const HashSet *set, const void *key);

/*
 * Adding an existing key succeeds without changing the set. A null key,
 * allocation failure, or size overflow returns false without changing it.
 */
extern bool hashset_add(HashSet *set, const void *key);

/*
 * Copy into an initialized destination, replacing its storage. Failure leaves
 * the destination unchanged. The two sets can then be modified independently.
 */
extern bool hashset_copy(HashSet *dst, const HashSet *src);

/*
 * Free the table and leave an empty, reusable set.
 */
extern void hashset_free(HashSet *set);

#endif
