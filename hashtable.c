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

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "hashtable.h"

void hashtable_init(HashTable *table) {
  table->entries = NULL;
  table->len = 0;
  table->capacity = 0;
}

static size_t hash_bytes(const char *key, size_t key_len) {
  uint64_t hash = 14695981039346656037UL;
  size_t i;
  /*
   * FNV-1a hashes exactly key_len bytes, including any embedded zeros.
   */
  for (i = 0; i < key_len; ++i) {
    hash ^= (unsigned char)key[i];
    hash *= 1099511628211UL;
  }
  return (size_t)hash;
}

static size_t find_slot(const HashTable *table, const char *key, size_t key_len,
                        size_t hash) {
  size_t index = hash & (table->capacity - 1);
  while (table->entries[index].key) {
    const HashEntry *entry = &table->entries[index];
    if (entry->hash == hash && entry->key_len == key_len &&
        memcmp(entry->key, key, key_len) == 0)
      break;
    index = (index + 1) & (table->capacity - 1);
  }
  return index;
}

static const HashEntry *find_entry(const HashTable *table, const char *key,
                                   size_t key_len) {
  const HashEntry *entry;
  if (!key || !table->len)
    return NULL;
  entry =
      &table->entries[find_slot(table, key, key_len, hash_bytes(key, key_len))];
  return entry->key ? entry : NULL;
}

void *hashtable_get(const HashTable *table, const char *key, size_t key_len) {
  const HashEntry *entry = find_entry(table, key, key_len);
  return entry ? entry->value : NULL;
}

bool hashtable_contains(const HashTable *table, const char *key,
                        size_t key_len) {
  return find_entry(table, key, key_len) != NULL;
}

static bool hashtable_grow(HashTable *table) {
  HashTable grown;
  size_t i;
  size_t limit = SIZE_MAX / sizeof(*table->entries);
  if (table->capacity > limit / 2)
    return false;
  hashtable_init(&grown);
  grown.capacity = table->capacity ? table->capacity * 2 : 8;
  if (grown.capacity > limit)
    return false;
  grown.entries = calloc(grown.capacity, sizeof(*grown.entries));
  if (!grown.entries)
    return false;
  for (i = 0; i < table->capacity; ++i) {
    HashEntry entry = table->entries[i];
    if (entry.key)
      grown.entries[find_slot(&grown, entry.key, entry.key_len, entry.hash)] =
          entry;
  }
  grown.len = table->len;
  free(table->entries);
  *table = grown;
  return true;
}

bool hashtable_put(HashTable *table, const char *key, size_t key_len,
                   void *value) {
  size_t hash;
  size_t index;
  HashEntry *entry;
  if (!key)
    return false;
  hash = hash_bytes(key, key_len);
  if (table->len) {
    index = find_slot(table, key, key_len, hash);
    if (table->entries[index].key) {
      table->entries[index].value = value;
      return true;
    }
  }
  /*
   * Keep at least half the slots empty so probing always finds a terminator.
   */
  if (table->len >= table->capacity / 2 && !hashtable_grow(table))
    return false;
  index = find_slot(table, key, key_len, hash);
  entry = &table->entries[index];
  entry->key = key;
  entry->key_len = key_len;
  entry->hash = hash;
  entry->value = value;
  ++table->len;
  return true;
}

bool hashtable_remove(HashTable *table, const char *key, size_t key_len) {
  size_t index;
  if (!key || !table->len)
    return false;
  index = find_slot(table, key, key_len, hash_bytes(key, key_len));
  if (!table->entries[index].key)
    return false;
  table->entries[index].key = NULL;
  --table->len;
  /*
   * Reinsert the rest of this probe cluster. Simply clearing the removed slot
   * would hide later colliding entries from lookup. This needs no allocation.
   */
  index = (index + 1) & (table->capacity - 1);
  while (table->entries[index].key) {
    HashEntry entry = table->entries[index];
    table->entries[index].key = NULL;
    table->entries[find_slot(table, entry.key, entry.key_len, entry.hash)] =
        entry;
    index = (index + 1) & (table->capacity - 1);
  }
  return true;
}

void hashtable_free(HashTable *table) {
  free(table->entries);
  hashtable_init(table);
}
