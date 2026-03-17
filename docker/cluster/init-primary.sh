#!/bin/bash
# init-primary.sh - Initialize primary PostgreSQL server
#
# This script is called during Docker entrypoint to set up the primary node.

set -e

REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-replicator_pass}"
EFM_DB_PASSWORD="${EFM_DB_PASSWORD:-efm_pass}"

echo "Setting up primary node..."

# This will be run by docker-entrypoint-initdb.d mechanism
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create replication user
    CREATE USER ${REPLICATION_USER} WITH REPLICATION ENCRYPTED PASSWORD '${REPLICATION_PASSWORD}';

    -- Create EFM user
    CREATE USER efm WITH SUPERUSER ENCRYPTED PASSWORD '${EFM_DB_PASSWORD}';

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
