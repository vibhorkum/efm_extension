-- efm_extension--1.1.sql
-- PostgreSQL extension for EDB Failover Manager (EFM) integration
--
-- Version 1.1 features:
-- - Structured composite types for better observability
-- - JSONB native support for cluster status
-- - Cache statistics and management
-- - Prometheus/Grafana/Zabbix compatible metrics views
-- - Status history table for trending
--
-- Copyright (c) 2024, PostgreSQL Global Development Group

-- Complain if script is sourced in psql rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION efm_extension" to load this file. \quit

-- Revoke default schema access
REVOKE ALL ON SCHEMA efm_extension FROM PUBLIC;

-- ============================================================================
-- Composite Types for Structured Returns
-- ============================================================================

-- Node status composite type
CREATE TYPE efm_extension.node_status AS (
    node_ip         inet,
    node_type       text,
    agent_status    text,
    db_status       text,
    xlog_location   text,
    xlog_info       text,
    priority        integer,
    is_promotable   boolean,
    last_updated    timestamptz
);

COMMENT ON TYPE efm_extension.node_status IS
    'Structured type for EFM node status information';

-- Cluster status composite type
CREATE TYPE efm_extension.cluster_info AS (
    cluster_name            text,
    vip                     text,
    membership_coordinator  text,
    minimum_standbys        integer,
    total_nodes             integer,
    allowed_nodes           text[],
    failover_priority       text[],
    messages                text[],
    fetched_at              timestamptz
);

COMMENT ON TYPE efm_extension.cluster_info IS
    'Structured type for EFM cluster information';

-- Cache statistics type
CREATE TYPE efm_extension.cache_stats AS (
    cache_hits          bigint,
    cache_misses        bigint,
    cache_updates       bigint,
    last_update         timestamptz,
    cache_ttl_seconds   integer
);

COMMENT ON TYPE efm_extension.cache_stats IS
    'Statistics for the EFM status cache';

-- Pool status types (for pgpool integration)
CREATE TYPE efm_extension.pool_status AS (
    pool_pid        integer,
    start_time      text,
    pool_id         integer,
    backend_id      integer,
    database        text,
    username        text,
    create_time     text,
    majorversion    integer,
    minorversion    integer,
    pool_counter    integer,
    pool_backendpid integer,
    pool_connected  integer
);

REVOKE ALL ON TYPE efm_extension.pool_status FROM PUBLIC;

CREATE TYPE efm_extension.pool_link_status AS (
    link_name   text,
    status      text
);

REVOKE ALL ON TYPE efm_extension.pool_link_status FROM PUBLIC;

-- ============================================================================
-- Core EFM Functions (C Language)
-- ============================================================================

-- Get cluster status as text lines (legacy compatibility)
CREATE FUNCTION efm_extension.efm_cluster_status(output_type text)
    RETURNS SETOF text
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_cluster_status';

COMMENT ON FUNCTION efm_extension.efm_cluster_status(text) IS
    'Get EFM cluster status as text lines. Use ''text'' or ''json'' as output_type';

REVOKE ALL ON FUNCTION efm_extension.efm_cluster_status(text) FROM PUBLIC;

-- Get cluster status as native JSONB
CREATE FUNCTION efm_extension.efm_cluster_status_json()
    RETURNS jsonb
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_cluster_status_json';

COMMENT ON FUNCTION efm_extension.efm_cluster_status_json() IS
    'Get EFM cluster status as native JSONB';

REVOKE ALL ON FUNCTION efm_extension.efm_cluster_status_json() FROM PUBLIC;

-- Get structured node information
CREATE FUNCTION efm_extension.efm_get_nodes()
    RETURNS SETOF efm_extension.node_status
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_get_nodes';

COMMENT ON FUNCTION efm_extension.efm_get_nodes() IS
    'Get structured node status information for all cluster nodes';

REVOKE ALL ON FUNCTION efm_extension.efm_get_nodes() FROM PUBLIC;

-- Allow a node to join the cluster
CREATE FUNCTION efm_extension.efm_allow_node(ip_address text)
    RETURNS integer
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_allow_node';

COMMENT ON FUNCTION efm_extension.efm_allow_node(text) IS
    'Allow a node with the specified IP address to join the EFM cluster';

REVOKE ALL ON FUNCTION efm_extension.efm_allow_node(text) FROM PUBLIC;

-- Disallow a node from the cluster
CREATE FUNCTION efm_extension.efm_disallow_node(ip_address text)
    RETURNS integer
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_disallow_node';

COMMENT ON FUNCTION efm_extension.efm_disallow_node(text) IS
    'Remove a node with the specified IP address from the EFM cluster';

REVOKE ALL ON FUNCTION efm_extension.efm_disallow_node(text) FROM PUBLIC;

-- Set failover priority for a node
CREATE FUNCTION efm_extension.efm_set_priority(ip_address text, priority text)
    RETURNS integer
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_set_priority';

COMMENT ON FUNCTION efm_extension.efm_set_priority(text, text) IS
    'Set failover priority for a node (0 = highest priority)';

REVOKE ALL ON FUNCTION efm_extension.efm_set_priority(text, text) FROM PUBLIC;

-- Trigger failover (promote standby)
CREATE FUNCTION efm_extension.efm_failover()
    RETURNS integer
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_failover';

COMMENT ON FUNCTION efm_extension.efm_failover() IS
    'Trigger an EFM failover - promotes the highest priority standby to primary';

REVOKE ALL ON FUNCTION efm_extension.efm_failover() FROM PUBLIC;

-- Trigger switchover (graceful role swap)
CREATE FUNCTION efm_extension.efm_switchover()
    RETURNS integer
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_switchover';

COMMENT ON FUNCTION efm_extension.efm_switchover() IS
    'Trigger an EFM switchover - graceful role swap between primary and standby';

REVOKE ALL ON FUNCTION efm_extension.efm_switchover() FROM PUBLIC;

-- Resume EFM monitoring
CREATE FUNCTION efm_extension.efm_resume_monitoring()
    RETURNS integer
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_resume_monitoring';

COMMENT ON FUNCTION efm_extension.efm_resume_monitoring() IS
    'Resume EFM monitoring after it has been paused';

REVOKE ALL ON FUNCTION efm_extension.efm_resume_monitoring() FROM PUBLIC;

-- List properties from EFM configuration file
CREATE FUNCTION efm_extension.efm_list_properties()
    RETURNS SETOF text
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_list_properties';

COMMENT ON FUNCTION efm_extension.efm_list_properties() IS
    'List all properties from the EFM cluster configuration file';

REVOKE ALL ON FUNCTION efm_extension.efm_list_properties() FROM PUBLIC;

-- Get cache statistics
CREATE FUNCTION efm_extension.efm_cache_stats()
    RETURNS efm_extension.cache_stats
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_cache_stats';

COMMENT ON FUNCTION efm_extension.efm_cache_stats() IS
    'Get statistics about the EFM status cache';

REVOKE ALL ON FUNCTION efm_extension.efm_cache_stats() FROM PUBLIC;

-- Invalidate cache
CREATE FUNCTION efm_extension.efm_invalidate_cache()
    RETURNS void
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_invalidate_cache';

COMMENT ON FUNCTION efm_extension.efm_invalidate_cache() IS
    'Manually invalidate the EFM status cache to force refresh';

REVOKE ALL ON FUNCTION efm_extension.efm_invalidate_cache() FROM PUBLIC;

-- Check if EFM is available (safe to call even when EFM is down)
CREATE FUNCTION efm_extension.efm_is_available()
    RETURNS TABLE (
        is_available    boolean,
        error_code      integer,
        error_message   text
    )
    LANGUAGE C VOLATILE STRICT
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_is_available';

COMMENT ON FUNCTION efm_extension.efm_is_available() IS
    'Check if EFM is available and responding. Safe to call even when EFM is down - will not crash PostgreSQL.';

REVOKE ALL ON FUNCTION efm_extension.efm_is_available() FROM PUBLIC;

-- ============================================================================
-- Views
-- ============================================================================

-- Local properties view (parsed key-value)
CREATE VIEW efm_extension.efm_local_properties AS
SELECT
    split_part(property_line, '=', 1) AS name,
    split_part(property_line, '=', 2) AS value
FROM efm_extension.efm_list_properties() AS property_line;

COMMENT ON VIEW efm_extension.efm_local_properties IS
    'Parsed view of EFM local configuration properties';

-- Node details view (from JSON)
CREATE VIEW efm_extension.efm_nodes_details AS
SELECT
    node_ip,
    node_type AS role,
    db_status,
    xlog_location AS xlog,
    agent_status,
    xlog_info,
    priority,
    is_promotable,
    last_updated
FROM efm_extension.efm_get_nodes();

COMMENT ON VIEW efm_extension.efm_nodes_details IS
    'Detailed view of all EFM cluster nodes with status information';

-- ============================================================================
-- Prometheus/Grafana Compatible Metrics View
-- ============================================================================

CREATE VIEW efm_extension.efm_metrics AS
-- Total nodes metric
SELECT
    'efm_cluster_nodes_total'::text AS metric_name,
    count(*)::float AS value,
    jsonb_build_object(
        'cluster', current_setting('efm.cluster_name', true)
    ) AS labels
FROM efm_extension.efm_get_nodes()

UNION ALL

-- Node status metric (1 = UP, 0 = DOWN)
SELECT
    'efm_node_status'::text AS metric_name,
    CASE agent_status
        WHEN 'UP' THEN 1.0
        ELSE 0.0
    END AS value,
    jsonb_build_object(
        'node_ip', node_ip::text,
        'node_type', node_type,
        'cluster', current_setting('efm.cluster_name', true)
    ) AS labels
FROM efm_extension.efm_get_nodes()

UNION ALL

-- Node type metric (for counting by role)
SELECT
    'efm_node_by_type'::text AS metric_name,
    1.0 AS value,
    jsonb_build_object(
        'node_ip', node_ip::text,
        'node_type', node_type,
        'db_status', db_status,
        'cluster', current_setting('efm.cluster_name', true)
    ) AS labels
FROM efm_extension.efm_get_nodes()

UNION ALL

-- Cache hit ratio
SELECT
    'efm_cache_hit_ratio'::text AS metric_name,
    CASE
        WHEN (stats).cache_hits + (stats).cache_misses > 0
        THEN (stats).cache_hits::float / ((stats).cache_hits + (stats).cache_misses)::float
        ELSE 0.0
    END AS value,
    jsonb_build_object('cluster', current_setting('efm.cluster_name', true)) AS labels
FROM (SELECT efm_extension.efm_cache_stats() AS stats) s;

COMMENT ON VIEW efm_extension.efm_metrics IS
    'Prometheus/Grafana compatible metrics view for EFM monitoring';

-- ============================================================================
-- Zabbix Low-Level Discovery Function
-- ============================================================================

CREATE FUNCTION efm_extension.zabbix_node_discovery()
RETURNS jsonb
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
SELECT jsonb_build_object(
    'data',
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                '{#NODE_IP}', node_ip::text,
                '{#NODE_TYPE}', node_type,
                '{#CLUSTER}', current_setting('efm.cluster_name', true)
            )
        ),
        '[]'::jsonb
    )
)
FROM efm_extension.efm_get_nodes();
$$;

COMMENT ON FUNCTION efm_extension.zabbix_node_discovery() IS
    'Returns node list in Zabbix LLD (Low-Level Discovery) JSON format';

REVOKE ALL ON FUNCTION efm_extension.zabbix_node_discovery() FROM PUBLIC;

-- ============================================================================
-- Status History Table (for background worker persistence)
-- ============================================================================

CREATE TABLE efm_extension.efm_status_history (
    id              bigserial PRIMARY KEY,
    status_json     jsonb NOT NULL,
    collected_at    timestamptz NOT NULL DEFAULT now()
);

-- Index for efficient time-based queries
CREATE INDEX efm_status_history_collected_at_idx
    ON efm_extension.efm_status_history (collected_at DESC);

-- Index for JSONB queries
CREATE INDEX efm_status_history_status_json_idx
    ON efm_extension.efm_status_history USING gin (status_json);

COMMENT ON TABLE efm_extension.efm_status_history IS
    'Historical EFM status data collected by background worker';

REVOKE ALL ON TABLE efm_extension.efm_status_history FROM PUBLIC;
REVOKE ALL ON SEQUENCE efm_extension.efm_status_history_id_seq FROM PUBLIC;

-- Cleanup function for old history
CREATE FUNCTION efm_extension.cleanup_status_history(retention_days integer DEFAULT 7)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
DECLARE
    deleted_count bigint;
BEGIN
    DELETE FROM efm_extension.efm_status_history
    WHERE collected_at < now() - (retention_days || ' days')::interval;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

COMMENT ON FUNCTION efm_extension.cleanup_status_history(integer) IS
    'Remove status history entries older than specified days (default 7)';

REVOKE ALL ON FUNCTION efm_extension.cleanup_status_history(integer) FROM PUBLIC;

-- ============================================================================
-- pgpool Integration Tables and Functions
-- ============================================================================

CREATE TABLE efm_extension.pgpool_nodes (
    hostname    text NOT NULL,
    port        integer NOT NULL,
    database    text NOT NULL,
    username    text NOT NULL,
    password    bytea,
    CONSTRAINT pgpool_nodes_pkey PRIMARY KEY (hostname, port, database)
);

COMMENT ON TABLE efm_extension.pgpool_nodes IS
    'Connection information for pgpool nodes for EFM monitoring integration';

REVOKE ALL ON TABLE efm_extension.pgpool_nodes FROM PUBLIC;

-- Encryption helper
CREATE FUNCTION efm_extension.encrypt_efm(plaintext text, key text)
RETURNS bytea
LANGUAGE sql STRICT
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
    SELECT encrypt(plaintext::bytea, key::bytea, 'aes');
$$;

REVOKE ALL ON FUNCTION efm_extension.encrypt_efm(text, text) FROM PUBLIC;

-- Decryption helper
CREATE FUNCTION efm_extension.get_efm(ciphertext bytea, key text)
RETURNS text
LANGUAGE sql STRICT
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
    SELECT convert_from(decrypt(ciphertext, key::bytea, 'aes'), 'SQL_ASCII');
$$;

REVOKE ALL ON FUNCTION efm_extension.get_efm(bytea, text) FROM PUBLIC;

-- Check if pgpool link exists
CREATE FUNCTION efm_extension.pgpool_link_exists(link_name text)
RETURNS boolean
LANGUAGE sql STRICT
AS $$
    SELECT COALESCE(link_name = ANY(dblink_get_connections()), false);
$$;

REVOKE ALL ON FUNCTION efm_extension.pgpool_link_exists(text) FROM PUBLIC;

-- Get pgpool connection links
CREATE FUNCTION efm_extension.get_pgpool_links()
RETURNS SETOF efm_extension.pool_link_status
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
    SELECT
        'pgpool_' || hostname AS link_name,
        CASE
            WHEN efm_extension.pgpool_link_exists('pgpool_' || hostname) THEN 'OK'
            ELSE dblink_connect(
                'pgpool_' || hostname,
                format('hostaddr=%s port=%s dbname=%I user=%I password=%I',
                    hostname, port, database, username,
                    efm_extension.get_efm(password, 'efm'))
            )
        END AS status
    FROM efm_extension.pgpool_nodes;
$$;

REVOKE ALL ON FUNCTION efm_extension.get_pgpool_links() FROM PUBLIC;

-- Get pgpool backend PID details
CREATE FUNCTION efm_extension.pgpool_backendpid_details(
    conn_name text,
    backend_pid integer
)
RETURNS SETOF efm_extension.pool_status
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
    SELECT *
    FROM dblink(conn_name, 'SHOW pool_pools') AS foo (
        pool_pid integer,
        start_time text,
        pool_id integer,
        backend_id integer,
        database text,
        username text,
        create_time text,
        majorversion integer,
        minorversion integer,
        pool_counter integer,
        pool_backendpid integer,
        pool_connected integer
    )
    WHERE pool_backendpid <> 0 AND pool_backendpid = backend_pid;
$$;

REVOKE ALL ON FUNCTION efm_extension.pgpool_backendpid_details(text, integer) FROM PUBLIC;

-- Add pgpool node for monitoring
CREATE FUNCTION efm_extension.add_pgpool_monitoring(
    hostname text,
    port integer,
    database text,
    username text,
    password text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
BEGIN
    INSERT INTO efm_extension.pgpool_nodes
    VALUES (hostname, port, database, username, efm_extension.encrypt_efm(password, 'efm'));
    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION efm_extension.add_pgpool_monitoring(text, integer, text, text, text) FROM PUBLIC;

-- Remove pgpool node from monitoring
CREATE FUNCTION efm_extension.remove_pgpool_monitoring(
    p_hostname text,
    p_port integer,
    p_database text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
BEGIN
    DELETE FROM efm_extension.pgpool_nodes
    WHERE hostname = p_hostname AND port = p_port AND database = p_database;
    RETURN FOUND;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION efm_extension.remove_pgpool_monitoring(text, integer, text) FROM PUBLIC;

-- Check if connected via pgpool (for determining recovery status)
CREATE FUNCTION efm_extension.pg_is_in_recovery()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
DECLARE
    recovery_status boolean := false;
BEGIN
    WITH pid_info AS (
        SELECT
            link_name,
            (SELECT count(1)
             FROM efm_extension.pgpool_backendpid_details(link_name, pg_backend_pid())
             LIMIT 1) AS num_of_conn
        FROM efm_extension.get_pgpool_links()
    )
    SELECT
        CASE
            WHEN COUNT(1) > 0 THEN true
            ELSE pg_catalog.pg_is_in_recovery()
        END INTO recovery_status
    FROM pid_info
    WHERE num_of_conn > 0;

    -- Disconnect all pgpool links
    PERFORM dblink_disconnect(link_name)
    FROM efm_extension.get_pgpool_links();

    RETURN COALESCE(recovery_status, pg_catalog.pg_is_in_recovery());
EXCEPTION
    WHEN OTHERS THEN
        -- Clean up connections on error
        PERFORM dblink_disconnect(link_name)
        FROM efm_extension.get_pgpool_links();
        RETURN pg_catalog.pg_is_in_recovery();
END;
$$;

REVOKE ALL ON FUNCTION efm_extension.pg_is_in_recovery() FROM PUBLIC;

-- Get last WAL replay LSN (works with pgpool)
CREATE FUNCTION efm_extension.pg_last_wal_replay_lsn()
RETURNS pg_lsn
LANGUAGE sql STABLE
AS $$
    SELECT
        CASE
            WHEN pg_catalog.pg_is_in_recovery() = false THEN pg_catalog.pg_current_wal_lsn()
            ELSE pg_catalog.pg_last_wal_replay_lsn()
        END;
$$;

REVOKE ALL ON FUNCTION efm_extension.pg_last_wal_replay_lsn() FROM PUBLIC;

-- ============================================================================
-- Access Control Functions
-- ============================================================================

-- Grant access to a user
CREATE FUNCTION efm_extension.grant_access_to_user(username text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
DECLARE
    rec RECORD;
    sql_cmd text;
BEGIN
    -- Validate username (prevent SQL injection)
    IF username !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RAISE EXCEPTION 'Invalid username format: %', username;
    END IF;

    -- Grant schema usage
    EXECUTE format('GRANT USAGE ON SCHEMA efm_extension TO %I', username);

    -- Grant access to all functions and views
    FOR rec IN
        SELECT
            CASE
                WHEN extn_objects ~* '^function' THEN
                    'GRANT EXECUTE ON ' || extn_objects
                WHEN extn_objects ~* '^view' THEN
                    'GRANT SELECT ON ' || regexp_replace(extn_objects, '^view ', '')
            END AS grant_cmd
        FROM (
            SELECT pg_catalog.pg_describe_object(classid, objid, 0) AS extn_objects
            FROM pg_catalog.pg_depend
            WHERE refclassid = 'pg_catalog.pg_extension'::regclass
              AND refobjid = (SELECT oid FROM pg_extension WHERE extname = 'efm_extension')
              AND deptype = 'e'
        ) foo
        WHERE extn_objects ~* '^(view|function)'
    LOOP
        IF rec.grant_cmd IS NOT NULL THEN
            EXECUTE format('%s TO %I', rec.grant_cmd, username);
        END IF;
    END LOOP;

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to grant access: %', SQLERRM;
        RETURN false;
END;
$$;

COMMENT ON FUNCTION efm_extension.grant_access_to_user(text) IS
    'Grant access to all EFM extension objects to the specified user';

REVOKE ALL ON FUNCTION efm_extension.grant_access_to_user(text) FROM PUBLIC;

-- Revoke access from a user
CREATE FUNCTION efm_extension.revoke_access_from_user(username text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
DECLARE
    rec RECORD;
BEGIN
    -- Validate username
    IF username !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RAISE EXCEPTION 'Invalid username format: %', username;
    END IF;

    -- Revoke access from all functions and views
    FOR rec IN
        SELECT
            CASE
                WHEN extn_objects ~* '^function' THEN
                    'REVOKE EXECUTE ON ' || extn_objects
                WHEN extn_objects ~* '^view' THEN
                    'REVOKE SELECT ON ' || regexp_replace(extn_objects, '^view ', '')
            END AS revoke_cmd
        FROM (
            SELECT pg_catalog.pg_describe_object(classid, objid, 0) AS extn_objects
            FROM pg_catalog.pg_depend
            WHERE refclassid = 'pg_catalog.pg_extension'::regclass
              AND refobjid = (SELECT oid FROM pg_extension WHERE extname = 'efm_extension')
              AND deptype = 'e'
        ) foo
        WHERE extn_objects ~* '^(view|function)'
    LOOP
        IF rec.revoke_cmd IS NOT NULL THEN
            EXECUTE format('%s FROM %I', rec.revoke_cmd, username);
        END IF;
    END LOOP;

    -- Revoke schema usage
    EXECUTE format('REVOKE USAGE ON SCHEMA efm_extension FROM %I', username);

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to revoke access: %', SQLERRM;
        RETURN false;
END;
$$;

COMMENT ON FUNCTION efm_extension.revoke_access_from_user(text) IS
    'Revoke access to all EFM extension objects from the specified user';

REVOKE ALL ON FUNCTION efm_extension.revoke_access_from_user(text) FROM PUBLIC;
