# contrib/efm_extension/Makefile
# PostgreSQL Extension for EFM (EDB Failover Manager)

MODULES = efm_extension

EXTENSION = efm_extension
DATA = efm_extension--1.0.sql
PGFILEDESC = "efm_extension - SQL interface to EFM commands"

REGRESS = 01_basic 02_properties_parse

# Security and quality compiler flags (no -Wextra due to PG headers)
PG_CPPFLAGS = -Wall -Werror -Wformat-security

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Version check: Ensure PostgreSQL 12+
PG_VERSION_NUM := $(shell $(PG_CONFIG) --version | sed 's/^PostgreSQL \([0-9]*\)\.\([0-9]*\).*/\1\2/')
ifeq ($(shell test $(PG_VERSION_NUM) -lt 12 && echo 1), 1)
    $(error PostgreSQL 12 or later is required. Found version $(shell $(PG_CONFIG) --version))
endif
