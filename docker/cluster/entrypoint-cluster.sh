#!/bin/bash
# entrypoint-cluster.sh - Main entrypoint for cluster nodes
#
# This script determines if this node should be a primary or standby
# and initializes accordingly.

set -e

# Configuration from environment
NODE_ROLE="${NODE_ROLE:-primary}"
PRIMARY_HOST="${PRIMARY_HOST:-}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-replicator_pass}"
EFM_CLUSTER_NAME="${EFM_CLUSTER_NAME:-efm}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

# Ensure data directory exists with correct permissions
mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

echo "=== EFM Cluster Node Initialization ==="
echo "Node Role: ${NODE_ROLE}"
echo "Primary Host: ${PRIMARY_HOST:-N/A (this is primary)}"
echo "EFM Version: ${EFM_VERSION}"
echo "PGDATA: ${PGDATA}"

# Function to wait for PostgreSQL to be ready
wait_for_postgres() {
    local host=$1
    local max_attempts=60
    local attempt=1

    echo "Waiting for PostgreSQL at ${host}..."
    while [ $attempt -le $max_attempts ]; do
        if pg_isready -h "$host" -U postgres > /dev/null 2>&1; then
            echo "PostgreSQL at ${host} is ready"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts - PostgreSQL not ready yet..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "ERROR: PostgreSQL at ${host} did not become ready"
    return 1
}

# Function to initialize as primary
init_as_primary() {
    echo "Initializing as PRIMARY node..."

    # Check if data directory is empty
    if [ -z "$(ls -A $PGDATA 2>/dev/null)" ]; then
        echo "Data directory is empty, running initdb..."

        # Initialize the database as postgres user
        gosu postgres initdb -D "$PGDATA"

        # Configure PostgreSQL for replication
        cat >> "$PGDATA/postgresql.conf" << EOF

# Replication settings
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
hot_standby_feedback = on
wal_log_hints = on

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'

# Connection settings
listen_addresses = '*'

# EFM Extension
shared_preload_libraries = 'efm_extension'
efm.cluster_name = '${EFM_CLUSTER_NAME}'
efm.command_path = '/usr/edb/efm-${EFM_VERSION}/bin/efm'
efm.properties_location = '/etc/edb/efm-${EFM_VERSION}'
efm.cache_ttl = 5
EOF

        # Configure pg_hba.conf
        cat > "$PGDATA/pg_hba.conf" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             0.0.0.0/0               md5
host    replication     ${REPLICATION_USER}    0.0.0.0/0       md5
host    replication     all             0.0.0.0/0               md5
EOF

        # Fix permissions
        chown -R postgres:postgres "$PGDATA"

        # Start PostgreSQL temporarily to create users
        gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start

        # Create replication user
        gosu postgres psql -v ON_ERROR_STOP=1 --username postgres << EOSQL
CREATE USER ${REPLICATION_USER} WITH REPLICATION ENCRYPTED PASSWORD '${REPLICATION_PASSWORD}';
CREATE USER efm WITH SUPERUSER ENCRYPTED PASSWORD '${EFM_DB_PASSWORD:-efm_pass}';
CREATE DATABASE testdb;
\c testdb
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION efm_extension;
EOSQL

        # Stop PostgreSQL
        gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop
    fi

    echo "Primary initialization complete"
}

# Function to initialize as standby
init_as_standby() {
    echo "Initializing as STANDBY node..."

    if [ -z "$PRIMARY_HOST" ]; then
        echo "ERROR: PRIMARY_HOST must be set for standby nodes"
        exit 1
    fi

    # Wait for primary to be ready
    wait_for_postgres "$PRIMARY_HOST"

    # Check if data directory is empty
    if [ -z "$(ls -A $PGDATA 2>/dev/null)" ]; then
        echo "Data directory is empty, running pg_basebackup..."

        # Create .pgpass for pg_basebackup
        echo "${PRIMARY_HOST}:5432:*:${REPLICATION_USER}:${REPLICATION_PASSWORD}" > /var/lib/postgresql/.pgpass
        chown postgres:postgres /var/lib/postgresql/.pgpass
        chmod 600 /var/lib/postgresql/.pgpass

        # Run pg_basebackup as postgres user
        gosu postgres pg_basebackup -h "$PRIMARY_HOST" -U "$REPLICATION_USER" -D "$PGDATA" \
            -Fp -Xs -P -R -C -S "standby_$(hostname | tr -d '-')"

        # Update postgresql.conf for standby
        cat >> "$PGDATA/postgresql.conf" << EOF

# Standby specific settings
primary_conninfo = 'host=${PRIMARY_HOST} port=5432 user=${REPLICATION_USER} password=${REPLICATION_PASSWORD}'
hot_standby = on

# EFM Extension
shared_preload_libraries = 'efm_extension'
efm.cluster_name = '${EFM_CLUSTER_NAME}'
efm.command_path = '/usr/edb/efm-${EFM_VERSION}/bin/efm'
efm.properties_location = '/etc/edb/efm-${EFM_VERSION}'
efm.cache_ttl = 5
EOF

        # Fix permissions
        chown -R postgres:postgres "$PGDATA"
    fi

    echo "Standby initialization complete"
}

# Main initialization logic
case "$NODE_ROLE" in
    primary)
        init_as_primary
        ;;
    standby)
        init_as_standby
        ;;
    *)
        echo "ERROR: Unknown NODE_ROLE: $NODE_ROLE"
        echo "Valid values: primary, standby"
        exit 1
        ;;
esac

# Configure EFM
/usr/local/bin/configure-efm.sh

# Start PostgreSQL in foreground and EFM in background
echo "Starting PostgreSQL..."
gosu postgres postgres -D "$PGDATA" &
PG_PID=$!

# Wait for PostgreSQL to be ready
sleep 5
wait_for_postgres "localhost"

# Start EFM
echo "Starting EFM..."
/usr/local/bin/start-efm.sh &

# Wait for PostgreSQL process
wait $PG_PID
