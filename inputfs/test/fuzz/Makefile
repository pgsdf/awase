# Makefile for the AD-9 inputfs HID parser fuzz harness.
#
# Per inputfs/docs/adr/0014-hid-fuzzing-scope.md.
#
# Usage:
#   make            - build the harness with AddressSanitizer
#   make smoke      - run the harness against corpus/known-good.bin
#   make clean      - remove built artefacts
#   make help       - show this list
#
# Configurable variables (override on the command line):
#   CC          - compiler. Default: cc.
#   FUZZ_CFLAGS - extra flags appended to CFLAGS. Default: empty.
#   FUZZ_LDFLAGS- extra flags appended to LDFLAGS. Default: empty.
#
# Example:
#   make CC=clang FUZZ_CFLAGS="-O2"
#
# Source layout:
#   kernel_shim.h               - force-included on every TU
#   shim_includes/              - empty stubs for kernel headers
#                                  and replacements for opt_hid.h
#                                  and hid_if.h
#   vendored/dev/hid/hid.c      - verbatim FreeBSD source
#   vendored/dev/hid/hid.h      - verbatim FreeBSD source
#   vendored/dev/hid/hidquirk.h - verbatim FreeBSD source
#   main.c                      - harness driver
#   ../../sys/dev/inputfs/inputfs_parser.{c,h}
#                               - inputfs's parser surface,
#                                  shared with the kernel module

CC ?= cc

PARSER_DIR := ../../sys/dev/inputfs

# AddressSanitizer is on by default. The harness exists to find
# memory-safety bugs; not enabling ASan would defeat the purpose.
SANITIZE := -fsanitize=address -fno-omit-frame-pointer

# Warning suppressions for the *vendored* hid.c. These are
# pre-existing FreeBSD-upstream patterns we do not want to
# patch; each is benign:
#   -Wno-sign-compare        - compares uint32_t HID usages
#                              with int32_t literals
#   -Wno-type-limits         - "always-false" comparison on
#                              an unsigned exponent that the
#                              kernel build also sees
#   -Wno-unused-parameter    - hid_test_quirk_w / hid_quirk_unload
#                              ignore their arguments
#   -Wno-unused-const-variable - our shim's SYSCTL_NODE/INT and
#                              MODULE_VERSION expansions create
#                              file-scope constants per macro
#                              expansion which are never read
WARN_SUPPRESS := \
	-Wno-sign-compare \
	-Wno-type-limits \
	-Wno-unused-parameter \
	-Wno-unused-const-variable

# Common include / preprocessor flags.
SHIM_FLAGS := \
	-include kernel_shim.h \
	-I shim_includes \
	-I vendored \
	-I $(PARSER_DIR)

CFLAGS := -O0 -g -Wall -Wextra -std=gnu11 \
	$(SHIM_FLAGS) $(WARN_SUPPRESS) $(SANITIZE) $(FUZZ_CFLAGS)

LDFLAGS := $(SANITIZE) $(FUZZ_LDFLAGS)

OBJS := \
	main.o \
	hid.o \
	inputfs_parser.o

.PHONY: all smoke clean help

all: inputfs-fuzz

inputfs-fuzz: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS)

main.o: main.c kernel_shim.h $(PARSER_DIR)/inputfs_parser.h
	$(CC) $(CFLAGS) -c main.c -o $@

hid.o: vendored/dev/hid/hid.c kernel_shim.h \
       vendored/dev/hid/hid.h vendored/dev/hid/hidquirk.h \
       shim_includes/opt_hid.h shim_includes/hid_if.h
	$(CC) $(CFLAGS) -c vendored/dev/hid/hid.c -o $@

inputfs_parser.o: $(PARSER_DIR)/inputfs_parser.c \
                  $(PARSER_DIR)/inputfs_parser.h kernel_shim.h
	$(CC) $(CFLAGS) -c $(PARSER_DIR)/inputfs_parser.c -o $@

smoke: inputfs-fuzz
	@echo "=== smoke 1: empty input ==="
	@printf "" | ./inputfs-fuzz; \
	    if [ $$? -eq 0 ]; then echo "  PASS"; else echo "  FAIL"; exit 1; fi
	@echo "=== smoke 2: known-good descriptor ==="
	@if [ ! -f corpus/known-good.bin ]; then \
	    echo "  SKIP (no corpus/known-good.bin)"; \
	else \
	    ./inputfs-fuzz corpus/known-good.bin; \
	    if [ $$? -eq 0 ]; then echo "  PASS"; else echo "  FAIL"; exit 1; fi; \
	fi
	@echo "=== smoke 3: random 4KB ==="
	@head -c 4096 /dev/urandom | ./inputfs-fuzz; \
	    if [ $$? -eq 0 ]; then echo "  PASS"; else echo "  FAIL"; exit 1; fi
	@echo
	@echo "All smoke tests passed."

clean:
	rm -f inputfs-fuzz $(OBJS)

help:
	@echo "Targets:"
	@echo "  make         - build the harness (default)"
	@echo "  make smoke   - run smoke tests"
	@echo "  make clean   - remove built artefacts"
	@echo "  make help    - this message"
