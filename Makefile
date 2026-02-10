# contrib/remote_exec/Makefile

MODULES = efm_extension

EXTENSION = efm_extension
DATA = efm_extension--1.0.sql
PGFILEDESC = "efm_extension - remote execution"

REGRESS = 01_basic 02_properties_parse

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
