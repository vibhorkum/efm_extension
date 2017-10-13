# contrib/remote_exec/Makefile

MODULES = efm_sql_command

EXTENSION = efm_sql_command
DATA = efm_sql_command--1.0.sql
PGFILEDESC = "efm_sql_command - remote execution"

REGRESS = efm_sql_command

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
