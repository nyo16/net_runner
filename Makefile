# Makefile for NetRunner native code
#
# Builds:
#   priv/shepherd       - persistent child-process shepherd binary
#   priv/net_runner_nif - NIF shared library for async I/O

PRIV_DIR = priv
C_SRC_DIR = c_src

# Erlang NIF include paths
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts/erts-~ts/include\", [code:root_dir(), erlang:system_info(version)])." -s init stop)
ERL_INTERFACE_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts\", [code:lib_dir(erl_interface, include)])." -s init stop)
ERL_INTERFACE_LIB_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts\", [code:lib_dir(erl_interface, lib)])." -s init stop)

# Platform detection
UNAME_S := $(shell uname -s)

CC ?= cc
CFLAGS_BASE = -O2 -Wall -Wextra -Werror -std=c99

ifeq ($(UNAME_S),Darwin)
	# macOS needs _DARWIN_C_SOURCE for SCM_RIGHTS, CMSG_SPACE, etc.
	CFLAGS = $(CFLAGS_BASE) -D_DARWIN_C_SOURCE
	NIF_LDFLAGS = -dynamiclib -undefined dynamic_lookup
	NIF_EXT = .so
else
	CFLAGS = $(CFLAGS_BASE) -D_GNU_SOURCE
	NIF_LDFLAGS = -shared
	NIF_EXT = .so
endif

NIF_CFLAGS = $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -I$(C_SRC_DIR) -fPIC

# Targets
SHEPHERD = $(PRIV_DIR)/shepherd
NIF_LIB = $(PRIV_DIR)/net_runner_nif$(NIF_EXT)

SHEPHERD_SRC = $(C_SRC_DIR)/shepherd.c
NIF_SRC = $(C_SRC_DIR)/net_runner_nif.c

SHEPHERD_OBJ = $(C_SRC_DIR)/shepherd.o
NIF_OBJ = $(C_SRC_DIR)/net_runner_nif.o

HEADERS = $(C_SRC_DIR)/protocol.h $(C_SRC_DIR)/utils.h

.PHONY: all clean

all: $(PRIV_DIR) $(SHEPHERD) $(NIF_LIB)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

# Shepherd binary
$(SHEPHERD): $(SHEPHERD_OBJ)
	$(CC) -o $@ $<

$(SHEPHERD_OBJ): $(SHEPHERD_SRC) $(HEADERS)
	$(CC) $(CFLAGS) -I$(C_SRC_DIR) -c -o $@ $<

# NIF shared library
$(NIF_LIB): $(NIF_OBJ)
	$(CC) $(NIF_LDFLAGS) -o $@ $<

$(NIF_OBJ): $(NIF_SRC) $(HEADERS)
	$(CC) $(NIF_CFLAGS) -c -o $@ $<

clean:
	rm -f $(SHEPHERD) $(NIF_LIB) $(SHEPHERD_OBJ) $(NIF_OBJ)
