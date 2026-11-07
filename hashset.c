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

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "hashset.h"

void hashset_init(HashSet *set) {
  set->entries = NULL;
  set->len = 0;
  set->capacity = 0;
}

static size_t hash_pointer(const void *key) {
  uintptr_t bits = (uintptr_t)key;
  /*
   * Mix address bits so aligned pointers do not cluster in adjacent slots.
   */
  bits ^= bits >> 16;
  bits *= 73244475U;
  bits ^= bits >> 16;
  return (size_t)bits;
}

static size_t find_slot(const HashSet *set, const void *key) {
  size_t index = hash_pointer(key) & (set->capacity - 1);
  while (set->entries[index] && set->entries[index] != key)
    index = (index + 1) & (set->capacity - 1);
  return index;
}

bool hashset_contains(const HashSet *set, const void *key) {
  return key && set->len && set->entries[find_slot(set, key)] == key;
}

static bool hashset_grow(HashSet *set) {
  HashSet grown;
  size_t i;
  size_t limit = SIZE_MAX / sizeof(*set->entries);
  if (set->capacity > limit / 2)
    return false;
  hashset_init(&grown);
  grown.capacity = set->capacity ? set->capacity * 2 : 8;
  if (grown.capacity > limit)
    return false;
  grown.entries = calloc(grown.capacity, sizeof(*grown.entries));
  if (!grown.entries)
    return false;
  for (i = 0; i < set->capacity; ++i)
    if (set->entries[i])
      grown.entries[find_slot(&grown, set->entries[i])] = set->entries[i];
  grown.len = set->len;
  free(set->entries);
  *set = grown;
  return true;
}

bool hashset_add(HashSet *set, const void *key) {
  if (!key)
    return false;
  if (hashset_contains(set, key))
    return true;
  /*
   * Keep at least half the slots empty, including a terminator for probing.
   */
  if (set->len >= set->capacity / 2 && !hashset_grow(set))
    return false;
  set->entries[find_slot(set, key)] = key;
  ++set->len;
  return true;
}

bool hashset_copy(HashSet *dst, const HashSet *src) {
  const void **entries = NULL;
  if (dst == src)
    return true;
  if (src->capacity) {
    entries = malloc(src->capacity * sizeof(*entries));
    if (!entries)
      return false;
    memcpy(entries, src->entries, src->capacity * sizeof(*entries));
  }
  free(dst->entries);
  dst->entries = entries;
  dst->len = src->len;
  dst->capacity = src->capacity;
  return true;
}

void hashset_free(HashSet *set) {
  free(set->entries);
  hashset_init(set);
}
