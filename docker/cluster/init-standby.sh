#!/bin/bash
# init-standby.sh - Initialize standby PostgreSQL server
#
# This script initializes a standby node from a running primary.

set -e

PRIMARY_HOST="${PRIMARY_HOST:?PRIMARY_HOST is required}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-replicator_pass}"

echo "Setting up standby node from primary: ${PRIMARY_HOST}"

# Wait for primary to be available
echo "Waiting for primary PostgreSQL..."
for i in {1..60}; do
    if pg_isready -h "$PRIMARY_HOST" -U postgres > /dev/null 2>&1; then
        echo "Primary is ready"
        break
    fi
    echo "Attempt $i/60 - Primary not ready yet..."
    sleep 2
done

# Create password file
echo "${PRIMARY_HOST}:5432:*:${REPLICATION_USER}:${REPLICATION_PASSWORD}" > ~/.pgpass
chmod 600 ~/.pgpass

# Take base backup
echo "Taking base backup from primary..."
pg_basebackup -h "$PRIMARY_HOST" -U "$REPLICATION_USER" -D /var/lib/postgresql/data \
    -Fp -Xs -P -R -C -S "standby_$(hostname | tr -d '-')"

echo "Standby node setup complete"
