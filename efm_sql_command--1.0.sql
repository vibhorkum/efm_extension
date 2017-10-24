-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION efm_sql_command" to load this file. \quit

CREATE FUNCTION efm_cluster_status (TEXT)
    RETURNS SETOF TEXT
AS 'MODULE_PATHNAME',
'efm_cluster_status'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION efm_allow_node (TEXT)
    RETURNS INTEGER
AS
'MODULE_PATHNAME',
'efm_allow_node'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION efm_disallow_node (TEXT)
    RETURNS INTEGER
AS 'MODULE_PATHNAME',
'efm_disallow_node'
LANGUAGE C VOLATILE STRICT;


CREATE FUNCTION efm_failover ()
    RETURNS INTEGER
AS
'MODULE_PATHNAME',
'efm_failover'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION efm_switchover ()
    RETURNS INTEGER
AS
'MODULE_PATHNAME',
'efm_switchover'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION efm_resume_monitoring ()
    RETURNS INTEGER
AS
'MODULE_PATHNAME',
'efm_resume_monitoring'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION efm_set_priority (TEXT, TEXT)
    RETURNS INTEGER
AS 'MODULE_PATHNAME',
'efm_set_priority'
LANGUAGE C VOLATILE STRICT;

CREATE FUNCTION efm_list_properties () 
    RETURNS SETOF TEXT
AS
'MODULE_PATHNAME',
'efm_list_properties'
LANGUAGE C VOLATILE STRICT;

CREATE VIEW efm_local_properties
AS
SELECT
    split_part(foo,
        '=',
        1) AS name,
    split_part(foo,
        '=',
        2) AS VALUE
FROM
    efm_extension.efm_list_properties () foo;

CREATE VIEW efm_nodes_details
AS
SELECT
    jsonb_each(VALUE).KEY AS node_ip,
    jsonb_each(jsonb_each(VALUE).VALUE).KEY AS property,
    jsonb_each(jsonb_each(VALUE).VALUE).VALUE AS VALUE
FROM
    jsonb_each((
            SELECT
                efm_extension.efm_cluster_status ('json'))::jsonb)
    WHERE
        KEY = 'nodes';


CREATE OR REPLACE FUNCTION efm.pg_is_in_recovery() 
    RETURNS BOOLEAN
    LANGUAGE SQL
AS $FUNCTION$
SELECT
    CASE WHEN inet_client_addr() = inet_server_addr() THEN
        pg_catalog.pg_is_in_recovery()
    ELSE
        TRUE
END;
$FUNCTION$;

CREATE OR REPLACE FUNCTION efm.pg_last_xlog_replay_location() 
    RETURNS pg_lsn
    LANGUAGE SQL
AS $FUNCTION$
SELECT
    CASE WHEN pg_catalog.pg_is_in_recovery() = FALSE THEN
        pg_catalog.pg_current_xlog_location()
    ELSE
        pg_catalog.pg_last_xlog_replay_location()
END;
$FUNCTION$;

