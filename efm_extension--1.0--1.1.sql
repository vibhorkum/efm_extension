-- efm_extension--1.0--1.1.sql
-- Upgrade script from version 1.0 to 1.1
--
-- This script adds:
-- - Structured composite types for better observability
-- - JSONB native support for cluster status
-- - Cache statistics and management functions
-- - Prometheus/Grafana/Zabbix compatible metrics views
-- - Status history table for trending
-- - Improved security with input validation
--
-- Copyright (c) 2024, PostgreSQL Global Development Group

-- Complain if script is sourced in psql rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION efm_extension UPDATE TO '1.1'" to load this file. \quit

-- ============================================================================
-- New Composite Types
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

-- Cluster info composite type
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

-- ============================================================================
-- New Functions
-- ============================================================================

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
-- Update efm_nodes_details view to use new function
-- ============================================================================

DROP VIEW IF EXISTS efm_extension.efm_nodes_details;

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
-- New Observability Views
-- ============================================================================

-- Prometheus/Grafana compatible metrics view
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

-- Node type metric
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
-- Status History Table
-- ============================================================================

CREATE TABLE efm_extension.efm_status_history (
    id              bigserial PRIMARY KEY,
    status_json     jsonb NOT NULL,
    collected_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX efm_status_history_collected_at_idx
    ON efm_extension.efm_status_history (collected_at DESC);

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
    WHERE collected_at < pg_catalog.now() - (retention_days || ' days')::interval;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

COMMENT ON FUNCTION efm_extension.cleanup_status_history(integer) IS
    'Remove status history entries older than specified days (default 7)';

REVOKE ALL ON FUNCTION efm_extension.cleanup_status_history(integer) FROM PUBLIC;

-- ============================================================================
-- Update existing functions with better security
-- ============================================================================

-- Update grant_access_to_user with input validation and search_path
CREATE OR REPLACE FUNCTION efm_extension.grant_access_to_user(username text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, efm_extension
AS $$
DECLARE
    rec RECORD;
    -- Management functions that require superuser and should NOT be granted
    management_funcs text[] := ARRAY[
        'efm_allow_node',
        'efm_disallow_node',
        'efm_set_priority',
        'efm_failover',
        'efm_switchover',
        'efm_resume_monitoring',
        'grant_access_to_user',
        'revoke_access_from_user'
    ];
BEGIN
    -- Validate username (prevent SQL injection)
    IF username !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RAISE EXCEPTION 'Invalid username format: %', username;
    END IF;

    -- Grant schema usage
    EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA efm_extension TO %I', username);

    -- Grant access to monitoring functions and views only
    FOR rec IN
        SELECT
            CASE
                WHEN extn_objects ~* '^function' THEN
                    'GRANT EXECUTE ON ' || extn_objects
                WHEN extn_objects ~* '^view' THEN
                    'GRANT SELECT ON ' || pg_catalog.regexp_replace(extn_objects, '^view ', '')
            END AS grant_cmd,
            extn_objects
        FROM (
            SELECT pg_catalog.pg_describe_object(classid, objid, 0) AS extn_objects
            FROM pg_catalog.pg_depend
            WHERE refclassid = 'pg_catalog.pg_extension'::regclass
              AND refobjid = (SELECT oid FROM pg_catalog.pg_extension WHERE extname = 'efm_extension')
              AND deptype = 'e'
        ) foo
        WHERE extn_objects ~* '^(view|function)'
    LOOP
        -- Skip management functions
        IF rec.grant_cmd IS NOT NULL THEN
            IF NOT EXISTS (
                SELECT 1 FROM pg_catalog.unnest(management_funcs) AS mf
                WHERE rec.extn_objects ~* mf
            ) THEN
                EXECUTE pg_catalog.format('%s TO %I', rec.grant_cmd, username);
            END IF;
        END IF;
    END LOOP;

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to grant access: %', SQLERRM;
        RETURN false;
END;
$$;

-- Update revoke_access_from_user with input validation and search_path
CREATE OR REPLACE FUNCTION efm_extension.revoke_access_from_user(username text)
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
                    'REVOKE SELECT ON ' || pg_catalog.regexp_replace(extn_objects, '^view ', '')
            END AS revoke_cmd
        FROM (
            SELECT pg_catalog.pg_describe_object(classid, objid, 0) AS extn_objects
            FROM pg_catalog.pg_depend
            WHERE refclassid = 'pg_catalog.pg_extension'::regclass
              AND refobjid = (SELECT oid FROM pg_catalog.pg_extension WHERE extname = 'efm_extension')
              AND deptype = 'e'
        ) foo
        WHERE extn_objects ~* '^(view|function)'
    LOOP
        IF rec.revoke_cmd IS NOT NULL THEN
            EXECUTE pg_catalog.format('%s FROM %I', rec.revoke_cmd, username);
        END IF;
    END LOOP;

    -- Revoke schema usage
    EXECUTE pg_catalog.format('REVOKE USAGE ON SCHEMA efm_extension FROM %I', username);

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to revoke access: %', SQLERRM;
        RETURN false;
END;
$$;

-- Update remove_pgpool_monitoring to fix parameter names and add search_path
CREATE OR REPLACE FUNCTION efm_extension.remove_pgpool_monitoring(
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

-- Drop old version with wrong signature if exists
DROP FUNCTION IF EXISTS efm_extension.remove_pgpool_monitoring(text, integer, text, text, text);
