# Makefile for NetRunner native code
#
# Builds these files in PRIV_DIR, which defaults to priv/:
#   shepherd       - persistent child-process shepherd binary
#   net_runner_nif - NIF shared library for async I/O
#
# Only a value on the make command line overrides PRIV_DIR. It is assigned
# with = so that an unrelated PRIV_DIR in the environment cannot move the
# output.

PRIV_DIR = priv
C_SRC_DIR = c_src

# Erlang NIF include paths
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts/erts-~ts/include\", [code:root_dir(), erlang:system_info(version)])." -s init stop)

# Platform detection
UNAME_S := $(shell uname -s)

CC ?= cc

# Opt-in sanitizer build. Usage:
#   make clean && SANITIZE=1 make all
#   mix test (from Elixir — the NIF and shepherd are rebuilt with ASan/UBSan)
#
# Requires LD_PRELOAD of libasan at runtime on Linux when the BEAM isn't
# built with sanitizers; see ci.yml for the invocation.

# -Werror is opt-in: CI sets WERROR=1, while package consumers compile
# warning-tolerant (newer compilers keep growing new warnings).
WERROR ?= 0

WARNINGS = -Wall -Wextra -Wformat-security -Wvla -Wshadow
ifeq ($(WERROR),1)
	WARNINGS += -Werror
endif

ifeq ($(SANITIZE),1)
	# _FORTIFY_SOURCE is incompatible with ASan (ASan already intercepts
	# memcpy/etc.). Disable optimisation to -O1 and skip FORTIFY.
	SAN_FLAGS = -fsanitize=address,undefined -fno-omit-frame-pointer -g
	CFLAGS_BASE = -O1 $(WARNINGS) -std=c99 -fstack-protector-strong $(SAN_FLAGS)
else
	# -U first: some toolchains predefine _FORTIFY_SOURCE and a bare -D
	# redefinition is itself a warning (fatal under -Werror).
	CFLAGS_BASE = -O2 $(WARNINGS) -std=c99 -fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2
endif

ifeq ($(UNAME_S),Darwin)
	# macOS needs _DARWIN_C_SOURCE for SCM_RIGHTS, CMSG_SPACE, etc.
	# += so packager-provided CFLAGS are honored, not clobbered.
	CFLAGS += $(CFLAGS_BASE) -D_DARWIN_C_SOURCE
	NIF_LDFLAGS = -dynamiclib -undefined dynamic_lookup
	NIF_EXT = .so
else
	CFLAGS += $(CFLAGS_BASE) -D_GNU_SOURCE
	NIF_LDFLAGS = -shared -Wl,-z,relro,-z,now -Wl,-z,noexecstack
	SHEPHERD_LDFLAGS = -pie -Wl,-z,relro,-z,now -Wl,-z,noexecstack
	NIF_EXT = .so
endif

# SHEPHERD_STATIC=1 links the shepherd as a static PIE. The NIF does not need
# this, because it uses the libc that the BEAM loads.
ifeq ($(SHEPHERD_STATIC),1)
ifeq ($(UNAME_S),Darwin)
$(error SHEPHERD_STATIC=1 is Linux-only: macOS has no static libc)
endif
ifeq ($(SANITIZE),1)
$(error SHEPHERD_STATIC=1 cannot be combined with SANITIZE=1: the sanitizer runtimes do not link statically)
endif
	SHEPHERD_LDFLAGS += -static-pie
endif

ifeq ($(SANITIZE),1)
	NIF_LDFLAGS += $(SAN_FLAGS)
	SHEPHERD_LDFLAGS += $(SAN_FLAGS)
endif

# -fvisibility=hidden: only nif_init needs to be exported, and ERL_NIF_INIT
# already marks it default-visible.
NIF_CFLAGS = $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -fPIC -fvisibility=hidden

SHEPHERD_CFLAGS = $(CFLAGS) -fPIE

# Targets
SHEPHERD = $(PRIV_DIR)/shepherd
NIF_LIB = $(PRIV_DIR)/net_runner_nif$(NIF_EXT)

SHEPHERD_SRC = $(C_SRC_DIR)/shepherd.c
NIF_SRC = $(C_SRC_DIR)/net_runner_nif.c

HEADERS = $(C_SRC_DIR)/protocol.h $(C_SRC_DIR)/utils.h

.PHONY: all clean asan bench bench-perf bench-claims bench-deadlock bench-spawn bench-exec

all: $(SHEPHERD) $(NIF_LIB)

# Convenience: force a sanitizer rebuild. Same as SANITIZE=1 make clean all.
asan:
	$(MAKE) clean
	$(MAKE) SANITIZE=1 all

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(SHEPHERD) $(NIF_LIB): | $(PRIV_DIR)

# Each binary has one source file, so each rule compiles and links it in one
# command.
$(SHEPHERD): $(SHEPHERD_SRC) $(HEADERS)
	$(CC) $(SHEPHERD_CFLAGS) $(SHEPHERD_LDFLAGS) $(LDFLAGS) -o $@ $<

$(NIF_LIB): $(NIF_SRC) $(HEADERS)
	$(CC) $(NIF_CFLAGS) $(NIF_LDFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(SHEPHERD) $(NIF_LIB)

# --- Benchmarks (repo-only; see bench/README.md) ---
#
# MIX_ENV=prod is not optional: the BEAM side compiles differently in dev and
# dev-mode numbers are not comparable to anything published.
BENCH_ENV = MIX_ENV=prod

bench: bench-perf bench-claims bench-deadlock bench-spawn bench-exec

bench-perf:
	$(BENCH_ENV) mix run bench/perf.exs

bench-claims:
	$(BENCH_ENV) mix run bench/claims.exs

bench-deadlock:
	$(BENCH_ENV) mix run bench/deadlock_probe.exs

bench-spawn:
	$(BENCH_ENV) mix run bench/spawn_breakdown.exs

bench-exec:
	$(BENCH_ENV) mix run bench/exec_baseline.exs
