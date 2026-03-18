/*-------------------------------------------------------------------------
 *
 * efm_extension.c
 *      PostgreSQL extension for EDB Failover Manager (EFM) integration
 *
 * This extension provides SQL functions to manage EFM clusters directly
 * from PostgreSQL, including cluster status, node management, failover,
 * and switchover operations.
 *
 * Security Features:
 * - Uses fork/execve instead of system() to prevent command injection
 * - Strict input validation for IP addresses and priorities
 * - Captures both stdout and stderr for proper error handling
 * - Maps EFM exit codes to PostgreSQL error levels
 *
 * Copyright (c) 2024, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "efm_cache.h"
#include "efm_bgworker.h"
#include "efm_exec.h"

#include "catalog/pg_type.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/inet.h"
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/pg_lsn.h"
#include "utils/timestamp.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <regex.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

/* Function declarations */
PG_FUNCTION_INFO_V1(efm_cluster_status);
PG_FUNCTION_INFO_V1(efm_cluster_status_json);
PG_FUNCTION_INFO_V1(efm_get_nodes);
PG_FUNCTION_INFO_V1(efm_allow_node);
PG_FUNCTION_INFO_V1(efm_disallow_node);
PG_FUNCTION_INFO_V1(efm_set_priority);
PG_FUNCTION_INFO_V1(efm_failover);
PG_FUNCTION_INFO_V1(efm_switchover);
PG_FUNCTION_INFO_V1(efm_resume_monitoring);
PG_FUNCTION_INFO_V1(efm_list_properties);
PG_FUNCTION_INFO_V1(efm_cache_stats);
PG_FUNCTION_INFO_V1(efm_invalidate_cache);
PG_FUNCTION_INFO_V1(efm_is_available);

/* GUC variables */
char *efm_path_command = NULL;
char *efm_sudo_path = NULL;
char *efm_sudo_user = NULL;
char *efm_cluster_name = NULL;
char *efm_properties_file_loc = NULL;

/* Internal function declarations */
void _PG_init(void);
void _PG_fini(void);

static void efm_check_config(void);
static void require_superuser(void);

/* Previous shared_preload_libraries hooks */
#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

/*
 * EFM error code mappings
 */
static const EfmErrorMapping efm_errors[] = {
    {0,   0,                                        "Success"},
    {1,   ERRCODE_EXTERNAL_ROUTINE_EXCEPTION,       "EFM general error"},
    {2,   ERRCODE_CONFIG_FILE_ERROR,                "EFM configuration error"},
    {3,   ERRCODE_CONNECTION_FAILURE,               "EFM agent connection failed"},
    {4,   ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE, "EFM cluster not in required state"},
    {5,   ERRCODE_INSUFFICIENT_PRIVILEGE,           "EFM permission denied"},
    {10,  ERRCODE_CONNECTION_FAILURE,               "EFM database connection failed"},
    {20,  ERRCODE_LOCK_NOT_AVAILABLE,               "EFM operation already in progress"},
    {127, ERRCODE_UNDEFINED_FILE,                   "EFM binary not found or sudo failed"},
    {-1,  ERRCODE_SYSTEM_ERROR,                     "EFM process terminated by signal"},
    {-2,  ERRCODE_SYSTEM_ERROR,                     "EFM process exited with unknown status"},
    {-3,  ERRCODE_QUERY_CANCELED,                   "EFM command timed out"},
    {-4,  ERRCODE_SYSTEM_ERROR,                     "Failed to wait for EFM process"},
};

/*
 * Validate IP address format (IPv4 or IPv6)
 */
bool
validate_ip_address(const char *ip)
{
    int a, b, c, d;
    char extra;

    if (ip == NULL || *ip == '\0')
        return false;

    /* Check for IPv6 (contains colons) */
    if (strchr(ip, ':') != NULL)
    {
        /* Basic IPv6 validation - must contain only hex digits, colons, and dots (for mapped IPv4) */
        for (const char *p = ip; *p; p++)
        {
            if (!isxdigit((unsigned char)*p) && *p != ':' && *p != '.')
                return false;
        }
        /* Must have at least one colon and reasonable length */
        if (strlen(ip) < 2 || strlen(ip) > 45)
            return false;
        return true;
    }

    /* IPv4 validation */
    if (sscanf(ip, "%d.%d.%d.%d%c", &a, &b, &c, &d, &extra) != 4)
        return false;

    /* Check octet ranges */
    if (a < 0 || a > 255 || b < 0 || b > 255 ||
        c < 0 || c > 255 || d < 0 || d > 255)
        return false;

    /* Check for leading zeros or other invalid formats */
    {
        char buf[16];
        snprintf(buf, sizeof(buf), "%d.%d.%d.%d", a, b, c, d);
        if (strcmp(buf, ip) != 0)
            return false;
    }

    return true;
}

/*
 * Validate priority (must be numeric, 0-999)
 */
bool
validate_priority(const char *priority)
{
    int val;
    char extra;

    if (priority == NULL || *priority == '\0')
        return false;

    /* Must be all digits */
    for (const char *p = priority; *p; p++)
    {
        if (!isdigit((unsigned char)*p))
            return false;
    }

    /* Check range */
    if (sscanf(priority, "%d%c", &val, &extra) != 1)
        return false;

    return (val >= 0 && val <= 999);
}

/*
 * Validate cluster name (alphanumeric and underscores only)
 */
bool
validate_cluster_name(const char *name)
{
    if (name == NULL || *name == '\0')
        return false;

    /* Must start with letter */
    if (!isalpha((unsigned char)*name))
        return false;

    /* Only alphanumeric, underscore, hyphen */
    for (const char *p = name; *p; p++)
    {
        if (!isalnum((unsigned char)*p) && *p != '_' && *p != '-')
            return false;
    }

    /* Reasonable length limit */
    if (strlen(name) > 64)
        return false;

    return true;
}

/*
 * Read from a non-blocking file descriptor with timeout
 * Returns data read, sets *len to length. Returns NULL on error.
 */
static char *
read_pipe_with_timeout(int fd, Size *len, int timeout_ms)
{
    StringInfoData buf;
    char chunk[4096];
    struct pollfd pfd;
    int remaining_ms = timeout_ms;
    time_t start_time = time(NULL);

    initStringInfo(&buf);

    /* Set non-blocking */
    fcntl(fd, F_SETFL, O_NONBLOCK);

    pfd.fd = fd;
    pfd.events = POLLIN;

    while (remaining_ms > 0)
    {
        int poll_result = poll(&pfd, 1, remaining_ms > 1000 ? 1000 : remaining_ms);

        if (poll_result < 0)
        {
            if (errno == EINTR)
            {
                /* Update remaining time and continue */
                remaining_ms = timeout_ms - (int)((time(NULL) - start_time) * 1000);
                continue;
            }
            break;  /* Real error */
        }
        else if (poll_result == 0)
        {
            /* Timeout on this poll, update remaining time */
            remaining_ms = timeout_ms - (int)((time(NULL) - start_time) * 1000);
            continue;
        }

        /* Data available or EOF/error */
        if (pfd.revents & (POLLIN | POLLHUP))
        {
            ssize_t nread = read(fd, chunk, sizeof(chunk));
            if (nread > 0)
            {
                appendBinaryStringInfo(&buf, chunk, nread);
            }
            else if (nread == 0)
            {
                /* EOF - pipe closed */
                break;
            }
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
            {
                /* Real error */
                break;
            }
        }

        if (pfd.revents & (POLLERR | POLLNVAL))
            break;

        /* Update remaining time */
        remaining_ms = timeout_ms - (int)((time(NULL) - start_time) * 1000);
    }

    if (len)
        *len = buf.len;

    return buf.data;
}

/* Default timeout for EFM commands in seconds */
#define EFM_COMMAND_TIMEOUT_SEC 30

/*
 * Execute EFM command securely using fork/execve
 * This avoids shell interpolation and command injection vulnerabilities
 *
 * Features:
 * - Timeout handling to prevent hung processes
 * - Proper signal handling in child
 * - Non-blocking pipe reads with select()
 */
EfmExecResult *
efm_exec_command(const char *efm_cmd, char **args, int nargs)
{
    int stdout_pipe[2];
    int stderr_pipe[2];
    pid_t pid;
    EfmExecResult *result;
    int status;
    int wait_result;
    time_t start_time;
    int timeout_remaining;

    result = palloc0(sizeof(EfmExecResult));

    /* Create pipes for stdout and stderr */
    if (pipe(stdout_pipe) < 0)
        ereport(ERROR,
                (errcode(ERRCODE_SYSTEM_ERROR),
                 errmsg("failed to create stdout pipe: %m")));

    if (pipe(stderr_pipe) < 0)
    {
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        ereport(ERROR,
                (errcode(ERRCODE_SYSTEM_ERROR),
                 errmsg("failed to create stderr pipe: %m")));
    }

    pid = fork();

    if (pid < 0)
    {
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[0]);
        close(stderr_pipe[1]);
        ereport(ERROR,
                (errcode(ERRCODE_SYSTEM_ERROR),
                 errmsg("fork failed: %m")));
    }

    if (pid == 0)
    {
        /* Child process */
        char **argv;
        int argc = 0;
        int i;
        sigset_t sigmask;

        /*
         * Reset signal handlers to default - PostgreSQL installs custom handlers
         * that can interfere with child process execution
         */
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGALRM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGUSR1, SIG_DFL);
        signal(SIGUSR2, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);

        /* Unblock all signals - PostgreSQL may have blocked some */
        sigemptyset(&sigmask);
        sigprocmask(SIG_SETMASK, &sigmask, NULL);

        /* Close all file descriptors except stdin, stdout, stderr and our pipes */
        {
            struct rlimit rl;
            int max_fd = 1024;  /* fallback if getrlimit fails */

            if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY)
                max_fd = (int) rl.rlim_cur;

            for (i = 3; i < max_fd; i++)
            {
                if (i != stdout_pipe[1] && i != stderr_pipe[1])
                    close(i);
            }
        }

        /* Close read ends of pipes */
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);

        /* Redirect stdout and stderr */
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        /* Build argument array for execve */
        /* Format: sudo -n -u efm /path/to/efm <cmd> <cluster> [args...] */
        argv = malloc((7 + nargs + 1) * sizeof(char *));
        if (!argv)
            _exit(127);

        argv[argc++] = efm_sudo_path ? efm_sudo_path : "/usr/bin/sudo";
        argv[argc++] = "-n";  /* Non-interactive - don't prompt for password */
        argv[argc++] = "-u";
        argv[argc++] = efm_sudo_user ? efm_sudo_user : "efm";
        argv[argc++] = efm_path_command;
        argv[argc++] = (char *)efm_cmd;
        argv[argc++] = efm_cluster_name;

        for (i = 0; i < nargs; i++)
            argv[argc++] = args[i];

        argv[argc] = NULL;

        /*
         * Execute command with minimal environment for sudo to work
         * We need PATH for sudo to find shells and HOME for some sudo configs
         */
        {
            char *envp[4];
            envp[0] = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
            envp[1] = "HOME=/tmp";
            envp[2] = "LANG=C";
            envp[3] = NULL;

            execve(efm_sudo_path ? efm_sudo_path : "/usr/bin/sudo", argv, envp);
        }

        /* If execve returns, it failed */
        _exit(127);
    }

    /* Parent process */
    start_time = time(NULL);

    /* Close write ends of pipes */
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    /*
     * Read output from child using poll-based non-blocking reads with timeout.
     * This ensures we don't block indefinitely if the child hangs.
     */
    {
        int timeout_ms = EFM_COMMAND_TIMEOUT_SEC * 1000;
        result->stdout_data = read_pipe_with_timeout(stdout_pipe[0], &result->stdout_len, timeout_ms);

        /* Recalculate remaining timeout for stderr */
        timeout_remaining = EFM_COMMAND_TIMEOUT_SEC - (int)(time(NULL) - start_time);
        if (timeout_remaining < 1)
            timeout_remaining = 1;
        result->stderr_data = read_pipe_with_timeout(stderr_pipe[0], &result->stderr_len, timeout_remaining * 1000);
    }

    close(stdout_pipe[0]);
    close(stderr_pipe[0]);

    /* Wait for child with remaining timeout */
    timeout_remaining = EFM_COMMAND_TIMEOUT_SEC - (int)(time(NULL) - start_time);
    if (timeout_remaining < 1)
        timeout_remaining = 1;

    /* Try non-blocking wait first */
    wait_result = waitpid(pid, &status, WNOHANG);

    if (wait_result == 0)
    {
        /* Child still running, wait with timeout */
        int elapsed = 0;
        while (elapsed < timeout_remaining)
        {
            usleep(100000);  /* 100ms */
            elapsed++;
            wait_result = waitpid(pid, &status, WNOHANG);
            if (wait_result != 0)
                break;
            if (elapsed % 10 == 0)  /* Check every second */
                elapsed = (int)(time(NULL) - start_time);
        }

        if (wait_result == 0)
        {
            /* Timeout - kill the child */
            elog(WARNING, "EFM command '%s' timed out after %d seconds, killing process",
                 efm_cmd, EFM_COMMAND_TIMEOUT_SEC);
            kill(pid, SIGTERM);
            usleep(500000);  /* Give it 500ms to terminate */
            wait_result = waitpid(pid, &status, WNOHANG);
            if (wait_result == 0)
            {
                kill(pid, SIGKILL);
                waitpid(pid, &status, 0);
            }
            result->exit_code = -3;  /* Timeout */
            if (result->stderr_data)
                pfree(result->stderr_data);
            result->stderr_data = pstrdup("Command timed out");
            result->stderr_len = strlen(result->stderr_data);
            return result;
        }
    }

    if (wait_result < 0)
    {
        result->exit_code = -4;  /* Wait failed */
        return result;
    }

    if (WIFEXITED(status))
        result->exit_code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status))
        result->exit_code = -1;  /* Killed by signal */
    else
        result->exit_code = -2;  /* Unknown status */

    return result;
}

/*
 * Free an execution result
 */
void
efm_free_exec_result(EfmExecResult *result)
{
    if (result)
    {
        if (result->stdout_data)
            pfree(result->stdout_data);
        if (result->stderr_data)
            pfree(result->stderr_data);
        pfree(result);
    }
}

/*
 * Check EFM result and raise appropriate error if needed.
 * This function takes ownership of the result and frees it before raising error.
 */
void
efm_check_result(EfmExecResult *result, const char *operation)
{
    int pg_errcode = ERRCODE_EXTERNAL_ROUTINE_EXCEPTION;
    const char *msg = "Unknown EFM error";
    int elevel;
    int i;
    int exit_code;
    char *stderr_copy = NULL;

    if (result->exit_code == 0)
        return;

    /* Save values we need for error message */
    exit_code = result->exit_code;
    if (result->stderr_data && result->stderr_len > 0)
        stderr_copy = pstrdup(result->stderr_data);

    /* Free the result before raising error to avoid memory leak */
    efm_free_exec_result(result);

    /* Find matching error */
    for (i = 0; i < sizeof(efm_errors) / sizeof(efm_errors[0]); i++)
    {
        if (efm_errors[i].exit_code == exit_code)
        {
            pg_errcode = efm_errors[i].pg_errcode;
            msg = efm_errors[i].message;
            break;
        }
    }

    /* Determine severity based on operation */
    elevel = ERROR;

    ereport(elevel,
            (errcode(pg_errcode),
             errmsg("%s failed: %s (exit code %d)", operation, msg, exit_code),
             errdetail("stderr: %s", stderr_copy ? stderr_copy : "(empty)"),
             errhint("Check EFM logs at /var/log/efm-*/efm.log for details")));

    /* Note: stderr_copy will be freed by PostgreSQL memory context cleanup after error */
}

/*
 * Check if EFM configuration is valid
 */
static void
efm_check_config(void)
{
    if (efm_cluster_name == NULL || *efm_cluster_name == '\0')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("efm.cluster_name is not set"),
                 errhint("Set efm.cluster_name in postgresql.conf or via ALTER SYSTEM")));

    if (efm_path_command == NULL || *efm_path_command == '\0')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("efm.command_path is not set"),
                 errhint("Set efm.command_path to the full path of the efm binary")));

    /* Check if EFM binary exists and is executable */
    if (access(efm_path_command, X_OK) != 0)
        ereport(ERROR,
                (errcode(ERRCODE_UNDEFINED_FILE),
                 errmsg("EFM binary not found or not executable: %s", efm_path_command),
                 errdetail("%m")));

    /* Validate cluster name format */
    if (!validate_cluster_name(efm_cluster_name))
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("invalid efm.cluster_name: %s", efm_cluster_name),
                 errhint("Cluster name must be alphanumeric with underscores/hyphens only")));
}

/*
 * Require superuser privileges
 * Note: We check the session user, not the current user, because these
 * functions may be SECURITY DEFINER. This ensures the actual invoker
 * must be a superuser, not just the function owner.
 */
static void
require_superuser(void)
{
    if (!superuser_arg(GetSessionUserId()))
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("permission denied"),
                 errhint("Only superusers can execute EFM management functions")));
}

/*
 * Parse EFM nodes from JSON response
 */
EfmNodeArray *
parse_efm_nodes(const char *json_data)
{
    EfmNodeArray *nodes;
    Jsonb *jb;
    JsonbIterator *it;
    JsonbValue v;
    JsonbIteratorToken type;
    bool in_nodes = false;
    char current_ip[64] = "";

    nodes = palloc0(sizeof(EfmNodeArray));
    nodes->capacity = 16;
    nodes->items = palloc0(sizeof(EfmNode) * nodes->capacity);
    nodes->count = 0;

    /* Parse JSON */
    jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in,
                                            CStringGetDatum(json_data)));

    it = JsonbIteratorInit(&jb->root);

    while ((type = JsonbIteratorNext(&it, &v, false)) != WJB_DONE)
    {
        if (type == WJB_KEY)
        {
            char *key = pnstrdup(v.val.string.val, v.val.string.len);

            if (strcmp(key, "nodes") == 0)
                in_nodes = true;
            else if (in_nodes && validate_ip_address(key))
            {
                /* This is a node IP */
                strncpy(current_ip, key, sizeof(current_ip) - 1);

                /* Expand array if needed */
                if (nodes->count >= nodes->capacity)
                {
                    nodes->capacity *= 2;
                    nodes->items = repalloc(nodes->items,
                                           sizeof(EfmNode) * nodes->capacity);
                }

                /* Initialize the new node */
                memset(&nodes->items[nodes->count], 0, sizeof(EfmNode));
                nodes->items[nodes->count].priority = -1;  /* -1 = not set */
                nodes->items[nodes->count].promotable_set = false;

                strncpy(nodes->items[nodes->count].ip, current_ip,
                       sizeof(nodes->items[nodes->count].ip) - 1);
                nodes->count++;
            }
            else if (in_nodes && current_ip[0] != '\0')
            {
                /* Node property */
                EfmNode *node = &nodes->items[nodes->count - 1];

                /* Get the value */
                type = JsonbIteratorNext(&it, &v, false);
                if (type == WJB_VALUE)
                {
                    char *val = NULL;
                    bool val_allocated = false;

                    if (v.type == jbvString)
                    {
                        val = pnstrdup(v.val.string.val, v.val.string.len);
                        val_allocated = true;
                    }
                    else if (v.type == jbvNumeric)
                    {
                        val = DatumGetCString(DirectFunctionCall1(numeric_out,
                                              NumericGetDatum(v.val.numeric)));
                        val_allocated = true;
                    }
                    else if (v.type == jbvBool)
                        val = v.val.boolean ? "true" : "false";

                    if (val)
                    {
                        if (strcmp(key, "type") == 0)
                            strncpy(node->type, val, sizeof(node->type) - 1);
                        else if (strcmp(key, "agent") == 0)
                            strncpy(node->agent_status, val, sizeof(node->agent_status) - 1);
                        else if (strcmp(key, "db") == 0)
                            strncpy(node->db_status, val, sizeof(node->db_status) - 1);
                        else if (strcmp(key, "xlog") == 0)
                            strncpy(node->xlog, val, sizeof(node->xlog) - 1);
                        else if (strcmp(key, "xloginfo") == 0)
                            strncpy(node->xlog_info, val, sizeof(node->xlog_info) - 1);
                        else if (strcmp(key, "priority") == 0)
                        {
                            node->priority = atoi(val);
                        }
                        else if (strcmp(key, "promotable") == 0)
                        {
                            node->is_promotable = (strcmp(val, "true") == 0);
                            node->promotable_set = true;
                        }

                        /* Free allocated memory to prevent leaks */
                        if (val_allocated)
                            pfree(val);
                    }
                }
            }

            pfree(key);
        }
        else if (type == WJB_END_OBJECT && in_nodes && current_ip[0] != '\0')
        {
            current_ip[0] = '\0';
        }
    }

    return nodes;
}

/*
 * Free node array
 */
void
free_efm_node_array(EfmNodeArray *nodes)
{
    if (nodes)
    {
        if (nodes->items)
            pfree(nodes->items);
        pfree(nodes);
    }
}

/* ============================================================================
 * SQL-Callable Functions
 * ============================================================================
 */

/*
 * efm_cluster_status - Get cluster status as text lines
 */
Datum
efm_cluster_status(PG_FUNCTION_ARGS)
{
    FuncCallContext *funcctx;
    MemoryContext oldcontext;

    text *output_type = PG_GETARG_TEXT_PP(0);
    char *type_str = text_to_cstring(output_type);

    require_superuser();
    efm_check_config();

    if (SRF_IS_FIRSTCALL())
    {
        EfmExecResult *result;
        char *cmd;
        StringInfoData buf;
        char *line;
        char *saveptr;
        List *lines = NIL;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        /* Determine command based on output type */
        if (strcmp(type_str, "text") == 0)
            cmd = "cluster-status";
        else if (strcmp(type_str, "json") == 0)
            cmd = "cluster-status-json";
        else
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("invalid output type: %s", type_str),
                     errhint("Use 'text' or 'json'")));

        /* Check cache first for JSON */
        if (strcmp(type_str, "json") == 0 && efm_cache_valid())
        {
            char *cached = efm_get_cached_status();
            if (cached)
            {
                initStringInfo(&buf);
                appendStringInfoString(&buf, cached);
                pfree(cached);
                goto parse_output;
            }
        }

        /* Execute EFM command */
        result = efm_exec_command(cmd, NULL, 0);
        efm_check_result(result, cmd);

        initStringInfo(&buf);
        appendStringInfoString(&buf, result->stdout_data);

        /* Update cache for JSON output */
        if (strcmp(type_str, "json") == 0)
            efm_update_cache(result->stdout_data, result->stdout_len);

        efm_free_exec_result(result);

parse_output:
        /* Split output into lines */
        line = strtok_r(buf.data, "\n", &saveptr);
        while (line != NULL)
        {
            lines = lappend(lines, pstrdup(line));
            line = strtok_r(NULL, "\n", &saveptr);
        }

        funcctx->user_fctx = lines;
        funcctx->max_calls = list_length(lines);

        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();

    if (funcctx->call_cntr < funcctx->max_calls)
    {
        List *lines = (List *)funcctx->user_fctx;
        char *line = (char *)list_nth(lines, funcctx->call_cntr);

        SRF_RETURN_NEXT(funcctx, CStringGetTextDatum(line));
    }

    SRF_RETURN_DONE(funcctx);
}

/*
 * efm_cluster_status_json - Get cluster status as JSONB
 */
Datum
efm_cluster_status_json(PG_FUNCTION_ARGS)
{
    EfmExecResult *result;
    Jsonb *jb;
    char *json_str;

    require_superuser();
    efm_check_config();

    /* Check cache first */
    if (efm_cache_valid())
    {
        json_str = efm_get_cached_status();
        if (json_str)
        {
            jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in,
                                                    CStringGetDatum(json_str)));
            pfree(json_str);
            PG_RETURN_JSONB_P(jb);
        }
    }

    /* Execute EFM command */
    result = efm_exec_command("cluster-status-json", NULL, 0);
    efm_check_result(result, "cluster-status-json");

    /* Update cache */
    efm_update_cache(result->stdout_data, result->stdout_len);

    /* Convert to JSONB */
    jb = DatumGetJsonbP(DirectFunctionCall1(jsonb_in,
                                            CStringGetDatum(result->stdout_data)));

    efm_free_exec_result(result);

    PG_RETURN_JSONB_P(jb);
}

/*
 * efm_get_nodes - Get structured node information
 */
Datum
efm_get_nodes(PG_FUNCTION_ARGS)
{
    FuncCallContext *funcctx;
    MemoryContext oldcontext;

    require_superuser();
    efm_check_config();

    if (SRF_IS_FIRSTCALL())
    {
        TupleDesc tupdesc;
        EfmExecResult *result;
        EfmNodeArray *nodes;
        char *json_str = NULL;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        /* Build tuple descriptor */
        tupdesc = CreateTemplateTupleDesc(9);
        TupleDescInitEntry(tupdesc, 1, "node_ip", INETOID, -1, 0);
        TupleDescInitEntry(tupdesc, 2, "node_type", TEXTOID, -1, 0);
        TupleDescInitEntry(tupdesc, 3, "agent_status", TEXTOID, -1, 0);
        TupleDescInitEntry(tupdesc, 4, "db_status", TEXTOID, -1, 0);
        TupleDescInitEntry(tupdesc, 5, "xlog_location", TEXTOID, -1, 0);
        TupleDescInitEntry(tupdesc, 6, "xlog_info", TEXTOID, -1, 0);
        TupleDescInitEntry(tupdesc, 7, "priority", INT4OID, -1, 0);
        TupleDescInitEntry(tupdesc, 8, "is_promotable", BOOLOID, -1, 0);
        TupleDescInitEntry(tupdesc, 9, "last_updated", TIMESTAMPTZOID, -1, 0);

        funcctx->tuple_desc = BlessTupleDesc(tupdesc);

        /* Check cache first */
        if (efm_cache_valid())
            json_str = efm_get_cached_status();

        if (!json_str)
        {
            /* Execute EFM command */
            result = efm_exec_command("cluster-status-json", NULL, 0);
            efm_check_result(result, "cluster-status-json");

            json_str = pstrdup(result->stdout_data);
            efm_update_cache(result->stdout_data, result->stdout_len);
            efm_free_exec_result(result);
        }

        /* Parse nodes from JSON */
        nodes = parse_efm_nodes(json_str);
        pfree(json_str);

        funcctx->user_fctx = nodes;
        funcctx->max_calls = nodes->count;

        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();

    if (funcctx->call_cntr < funcctx->max_calls)
    {
        EfmNodeArray *nodes = (EfmNodeArray *)funcctx->user_fctx;
        EfmNode *node = &nodes->items[funcctx->call_cntr];
        Datum values[9];
        bool nulls[9] = {false};
        HeapTuple tuple;

        /* node_ip */
        values[0] = DirectFunctionCall1(inet_in, CStringGetDatum(node->ip));

        /* node_type */
        values[1] = CStringGetTextDatum(node->type[0] ? node->type : "Unknown");

        /* agent_status */
        values[2] = CStringGetTextDatum(node->agent_status[0] ? node->agent_status : "Unknown");

        /* db_status */
        values[3] = CStringGetTextDatum(node->db_status[0] ? node->db_status : "Unknown");

        /* xlog_location */
        if (node->xlog[0])
            values[4] = CStringGetTextDatum(node->xlog);
        else
            nulls[4] = true;

        /* xlog_info */
        if (node->xlog_info[0])
            values[5] = CStringGetTextDatum(node->xlog_info);
        else
            nulls[5] = true;

        /* priority (-1 means not available) */
        if (node->priority >= 0)
            values[6] = Int32GetDatum(node->priority);
        else
            nulls[6] = true;

        /* is_promotable (only set if parsed from JSON) */
        if (node->promotable_set)
            values[7] = BoolGetDatum(node->is_promotable);
        else
            nulls[7] = true;

        /* last_updated */
        values[8] = TimestampTzGetDatum(GetCurrentTimestamp());

        tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);

        SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(tuple));
    }

    /* Free resources */
    free_efm_node_array((EfmNodeArray *)funcctx->user_fctx);

    SRF_RETURN_DONE(funcctx);
}

/*
 * efm_allow_node - Allow a node to join the cluster
 */
Datum
efm_allow_node(PG_FUNCTION_ARGS)
{
    text *ip_text = PG_GETARG_TEXT_PP(0);
    char *ip = text_to_cstring(ip_text);
    EfmExecResult *result;
    char *args[1];

    require_superuser();
    efm_check_config();

    /* Validate IP address */
    if (!validate_ip_address(ip))
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("invalid IP address: %s", ip)));

    ereport(LOG,
            (errmsg("EFM allow-node executed by %s for IP %s",
                    GetUserNameFromId(GetSessionUserId(), false), ip)));

    args[0] = ip;
    result = efm_exec_command("allow-node", args, 1);

    if (result->exit_code != 0)
    {
        /* efm_check_result takes ownership and frees result before raising ERROR */
        efm_check_result(result, "allow-node");
        /* Not reached - efm_check_result raises ERROR */
    }

    efm_free_exec_result(result);
    efm_cache_invalidate();

    PG_RETURN_INT32(0);
}

/*
 * efm_disallow_node - Remove a node from the cluster
 */
Datum
efm_disallow_node(PG_FUNCTION_ARGS)
{
    text *ip_text = PG_GETARG_TEXT_PP(0);
    char *ip = text_to_cstring(ip_text);
    EfmExecResult *result;
    char *args[1];

    require_superuser();
    efm_check_config();

    /* Validate IP address */
    if (!validate_ip_address(ip))
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("invalid IP address: %s", ip)));

    ereport(LOG,
            (errmsg("EFM disallow-node executed by %s for IP %s",
                    GetUserNameFromId(GetSessionUserId(), false), ip)));

    args[0] = ip;
    result = efm_exec_command("disallow-node", args, 1);

    if (result->exit_code != 0)
    {
        /* efm_check_result takes ownership and frees result before raising ERROR */
        efm_check_result(result, "disallow-node");
        /* Not reached - efm_check_result raises ERROR */
    }

    efm_free_exec_result(result);
    efm_cache_invalidate();

    PG_RETURN_INT32(0);
}

/*
 * efm_set_priority - Set failover priority for a node
 */
Datum
efm_set_priority(PG_FUNCTION_ARGS)
{
    text *ip_text = PG_GETARG_TEXT_PP(0);
    text *priority_text = PG_GETARG_TEXT_PP(1);
    char *ip = text_to_cstring(ip_text);
    char *priority = text_to_cstring(priority_text);
    EfmExecResult *result;
    char *args[2];

    require_superuser();
    efm_check_config();

    /* Validate inputs */
    if (!validate_ip_address(ip))
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("invalid IP address: %s", ip)));

    if (!validate_priority(priority))
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("invalid priority: %s", priority),
                 errhint("Priority must be a number between 0 and 999")));

    ereport(LOG,
            (errmsg("EFM set-priority executed by %s: IP=%s, priority=%s",
                    GetUserNameFromId(GetSessionUserId(), false), ip, priority)));

    args[0] = ip;
    args[1] = priority;
    result = efm_exec_command("set-priority", args, 2);

    if (result->exit_code != 0)
    {
        /* efm_check_result takes ownership and frees result before raising ERROR */
        efm_check_result(result, "set-priority");
        /* Not reached - efm_check_result raises ERROR */
    }

    efm_free_exec_result(result);
    efm_cache_invalidate();

    PG_RETURN_INT32(0);
}

/*
 * efm_failover - Trigger a failover (promote standby)
 */
Datum
efm_failover(PG_FUNCTION_ARGS)
{
    EfmExecResult *result;

    require_superuser();
    efm_check_config();

    ereport(LOG,
            (errmsg("EFM failover (promote) initiated by %s",
                    GetUserNameFromId(GetSessionUserId(), false))));

    result = efm_exec_command("promote", NULL, 0);

    if (result->exit_code != 0)
    {
        /* efm_check_result takes ownership and frees result before raising ERROR */
        efm_check_result(result, "promote");
        /* Not reached - efm_check_result raises ERROR */
    }

    ereport(LOG,
            (errmsg("EFM failover completed successfully")));

    efm_free_exec_result(result);
    efm_cache_invalidate();

    PG_RETURN_INT32(0);
}

/*
 * efm_switchover - Trigger a switchover (graceful role swap)
 */
Datum
efm_switchover(PG_FUNCTION_ARGS)
{
    EfmExecResult *result;
    char *args[1] = {"-switchover"};

    require_superuser();
    efm_check_config();

    ereport(LOG,
            (errmsg("EFM switchover initiated by %s",
                    GetUserNameFromId(GetSessionUserId(), false))));

    result = efm_exec_command("promote", args, 1);

    if (result->exit_code != 0)
    {
        /* efm_check_result takes ownership and frees result before raising ERROR */
        efm_check_result(result, "switchover");
        /* Not reached - efm_check_result raises ERROR */
    }

    ereport(LOG,
            (errmsg("EFM switchover completed successfully")));

    efm_free_exec_result(result);
    efm_cache_invalidate();

    PG_RETURN_INT32(0);
}

/*
 * efm_resume_monitoring - Resume EFM monitoring after pause
 */
Datum
efm_resume_monitoring(PG_FUNCTION_ARGS)
{
    EfmExecResult *result;

    require_superuser();
    efm_check_config();

    ereport(LOG,
            (errmsg("EFM resume monitoring executed by %s",
                    GetUserNameFromId(GetSessionUserId(), false))));

    result = efm_exec_command("resume", NULL, 0);

    if (result->exit_code != 0)
    {
        /* efm_check_result takes ownership and frees result before raising ERROR */
        efm_check_result(result, "resume");
        /* Not reached - efm_check_result raises ERROR */
    }

    efm_free_exec_result(result);
    efm_cache_invalidate();

    PG_RETURN_INT32(0);
}

/*
 * efm_list_properties - List EFM properties from config file
 */
Datum
efm_list_properties(PG_FUNCTION_ARGS)
{
    FuncCallContext *funcctx;
    MemoryContext oldcontext;

    require_superuser();
    efm_check_config();

    if (SRF_IS_FIRSTCALL())
    {
        char *properties_path;
        FILE *fp;
        char line[1024];
        List *lines = NIL;

        funcctx = SRF_FIRSTCALL_INIT();
        oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        /* Build properties file path */
        if (efm_properties_file_loc == NULL || *efm_properties_file_loc == '\0')
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("efm.properties_location is not set")));

        properties_path = psprintf("%s/%s.properties",
                                   efm_properties_file_loc, efm_cluster_name);

        /* Open and read file directly (safer than piping through shell) */
        fp = fopen(properties_path, "r");
        if (fp == NULL)
            ereport(ERROR,
                    (errcode(ERRCODE_UNDEFINED_FILE),
                     errmsg("cannot open properties file: %s", properties_path),
                     errdetail("%m")));

        while (fgets(line, sizeof(line), fp) != NULL)
        {
            size_t len = strlen(line);

            /* Skip comments and empty lines */
            if (line[0] == '#' || line[0] == '\n' || line[0] == '\r')
                continue;

            /* Trim trailing newline */
            while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
                line[--len] = '\0';

            /* Skip if empty after trimming */
            if (len == 0)
                continue;

            lines = lappend(lines, pstrdup(line));
        }

        fclose(fp);
        pfree(properties_path);

        funcctx->user_fctx = lines;
        funcctx->max_calls = list_length(lines);

        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();

    if (funcctx->call_cntr < funcctx->max_calls)
    {
        List *lines = (List *)funcctx->user_fctx;
        char *line = (char *)list_nth(lines, funcctx->call_cntr);

        SRF_RETURN_NEXT(funcctx, CStringGetTextDatum(line));
    }

    SRF_RETURN_DONE(funcctx);
}

/*
 * efm_cache_stats - Return cache statistics
 */
Datum
efm_cache_stats(PG_FUNCTION_ARGS)
{
    TupleDesc tupdesc;
    Datum values[5];
    bool nulls[5] = {false};
    HeapTuple tuple;
    EfmCacheStats stats;

    require_superuser();

    /* Build tuple descriptor */
    tupdesc = CreateTemplateTupleDesc(5);
    TupleDescInitEntry(tupdesc, 1, "cache_hits", INT8OID, -1, 0);
    TupleDescInitEntry(tupdesc, 2, "cache_misses", INT8OID, -1, 0);
    TupleDescInitEntry(tupdesc, 3, "cache_updates", INT8OID, -1, 0);
    TupleDescInitEntry(tupdesc, 4, "last_update", TIMESTAMPTZOID, -1, 0);
    TupleDescInitEntry(tupdesc, 5, "cache_ttl_seconds", INT4OID, -1, 0);
    tupdesc = BlessTupleDesc(tupdesc);

    stats = efm_get_cache_stats();

    values[0] = Int64GetDatum(stats.hits);
    values[1] = Int64GetDatum(stats.misses);
    values[2] = Int64GetDatum(stats.updates);

    if (stats.last_update != 0)
        values[3] = TimestampTzGetDatum(stats.last_update);
    else
        nulls[3] = true;

    values[4] = Int32GetDatum(efm_cache_ttl);

    tuple = heap_form_tuple(tupdesc, values, nulls);

    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * efm_invalidate_cache_func - Manually invalidate the cache (SQL callable)
 */
Datum
efm_invalidate_cache(PG_FUNCTION_ARGS)
{
    require_superuser();

    /* Call the cache module function (not this SQL wrapper) */
    efm_cache_invalidate();

    PG_RETURN_VOID();
}

/*
 * efm_is_available - Check if EFM is available and responding
 *
 * This function checks:
 * 1. EFM binary exists and is executable
 * 2. EFM agent is running and responding
 *
 * Returns a record with availability status and error message if unavailable.
 * This function does NOT raise an error if EFM is down - it returns status.
 *
 * IMPORTANT: This function is safe to call even if EFM is not running.
 * It will not break PostgreSQL - it simply returns false with an error message.
 */
Datum
efm_is_available(PG_FUNCTION_ARGS)
{
    TupleDesc tupdesc;
    Datum values[3];
    bool nulls[3] = {false, false, false};
    HeapTuple tuple;
    bool is_available = false;
    char *error_message = NULL;
    int error_code = 0;

    require_superuser();

    /* Build tuple descriptor */
    tupdesc = CreateTemplateTupleDesc(3);
    TupleDescInitEntry(tupdesc, 1, "is_available", BOOLOID, -1, 0);
    TupleDescInitEntry(tupdesc, 2, "error_code", INT4OID, -1, 0);
    TupleDescInitEntry(tupdesc, 3, "error_message", TEXTOID, -1, 0);
    tupdesc = BlessTupleDesc(tupdesc);

    /* Check 1: Configuration set */
    if (efm_cluster_name == NULL || *efm_cluster_name == '\0')
    {
        error_code = 1;
        error_message = "efm.cluster_name is not configured";
        goto done;
    }

    if (efm_path_command == NULL || *efm_path_command == '\0')
    {
        error_code = 2;
        error_message = "efm.command_path is not configured";
        goto done;
    }

    /* Check 2: EFM binary exists */
    if (access(efm_path_command, X_OK) != 0)
    {
        error_code = 3;
        error_message = psprintf("EFM binary not found or not executable: %s", efm_path_command);
        goto done;
    }

    /* Check 3: Try to get cluster status (quick check) */
    {
        EfmExecResult *result;

        result = efm_exec_command("cluster-status-json", NULL, 0);

        if (result->exit_code == 0)
        {
            is_available = true;
            error_message = "EFM is available and responding";
            error_code = 0;
        }
        else if (result->exit_code == -3)
        {
            error_code = 4;
            error_message = "EFM command timed out - agent may be unresponsive";
        }
        else if (result->exit_code == 127)
        {
            error_code = 5;
            error_message = "sudo or EFM binary execution failed - check permissions";
        }
        else
        {
            error_code = result->exit_code;
            if (result->stderr_data && result->stderr_len > 0)
                error_message = pstrdup(result->stderr_data);
            else
                error_message = psprintf("EFM returned error code %d", result->exit_code);
        }

        efm_free_exec_result(result);
    }

done:
    values[0] = BoolGetDatum(is_available);
    values[1] = Int32GetDatum(error_code);
    values[2] = CStringGetTextDatum(error_message ? error_message : "Unknown error");

    tuple = heap_form_tuple(tupdesc, values, nulls);

    PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* ============================================================================
 * Module Initialization
 * ============================================================================
 */

/*
 * Shared memory request hook (PG15+)
 */
#if PG_VERSION_NUM >= 150000
static void
efm_shmem_request_hook(void)
{
    if (prev_shmem_request_hook)
        (*prev_shmem_request_hook)();

    efm_shmem_request();
}
#endif

/*
 * Shared memory startup hook
 */
static void
efm_shmem_startup_hook(void)
{
    if (prev_shmem_startup_hook)
        (*prev_shmem_startup_hook)();

    efm_shmem_startup();
}

/*
 * GUC check function for efm.command_path
 */
static bool
check_efm_command_path(char **newval, void **extra, GucSource source)
{
    /* Allow empty during initial load */
    if (*newval == NULL || **newval == '\0')
        return true;

    /* Path must be absolute */
    if (**newval != '/')
    {
        GUC_check_errdetail("efm.command_path must be an absolute path");
        return false;
    }

    return true;
}

/*
 * GUC check function for efm.cluster_name
 */
static bool
check_efm_cluster_name(char **newval, void **extra, GucSource source)
{
    /* Allow empty during initial load */
    if (*newval == NULL || **newval == '\0')
        return true;

    if (!validate_cluster_name(*newval))
    {
        GUC_check_errdetail("efm.cluster_name must be alphanumeric with underscores/hyphens");
        return false;
    }

    return true;
}

/*
 * Module load callback
 */
void
_PG_init(void)
{
    /* Can only be loaded via shared_preload_libraries for BGW support */
    if (!process_shared_preload_libraries_in_progress)
    {
        elog(WARNING, "efm_extension should be loaded via shared_preload_libraries "
             "to enable caching and background worker features");
    }

    /* Define GUC variables */
    DefineCustomStringVariable("efm.cluster_name",
                               "Name of the EFM cluster to manage",
                               "Must match the cluster name in EFM configuration",
                               &efm_cluster_name,
                               "",
                               PGC_SUSET,
                               0,
                               check_efm_cluster_name, NULL, NULL);

    DefineCustomStringVariable("efm.command_path",
                               "Full path to the EFM binary",
                               "Example: /usr/edb/efm-4.9/bin/efm",
                               &efm_path_command,
                               "/usr/edb/efm-4.9/bin/efm",
                               PGC_SUSET,
                               0,
                               check_efm_command_path, NULL, NULL);

    DefineCustomStringVariable("efm.sudo_path",
                               "Full path to sudo binary",
                               "Default: /usr/bin/sudo",
                               &efm_sudo_path,
                               "/usr/bin/sudo",
                               PGC_SUSET,
                               0,
                               NULL, NULL, NULL);

    DefineCustomStringVariable("efm.sudo_user",
                               "User to run EFM commands as",
                               "Default: efm",
                               &efm_sudo_user,
                               "efm",
                               PGC_SUSET,
                               0,
                               NULL, NULL, NULL);

    DefineCustomStringVariable("efm.properties_location",
                               "Directory containing EFM properties files",
                               "Example: /etc/edb/efm-4.9",
                               &efm_properties_file_loc,
                               "/etc/edb/efm-4.9",
                               PGC_SUSET,
                               0,
                               NULL, NULL, NULL);

    DefineCustomIntVariable("efm.cache_ttl",
                            "Cache TTL in seconds",
                            "How long to cache EFM status (0 = disabled)",
                            &efm_cache_ttl,
                            5,      /* default */
                            0,      /* min */
                            300,    /* max */
                            PGC_SUSET,
                            GUC_UNIT_S,
                            NULL, NULL, NULL);

    /* Background worker GUCs */
    DefineCustomBoolVariable("efm.bgw_enabled",
                             "Enable background worker for status polling",
                             "Requires shared_preload_libraries",
                             &efm_bgw_enabled,
                             false,
                             PGC_POSTMASTER,
                             0,
                             NULL, NULL, NULL);

    DefineCustomIntVariable("efm.bgw_interval",
                            "Background worker polling interval in seconds",
                            NULL,
                            &efm_bgw_interval,
                            10,     /* default */
                            1,      /* min */
                            3600,   /* max */
                            PGC_SIGHUP,
                            GUC_UNIT_S,
                            NULL, NULL, NULL);

    DefineCustomStringVariable("efm.bgw_database",
                               "Database for background worker to connect to",
                               NULL,
                               &efm_bgw_database,
                               "postgres",
                               PGC_POSTMASTER,
                               0,
                               NULL, NULL, NULL);

    DefineCustomBoolVariable("efm.bgw_persist_history",
                             "Persist status history to table",
                             "Requires efm_status_history table",
                             &efm_bgw_persist_history,
                             false,
                             PGC_SIGHUP,
                             0,
                             NULL, NULL, NULL);

#if PG_VERSION_NUM >= 150000
    MarkGUCPrefixReserved("efm");
#endif

    /* Set up shared memory hooks */
    if (process_shared_preload_libraries_in_progress)
    {
#if PG_VERSION_NUM >= 150000
        /* PG15+ has shmem_request_hook */
        prev_shmem_request_hook = shmem_request_hook;
        shmem_request_hook = efm_shmem_request_hook;
#else
        /* For PG14, request shared memory directly */
        RequestAddinShmemSpace(efm_shmem_size());
#endif

        prev_shmem_startup_hook = shmem_startup_hook;
        shmem_startup_hook = efm_shmem_startup_hook;

        /* Register background worker if enabled */
        efm_register_bgworker();
    }
}

/*
 * Module unload callback
 */
void
_PG_fini(void)
{
    /* Nothing to clean up */
}
