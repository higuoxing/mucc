CC := gcc
OPT := -O2
CFLAGS := -std=c11 -Wall -Wextra -Wpedantic -Werror $(OPT)
TARGET := mucc

SRCS := main.c lexer.c preprocessor.c error.c type.c builtins.c parser.c sema.c layout.c codegen.c vector.c hashset.c
OBJS := $(SRCS:.c=.o)
DEPS := $(OBJS:.o=.d)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $^ -o $@

%.o: %.c
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

-include $(DEPS)

clean:
	rm -f $(OBJS) $(DEPS) $(TARGET)
	rm -rf build

test: $(TARGET)
	./test.sh

fmt:
	@echo "Formatting ..."
	@clang-format -i *.h *.c include/*.h
	@shfmt -ln bash -i 2 -ci -w test.sh

# Bootstrap follows GCC. stage-1 is built by the host compiler. Each later
# stage is built by the previous one. The host compiler still preprocesses
# and assembles. compare checks that stage-2 and stage-3 emit the same assembly.
STAGE2_DIR := build/stage-2
STAGE3_DIR := build/stage-3
STAGE_HEADERS := $(wildcard *.h include/*.h)

stage-1: $(TARGET)

# $(1) is the stage directory. $(2) is the compiler that reads preprocessed input.
define STAGE_RULES
$(1):
	mkdir -p $$@

$(1)/%.i: %.c $$(STAGE_HEADERS) | $(1)
	$$(CC) -std=c11 -E -P -nostdinc -I include $$< -o $$@

$(1)/%.s: $(1)/%.i $(2)
	./$(2) $$< -o $$@

$(1)/%.o: $(1)/%.s
	$$(CC) -c $$< -o $$@

$(1)/mucc: $$(patsubst %.c,$(1)/%.o,$$(SRCS))
	$$(CC) $$^ -o $$@

.PRECIOUS: $(1)/%.i $(1)/%.s
endef

$(eval $(call STAGE_RULES,$(STAGE2_DIR),$(TARGET)))
$(eval $(call STAGE_RULES,$(STAGE3_DIR),$(STAGE2_DIR)/mucc))

stage-2: $(STAGE2_DIR)/mucc
stage-3: $(STAGE3_DIR)/mucc

compare: $(patsubst %.c,$(STAGE2_DIR)/%.s,$(SRCS)) $(patsubst %.c,$(STAGE3_DIR)/%.s,$(SRCS))
	@fail=0; \
	for src in $(SRCS); do \
		stem=$${src%.c}; \
		if ! cmp -s $(STAGE2_DIR)/$$stem.s $(STAGE3_DIR)/$$stem.s; then \
			printf 'stage-2 and stage-3 differ: %s.s\n' "$$stem" >&2; \
			fail=1; \
		fi; \
	done; \
	if [ "$$fail" -ne 0 ]; then exit 1; fi
	@echo "stage-2 and stage-3 assembly match."

bootstrap: compare

stage-2-test: stage-2
	TEST_CC=$(STAGE2_DIR)/mucc ./test.sh

stage-3-test: stage-3
	TEST_CC=$(STAGE3_DIR)/mucc ./test.sh

.PHONY: all test clean fmt stage-1 stage-2 stage-3 compare bootstrap stage-2-test stage-3-test
