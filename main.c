/*
 * Main driver for the self-hosted C compiler
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "codegen.h"
#include "layout.h"
#include "parser.h"

static void usage(const char *prog) {
  fprintf(stderr, "Usage: %s [-I dir]... <filename> [-o <output>]\n", prog);
  exit(1);
}

/*
 * Derive the assembly file name from the input one, mirroring 'gcc -S':
 * 'foo.c' becomes 'foo.s', and a name without a dot gets '.s' appended.
 */
static char *derive_output_path(const char *input) {
  const char *slash;
  const char *name;
  const char *dot;
  size_t base_len;
  char *path;

  slash = strrchr(input, '/');
  name = slash ? slash + 1 : input;
  dot = strrchr(name, '.');
  /* A leading dot is part of a hidden file name, not an extension. */
  base_len = dot && dot != name ? (size_t)(dot - input) : strlen(input);

  path = malloc(base_len + 3);
  if (!path) {
    fprintf(stderr, "failed to allocate output file name\n");
    exit(1);
  }
  memcpy(path, input, base_len);
  memcpy(path + base_len, ".s", 3); /* Includes the terminating NUL. */
  return path;
}

int main(int argc, char **argv) {
  const char *filename = NULL;
  const char *output = NULL;
  Vector include_paths;
  char *derived = NULL;
  FILE *out_file;
  SourceFile *file;
  AstNode *tree;
  int i;

  vector_init(&include_paths, sizeof(const char *));

  for (i = 1; i < argc; ++i) {
    const char *path = NULL;
    if (strcmp(argv[i], "-o") == 0) {
      if (i + 1 >= argc)
        usage(argv[0]);
      output = argv[++i];
    } else if (strcmp(argv[i], "-I") == 0) {
      if (i + 1 >= argc)
        usage(argv[0]);
      path = argv[++i];
    } else if (strncmp(argv[i], "-I", 2) == 0 && argv[i][2] != '\0') {
      path = argv[i] + 2;
    } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
      usage(argv[0]);
    } else if (!filename) {
      filename = argv[i];
    } else {
      usage(argv[0]);
    }
    if (path && !vector_push(&include_paths, &path)) {
      fprintf(stderr, "failed to allocate include paths\n");
      exit(1);
    }
  }

  if (!filename)
    usage(argv[0]);

  file = new_source_file(filename);
  if (!file) {
    fprintf(stderr, "failed to open file '%s'\n", filename);
    exit(1);
  }
  tree = parse_translation_unit(file, &include_paths);
  vector_free(&include_paths);
  assign_stack_offsets(filename, tree);

  if (output && strcmp(output, "-") == 0) {
    /* '-o -' writes assembly to stdout, like gcc and clang. */
    out_file = stdout;
  } else {
    if (!output)
      output = derived = derive_output_path(filename);

    /* Refuse an output path that is the same string as the input path. */
    if (strcmp(filename, output) == 0) {
      fprintf(stderr, "refusing to overwrite input file '%s'\n", filename);
      exit(1);
    }

    out_file = fopen(output, "wb");
    if (!out_file) {
      fprintf(stderr, "failed to open output file '%s'\n", output);
      exit(1);
    }
  }

  codegen(tree, out_file);

  if (out_file != stdout && fclose(out_file) != 0) {
    fprintf(stderr, "failed to write output file '%s'\n", output);
    exit(1);
  }

  free(derived);

  return 0;
}
