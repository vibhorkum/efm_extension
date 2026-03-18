#!/bin/bash
# init-primary.sh - Initialize primary PostgreSQL server
#
# This script is called during Docker entrypoint to set up the primary node.
# Uses psql variables (-v) to safely pass credentials without SQL injection risk.

set -e

REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-replicator_pass}"
EFM_DB_PASSWORD="${EFM_DB_PASSWORD:-efm_pass}"

echo "Setting up primary node..."

# Create users with proper escaping using psql variables and format()
# This prevents SQL injection if passwords contain special characters
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v repl_user="$REPLICATION_USER" \
    -v repl_pass="$REPLICATION_PASSWORD" \
    -v efm_pass="$EFM_DB_PASSWORD" <<'EOSQL'
    -- Create replication user with proper escaping
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'repl_user') THEN
            EXECUTE format('CREATE USER %I WITH REPLICATION ENCRYPTED PASSWORD %L',
                          :'repl_user', :'repl_pass');
        END IF;
    END
    $$;

    -- Create EFM user with proper escaping
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'efm') THEN
            EXECUTE format('CREATE USER efm WITH SUPERUSER ENCRYPTED PASSWORD %L',
                          :'efm_pass');
        END IF;
    END
    $$;

    -- Create test database if needed
    SELECT 'CREATE DATABASE testdb' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'testdb')\gexec

    -- Connect to testdb and install extensions
    \c testdb
    CREATE EXTENSION IF NOT EXISTS dblink;
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE EXTENSION IF NOT EXISTS efm_extension;

    -- Grant permissions
    GRANT USAGE ON SCHEMA efm_extension TO efm;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA efm_extension TO efm;
EOSQL

echo "Primary node setup complete"
