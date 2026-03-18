/*-------------------------------------------------------------------------
 *
 * efm_bgworker.c
 *      Background worker for periodic EFM status polling
 *
 * This background worker periodically polls EFM for cluster status and
 * updates the shared memory cache. It can optionally persist status
 * history to a table for trending and alerting purposes.
 *
 * Copyright (c) 2024, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "efm_bgworker.h"
#include "efm_cache.h"
#include "efm_exec.h"

#include "access/xact.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/snapmgr.h"

/* GUC variables */
bool efm_bgw_enabled = false;
int efm_bgw_interval = 10;          /* Poll every 10 seconds */
char *efm_bgw_database = NULL;
bool efm_bgw_persist_history = false;

/* Signal handling */
static volatile sig_atomic_t got_sighup = false;
static volatile sig_atomic_t got_sigterm = false;

/*
 * Signal handler for SIGHUP
 */
static void
efm_bgw_sighup(SIGNAL_ARGS)
{
    int save_errno = errno;
    got_sighup = true;
    SetLatch(MyLatch);
    errno = save_errno;
}

/*
 * Signal handler for SIGTERM
 */
static void
efm_bgw_sigterm(SIGNAL_ARGS)
{
    int save_errno = errno;
    got_sigterm = true;
    SetLatch(MyLatch);
    errno = save_errno;
}

/*
 * Persist status to history table
 */
static void
efm_persist_status(const char *json_data)
{
    int ret;
    bool isnull;
    Oid argtypes[1] = { TEXTOID };
    Datum values[1];

    SetCurrentStatementStartTimestamp();
    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    values[0] = CStringGetTextDatum(json_data);

    ret = SPI_execute_with_args(
        "INSERT INTO efm_extension.efm_status_history "
        "(status_json, collected_at) VALUES ($1::jsonb, now()) "
        "ON CONFLICT DO NOTHING",
        1,
        argtypes,
        values,
        NULL,
        false,
        0);

    if (ret != SPI_OK_INSERT)
        elog(WARNING, "Failed to persist EFM status to history table: %d", ret);

    SPI_finish();
    PopActiveSnapshot();
    CommitTransactionCommand();

    /* Reset statement start time for next iteration */
    pgstat_report_activity(STATE_IDLE, NULL);
}

/*
 * Cleanup old history entries
 */
static void
efm_cleanup_history(void)
{
    int ret;

    SetCurrentStatementStartTimestamp();
    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    ret = SPI_execute(
        "DELETE FROM efm_extension.efm_status_history "
        "WHERE collected_at < now() - interval '7 days'",
        false, 0);

    if (ret != SPI_OK_DELETE)
        elog(WARNING, "Failed to cleanup EFM history: %d", ret);
    else if (SPI_processed > 0)
        elog(LOG, "EFM background worker: cleaned up %lu old history entries",
             (unsigned long) SPI_processed);

    SPI_finish();
    PopActiveSnapshot();
    CommitTransactionCommand();

    pgstat_report_activity(STATE_IDLE, NULL);
}

/*
 * Check if the history table exists
 */
static bool
efm_history_table_exists(void)
{
    int ret;
    bool exists = false;

    SetCurrentStatementStartTimestamp();
    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    ret = SPI_execute(
        "SELECT 1 FROM pg_catalog.pg_class c "
        "JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'efm_extension' "
        "AND c.relname = 'efm_status_history'",
        true, 1);

    if (ret == SPI_OK_SELECT && SPI_processed > 0)
        exists = true;

    SPI_finish();
    PopActiveSnapshot();
    CommitTransactionCommand();

    return exists;
}

/*
 * Main entry point for the background worker
 */
void
efm_bgworker_main(Datum main_arg)
{
    int cleanup_counter = 0;
    bool history_exists = false;

    /* Establish signal handlers */
    pqsignal(SIGHUP, efm_bgw_sighup);
    pqsignal(SIGTERM, efm_bgw_sigterm);

    /* Unblock signals */
    BackgroundWorkerUnblockSignals();

    /* Connect to database */
    BackgroundWorkerInitializeConnection(
        efm_bgw_database ? efm_bgw_database : "postgres",
        NULL,
        0);

    elog(LOG, "EFM background worker started, polling every %d seconds",
         efm_bgw_interval);

    /* Check if history table exists */
    if (efm_bgw_persist_history)
        history_exists = efm_history_table_exists();

    /* Main loop */
    while (!got_sigterm)
    {
        int rc;

        /* Wait for interval or signal */
        rc = WaitLatch(MyLatch,
                       WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
                       efm_bgw_interval * 1000L,
                       PG_WAIT_EXTENSION);

        ResetLatch(MyLatch);

        /* Check for config reload */
        if (got_sighup)
        {
            got_sighup = false;
            ProcessConfigFile(PGC_SIGHUP);

            /* Re-check history table existence after reload */
            if (efm_bgw_persist_history)
                history_exists = efm_history_table_exists();
        }

        /* Check for shutdown request */
        if (got_sigterm)
            break;

        /* Skip if we only woke up due to latch set */
        if (!(rc & WL_TIMEOUT))
            continue;

        /* Poll EFM status */
        PG_TRY();
        {
            EfmExecResult *result;

            pgstat_report_activity(STATE_RUNNING, "polling EFM status");

            /* Note: efm_exec_command already appends efm_cluster_name internally */
            result = efm_exec_command("cluster-status-json", NULL, 0);

            if (result->exit_code == 0 && result->stdout_data)
            {
                /* Update shared memory cache */
                efm_update_cache(result->stdout_data, result->stdout_len);

                /* Optionally persist to history table */
                if (efm_bgw_persist_history && history_exists)
                    efm_persist_status(result->stdout_data);

                elog(DEBUG1, "EFM status updated successfully");
            }
            else
            {
                elog(WARNING, "EFM status poll failed (exit code %d): %s",
                     result->exit_code,
                     result->stderr_data ? result->stderr_data : "(no error output)");
            }

            efm_free_exec_result(result);

            /* Periodic cleanup (every ~1 hour) */
            cleanup_counter++;
            if (efm_bgw_persist_history && history_exists &&
                cleanup_counter >= (3600 / efm_bgw_interval))
            {
                cleanup_counter = 0;
                efm_cleanup_history();
            }
        }
        PG_CATCH();
        {
            /* Don't let errors kill the worker */
            EmitErrorReport();
            FlushErrorState();
        }
        PG_END_TRY();

        pgstat_report_activity(STATE_IDLE, NULL);
    }

    elog(LOG, "EFM background worker shutting down");
    proc_exit(0);
}

/*
 * Register the background worker during module initialization
 */
void
efm_register_bgworker(void)
{
    BackgroundWorker worker;

    if (!efm_bgw_enabled)
        return;

    if (!process_shared_preload_libraries_in_progress)
    {
        elog(WARNING, "efm_extension must be loaded via shared_preload_libraries "
             "to enable background worker");
        return;
    }

    memset(&worker, 0, sizeof(BackgroundWorker));

    snprintf(worker.bgw_name, BGW_MAXLEN, "efm_status_monitor");
    snprintf(worker.bgw_type, BGW_MAXLEN, "efm_status_monitor");

    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
                       BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_restart_time = 10;  /* Restart after 10 seconds if crash */

    snprintf(worker.bgw_library_name, BGW_MAXLEN, "efm_extension");
    snprintf(worker.bgw_function_name, BGW_MAXLEN, "efm_bgworker_main");

    worker.bgw_main_arg = (Datum) 0;
    worker.bgw_notify_pid = 0;

    RegisterBackgroundWorker(&worker);

    elog(LOG, "EFM background worker registered");
}
