# contrib/remote_exec/Makefile

MODULES = efm_extension

EXTENSION = efm_extension
DATA = efm_extension--1.0.sql
PGFILEDESC = "efm_extension - remote execution"

REGRESS = efm_extension

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
