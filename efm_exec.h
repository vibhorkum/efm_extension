/*-------------------------------------------------------------------------
 *
 * efm_exec.h
 *      Secure command execution for EFM extension
 *
 * Copyright (c) 2024, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#ifndef EFM_EXEC_H
#define EFM_EXEC_H

#include "postgres.h"

/* Result structure for command execution */
typedef struct EfmExecResult
{
    int         exit_code;
    char       *stdout_data;
    char       *stderr_data;
    Size        stdout_len;
    Size        stderr_len;
} EfmExecResult;

/* EFM error mapping structure */
typedef struct EfmErrorMapping
{
    int         exit_code;
    int         pg_errcode;
    const char *message;
} EfmErrorMapping;

/* Node information parsed from JSON */
typedef struct EfmNode
{
    char        ip[64];
    char        type[32];
    char        agent_status[16];
    char        db_status[32];
    char        xlog[32];
    char        xlog_info[256];
    int         priority;           /* -1 means not set/available */
    bool        is_promotable;
    bool        promotable_set;     /* true if is_promotable was parsed from JSON */
} EfmNode;

/* Array of nodes */
typedef struct EfmNodeArray
{
    int         count;
    int         capacity;
    EfmNode    *items;
    TimestampTz fetch_timestamp;    /* When the data was fetched (same for all nodes) */
} EfmNodeArray;

/* Function declarations */
extern EfmExecResult *efm_exec_command(const char *efm_cmd, char **args, int nargs);
extern void efm_free_exec_result(EfmExecResult *result);
extern void efm_check_result(EfmExecResult *result, const char *operation);

/* Input validation */
extern bool validate_ip_address(const char *ip);
extern bool validate_priority(const char *priority);
extern bool validate_cluster_name(const char *name);

/* JSON parsing */
extern EfmNodeArray *parse_efm_nodes(const char *json_data);
extern void free_efm_node_array(EfmNodeArray *nodes);

/* GUC variables */
extern char *efm_path_command;
extern char *efm_sudo_path;
extern char *efm_sudo_user;
extern char *efm_cluster_name;
extern char *efm_properties_file_loc;

#endif /* EFM_EXEC_H */
