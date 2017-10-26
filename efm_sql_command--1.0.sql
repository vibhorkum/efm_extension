-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION efm_sql_command" to load this file. \quit

REVOKE ALL ON SCHEMA efm_extension FROM PUBLIC;
CREATE FUNCTION efm_cluster_status (TEXT)
    RETURNS SETOF TEXT
    SECURITY DEFINER
AS 'MODULE_PATHNAME',
'efm_cluster_status'
LANGUAGE C VOLATILE STRICT;
REVOKE ALL ON FUNCTION efm_cluster_status (TEXT) FROM PUBLIC;

CREATE FUNCTION efm_allow_node (TEXT)
    RETURNS INTEGER
    SECURITY DEFINER
AS
'MODULE_PATHNAME',
'efm_allow_node'
LANGUAGE C VOLATILE STRICT;

REVOKE ALL ON FUNCTION efm_allow_node (TEXT) FROM PUBLIC;


CREATE FUNCTION efm_disallow_node (TEXT)
    RETURNS INTEGER
    SECURITY DEFINER
AS 'MODULE_PATHNAME',
'efm_disallow_node'
LANGUAGE C VOLATILE STRICT;
REVOKE ALL ON FUNCTION efm_disallow_node (TEXT) FROM PUBLIC;

CREATE FUNCTION efm_failover ()
    RETURNS INTEGER
    SECURITY DEFINER
AS
'MODULE_PATHNAME',
'efm_failover'
LANGUAGE C VOLATILE STRICT;
REVOKE ALL ON FUNCTION efm_failover ()  FROM PUBLIC;

CREATE FUNCTION efm_switchover ()
    RETURNS INTEGER
    SECURITY DEFINER
AS
'MODULE_PATHNAME',
'efm_switchover'
LANGUAGE C VOLATILE STRICT;

REVOKE ALL ON FUNCTION efm_switchover () FROM PUBLIC;

CREATE FUNCTION efm_resume_monitoring ()
    RETURNS INTEGER
    SECURITY DEFINER
AS
'MODULE_PATHNAME',
'efm_resume_monitoring'
LANGUAGE C VOLATILE STRICT;

REVOKE ALL ON FUNCTION efm_resume_monitoring () FROM PUBLIC;

CREATE FUNCTION efm_set_priority (TEXT, TEXT)
    RETURNS INTEGER
    SECURITY DEFINER
AS 'MODULE_PATHNAME',
'efm_set_priority'
LANGUAGE C VOLATILE STRICT;

REVOKE ALL ON FUNCTION efm_set_priority (TEXT, TEXT) FROM PUBLIC;

CREATE FUNCTION efm_list_properties () 
    RETURNS SETOF TEXT
    SECURITY DEFINER
AS
'MODULE_PATHNAME',
'efm_list_properties'
LANGUAGE C VOLATILE STRICT;

REVOKE ALL ON FUNCTION efm_list_properties() FROM PUBLIC;

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


/* adding efm pgpool monitoring capability functions */
CREATE TYPE efm_extension.pool_status AS (
    pool_pid INTEGER,
    start_time TEXT,
    pool_id INTEGER,
    backend_id INTEGER,
    DATABASE TEXT,
    username TEXT,
    create_time TEXT,
    majorversion INTEGER,
    minorversion INTEGER,
    pool_counter INTEGER,
    pool_backendpid INTEGER,
    pool_connected INTEGER
);

REVOKE ALL ON TYPE efm_extension.pool_status FROM PUBLIC;

CREATE TYPE efm_extension.pool_link_status AS (
    link_name TEXT,
    status    TEXT
);


REVOKE ALL ON TYPE efm_extension.pool_link_status FROM PUBLIC;

CREATE TABLE efm_extension.pgpool_nodes(
   hostname TEXT,
   port INTEGER,
   database TEXT,
   username TEXT,
   password bytea);

REVOKE ALL ON TABLE efm_extension.pgpool_nodes FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.encrypt_efm(TEXT, TEXT)
RETURNS bytea
LANGUAGE SQL
AS
$FUNCTION$
  SELECT encrypt($1::BYTEA,$2::BYTEA,'aes');
$FUNCTION$;

REVOKE ALL ON FUNCTION efm_extension.encrypt_efm(TEXT,TEXT) FROM PUBLIC;


CREATE OR REPLACE FUNCTION efm_extension.get_efm(BYTEA,TEXT)
RETURNS text
LANGUAGE SQL
AS
$FUNCTION$
  SELECT convert_from(decrypt($1,$2::BYTEA,'aes'),'SQL_ASCII');
$FUNCTION$;

REVOKE ALL ON FUNCTION efm_extension.get_efm(BYTEA,TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.pgpool_link_exists(TEXT)
RETURNS bool AS $$
   SELECT COALESCE($1 = ANY (dblink_get_connections()), false)
$$ LANGUAGE sql;

REVOKE ALL ON FUNCTION efm_extension.pgpool_link_exists(TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.get_pgpool_links() 
RETURNS SETOF efm_extension.pool_link_status
LANGUAGE SQL
AS
$FUNCTION$
 SELECT
            'pgpool_' || hostname AS conn_name,
            CASE WHEN efm_extension.pgpool_link_exists ('pgpool_' || hostname) THEN
                'OK'
            ELSE
                dblink_connect('pgpool_' || hostname,
                    format('hostaddr=%s port=%s dbname=%I user=%I password=%I',
                        hostname,
                        port,
                        DATABASE,
                        username,
                        efm_extension.get_efm (PASSWORD,
                            'efm')))
        END
    FROM
        efm_extension.pgpool_nodes;
$FUNCTION$;

REVOKE ALL ON FUNCTION efm_extension.get_pgpool_links() FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.pgpool_backendpid_details (TEXT, INTEGER)
    RETURNS SETOF efm_extension.pool_status
    LANGUAGE SQL
AS $FUNCTION$
SELECT
    *
FROM
    dblink($1,
        'SHOW pool_pools') foo (pool_pid INTEGER,
        start_time TEXT,
        pool_id INTEGER,
        backend_id INTEGER,
        DATABASE TEXT,
        username TEXT,
        create_time TEXT,
        majorversion INTEGER,
        minorversion INTEGER,
        pool_counter INTEGER,
        pool_backendpid INTEGER,
        pool_connected INTEGER)
WHERE
    pool_backendpid <> 0 AND pool_backendpid = $2;
$FUNCTION$;


REVOKE ALL ON FUNCTION efm_extension.pgpool_backendpid_details(TEXT, INTEGER) FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.add_pgpool_monitoring(TEXT, INTEGER, TEXT, TEXT, TEXT)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS
$FUNCTION$
DECLARE 
  cmd_string TEXT;
  server_name TEXT ;
BEGIN
    INSERT INTO efm_extension.pgpool_nodes 
      VALUES($1,$2,$3,$4,efm_extension.encrypt_efm($5,'efm'));
    RETURN TRUE;
  EXCEPTION 
        WHEN OTHERS THEN
        RETURN FALSE;
END;
$FUNCTION$;

REVOKE ALL ON FUNCTION efm_extension.add_pgpool_monitoring(TEXT, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.pg_is_in_recovery()
    RETURNS BOOLEAN
    LANGUAGE plpgsql
    SECURITY DEFINER
AS $FUNCTION$
DECLARE
    recovery_status BOOLEAN := false;
BEGIN
    WITH pid_info AS (
    SELECT
        link_name,
        (SELECT count(1) as num_of_conn FROM efm_extension.pgpool_backendpid_details (link_name,pg_backend_pid()) LIMIT 1)
    FROM
        efm_extension.get_pgpool_links()
)
SELECT
    CASE WHEN COUNT(1) > 0 THEN 
      TRUE
    ELSE 
       pg_catalog.pg_is_in_recovery() 
    END INTO recovery_status 
FROM
    pid_info where num_of_conn > 0;

    PERFORM
        dblink_disconnect (link_name)
    FROM
        efm_extension.get_pgpool_links();

    RETURN recovery_status;

 EXCEPTION
    WHEN OTHERS THEN
    PERFORM
        dblink_disconnect (link_name)
    FROM
        efm_extension.get_pgpool_links();

    RETURN recovery_status;

END;
$FUNCTION$;

REVOKE ALL ON FUNCTION efm_extension.pg_is_in_recovery() FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.pg_last_xlog_replay_location() 
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

REVOKE ALL ON FUNCTION efm_extension.pg_last_xlog_replay_location() FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.grant_access_to_user(TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS
$FUNCTION$
DECLARE 
  rec RECORD;
  sql_cmd TEXT;

BEGIN
   sql_cmd := $SQL$ SELECT
    CASE WHEN extn_objects ~* '^function' THEN
        'GRANT EXECUTE ON ' || extn_objects 
        WHEN extn_objects ~* '^view' THEN
        'GRANT SELECT ON ' || pg_catalog.regexp_replace(extn_objects,'^view ','')
    END as grant_cmd
FROM (
    SELECT
        pg_catalog.pg_describe_object(classid,
            objid,
            0) AS extn_objects
    FROM
        pg_catalog.pg_depend
    WHERE
        refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
        AND refobjid = (
            SELECT
                e.oid
            FROM
                pg_catalog.pg_extension e
            WHERE
                e.extname ~ '^(efm_sql_command)$'
            ORDER BY
                1)
            AND deptype = 'e'
        ORDER BY
            1) foo
    WHERE
        extn_objects ~* '^view'
        OR extn_objects ~* '^function' $SQL$;
  EXECUTE 'GRANT USAGE ON SCHEMA efm_extension TO '||$1;
  FOR rec IN EXECUTE sql_cmd
  LOOP
     RAISE NOTICE '% TO %',rec.grant_cmd,$1;
     EXECUTE rec.grant_cmd || ' TO '||$1;
  END LOOP;
  RETURN true;
  EXCEPTION
    WHEN OTHERS THEN
       RETURN false;
END;
$FUNCTION$;

REVOKE ALL ON FUNCTION efm_extension.grant_access_to_user(TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION efm_extension.revoke_access_from_user(TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS
$FUNCTION$
DECLARE 
  rec RECORD;
  sql_cmd TEXT;

BEGIN
   sql_cmd := $SQL$ SELECT
    CASE WHEN extn_objects ~* '^function' THEN
        'REVOKE EXECUTE ON ' || extn_objects 
        WHEN extn_objects ~* '^view' THEN
        'REVOKE SELECT ON ' || pg_catalog.regexp_replace(extn_objects,'^view ','')
    END as grant_cmd
FROM (
    SELECT
        pg_catalog.pg_describe_object(classid,
            objid,
            0) AS extn_objects
    FROM
        pg_catalog.pg_depend
    WHERE
        refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
        AND refobjid = (
            SELECT
                e.oid
            FROM
                pg_catalog.pg_extension e
            WHERE
                e.extname ~ '^(efm_sql_command)$'
            ORDER BY
                1)
            AND deptype = 'e'
        ORDER BY
            1) foo
    WHERE
        extn_objects ~* '^view'
        OR extn_objects ~* '^function' $SQL$;
  
  EXECUTE 'REVOKE USAGE ON SCHEMA efm_extension FROM '||$1;

  FOR rec IN EXECUTE sql_cmd
  LOOP
     RAISE NOTICE '% FROM %',rec.grant_cmd,$1;
     EXECUTE rec.grant_cmd || ' FROM '||$1;
  END LOOP;
  RETURN true;
  EXCEPTION
    WHEN OTHERS THEN
       RETURN false;
END;
$FUNCTION$;

REVOKE EXECUTE ON FUNCTION efm_extension.revoke_access_from_user(TEXT) FROM PUBLIC;

