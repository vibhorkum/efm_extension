# contrib/efm_extension/Makefile
#
# PostgreSQL extension for EDB Failover Manager (EFM) integration
#
# Supports PostgreSQL 14+

EXTENSION = efm_extension
MODULE_big = efm_extension

# Source files
OBJS = efm_extension.o efm_cache.o efm_bgworker.o

# Extension data files
DATA = efm_extension--1.0.sql \
       efm_extension--1.1.sql \
       efm_extension--1.0--1.1.sql

PGFILEDESC = "efm_extension - EDB Failover Manager SQL interface"

# Regression tests
REGRESS = efm_extension
REGRESS_OPTS = --temp-config $(srcdir)/efm_extension.conf

# Use pg_config from PATH or specified location
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

# Get PostgreSQL version for compatibility checks
PG_VERSION := $(shell $(PG_CONFIG) --version | sed 's/[^0-9.]//g' | cut -d. -f1)

# Compiler flags
PG_CPPFLAGS = -I$(libpq_srcdir)
PG_CFLAGS = -Wall -Wmissing-prototypes -Wpointer-arith \
            -Wdeclaration-after-statement -Wendif-labels \
            -Wmissing-format-attribute -Wformat-security

# Enable additional warnings in debug mode
ifdef DEBUG
PG_CFLAGS += -g -O0 -DDEBUG
endif

# Shared library flags
SHLIB_LINK =

include $(PGXS)

# Custom targets

.PHONY: check-version clean-all install-headers

# Check PostgreSQL version compatibility
check-version:
	@if [ "$(PG_VERSION)" -lt "14" ]; then \
		echo "Error: PostgreSQL 14 or later required (found $(PG_VERSION))"; \
		exit 1; \
	fi
	@echo "PostgreSQL version $(PG_VERSION) - OK"

# Clean including backup files
clean-all: clean
	rm -f *.bak *.orig *~

# Print configuration info
info:
	@echo "Extension:    $(EXTENSION)"
	@echo "PG_CONFIG:    $(PG_CONFIG)"
	@echo "PG_VERSION:   $(PG_VERSION)"
	@echo "PGXS:         $(PGXS)"
	@echo "SHAREDIR:     $(shell $(PG_CONFIG) --sharedir)"
	@echo "PKGLIBDIR:    $(shell $(PG_CONFIG) --pkglibdir)"
