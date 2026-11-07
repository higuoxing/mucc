/*
 * Hash tables for the self-hosted C compiler
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

#ifndef _HASHTABLE_H_
#define _HASHTABLE_H_

#include <stdbool.h>
#include <stddef.h>

typedef struct {
  const char *key;
  size_t key_len;
  size_t hash;
  void *value;
} HashEntry;

/*
 * Maps byte strings to pointers. Keys need not be null-terminated and are
 * compared by contents and length. A key pointer must be non-null, including
 * for an empty key. Values may be NULL.
 *
 * The table owns its storage, but borrows keys and values. Key bytes must
 * remain alive and unchanged until removal or cleanup. Initialize before use;
 * insertion and removal may move entries. An empty slot has a NULL key.
 */
typedef struct {
  HashEntry *entries;
  size_t len;
  size_t capacity;
} HashTable;

extern void hashtable_init(HashTable *table);

/*
 * Return NULL if absent. Use contains to distinguish a stored NULL value.
 */
extern void *hashtable_get(const HashTable *table, const char *key,
                           size_t key_len);
extern bool hashtable_contains(const HashTable *table, const char *key,
                               size_t key_len);

/*
 * Insert or replace a value. Replacement retains the original key pointer.
 * A null key, allocation failure, or size overflow returns false without
 * changing the table. Replacing an existing value does not allocate.
 */
extern bool hashtable_put(HashTable *table, const char *key, size_t key_len,
                          void *value);

/*
 * Remove a key without freeing its bytes or value. Return false if absent.
 */
extern bool hashtable_remove(HashTable *table, const char *key, size_t key_len);

/*
 * Free the table storage and leave an empty, reusable table.
 */
extern void hashtable_free(HashTable *table);

#endif
