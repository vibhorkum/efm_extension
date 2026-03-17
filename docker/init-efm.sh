#!/bin/bash
# init-efm.sh - Initialize EFM during container startup
#
# This script:
# 1. Creates the EFM database user
# 2. Encrypts the EFM password
# 3. Generates the EFM properties file
# 4. Starts the EFM agent
#
# Environment variables:
#   EFM_VERSION - EFM version (required, set in Dockerfile)
#   EFM_DB_PASSWORD - Password for EFM database user (default: efm_password)
#   EFM_CLUSTER_NAME - Cluster name (default: efm)
#   BIND_ADDRESS - IP address to bind EFM (default: auto-detected)

set -e

EFM_VERSION="${EFM_VERSION:-4.9}"
EFM_DB_PASSWORD="${EFM_DB_PASSWORD:-efm_password}"
EFM_CLUSTER_NAME="${EFM_CLUSTER_NAME:-efm}"
EFM_BIN="/usr/edb/efm-${EFM_VERSION}/bin"
EFM_CONF_DIR="/etc/edb/efm-${EFM_VERSION}"

echo "Initializing EFM ${EFM_VERSION}..."

# Auto-detect bind address if not set
if [ -z "$BIND_ADDRESS" ]; then
    BIND_ADDRESS=$(hostname -I | awk '{print $1}')
fi
echo "Using bind address: ${BIND_ADDRESS}"

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
until pg_isready -U postgres; do
    sleep 1
done

# Create EFM database user
echo "Creating EFM database user..."
psql -U postgres -d postgres <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'efm') THEN
        CREATE USER efm WITH PASSWORD '${EFM_DB_PASSWORD}' SUPERUSER;
    END IF;
END
\$\$;
EOF

# Create efm_extension if not exists
echo "Creating efm_extension..."
psql -U postgres -d postgres -c "CREATE EXTENSION IF NOT EXISTS efm_extension;"

# Encrypt the password using EFM's encrypt utility
echo "Encrypting EFM password..."
EFM_DB_PASSWORD_ENCRYPTED=$("${EFM_BIN}/efm" encrypt efm --from-env <<< "${EFM_DB_PASSWORD}" 2>/dev/null || echo "")

if [ -z "$EFM_DB_PASSWORD_ENCRYPTED" ]; then
    # Fallback: use efm-encrypt if available
    if [ -x "${EFM_BIN}/efm-encrypt" ]; then
        EFM_DB_PASSWORD_ENCRYPTED=$("${EFM_BIN}/efm-encrypt" <<< "${EFM_DB_PASSWORD}")
    else
        echo "WARNING: Could not encrypt password, using placeholder"
        EFM_DB_PASSWORD_ENCRYPTED="encrypted_placeholder"
    fi
fi

# Generate EFM properties file from template
echo "Generating EFM properties file..."
export BIND_ADDRESS EFM_DB_PASSWORD_ENCRYPTED PG_MAJOR
envsubst < "${EFM_CONF_DIR}/efm.properties.template" > "${EFM_CONF_DIR}/${EFM_CLUSTER_NAME}.properties"
chown efm:efm "${EFM_CONF_DIR}/${EFM_CLUSTER_NAME}.properties"
chmod 600 "${EFM_CONF_DIR}/${EFM_CLUSTER_NAME}.properties"

# Create EFM nodes file
echo "Creating EFM nodes file..."
echo "${BIND_ADDRESS}:7800" > "${EFM_CONF_DIR}/${EFM_CLUSTER_NAME}.nodes"
chown efm:efm "${EFM_CONF_DIR}/${EFM_CLUSTER_NAME}.nodes"
chmod 600 "${EFM_CONF_DIR}/${EFM_CLUSTER_NAME}.nodes"

# Start EFM agent
echo "Starting EFM agent..."
sudo -u efm "${EFM_BIN}/efm" start "${EFM_CLUSTER_NAME}" &

# Wait for EFM to be ready
echo "Waiting for EFM to be ready..."
for i in {1..30}; do
    if sudo -u efm "${EFM_BIN}/efm" cluster-status "${EFM_CLUSTER_NAME}" &>/dev/null; then
        echo "EFM is ready!"
        break
    fi
    sleep 1
done

echo "EFM initialization complete."
