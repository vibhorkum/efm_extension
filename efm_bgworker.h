/*-------------------------------------------------------------------------
 *
 * efm_bgworker.h
 *      Background worker for periodic EFM status polling
 *
 * Copyright (c) 2024, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#ifndef EFM_BGWORKER_H
#define EFM_BGWORKER_H

#include "postgres.h"

/* Background worker configuration GUCs */
extern bool efm_bgw_enabled;
extern int efm_bgw_interval;
extern char *efm_bgw_database;
extern bool efm_bgw_persist_history;

/* Function declarations */
extern void efm_register_bgworker(void);

/* Main entry point - must be PGDLLEXPORT for dynamic loading */
PGDLLEXPORT void efm_bgworker_main(Datum main_arg);

#endif /* EFM_BGWORKER_H */
