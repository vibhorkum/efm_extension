#!/bin/bash
# start-efm.sh - Start EFM agent
#
# This script starts the EFM agent as a background process.

set -e

EFM_CLUSTER_NAME="${EFM_CLUSTER_NAME:-efm}"
EFM_BIN="/usr/edb/efm-${EFM_VERSION}/bin"

echo "Starting EFM agent..."

# Wait a bit for PostgreSQL to fully initialize
sleep 10

# Check if PostgreSQL is accepting connections
for i in {1..30}; do
    if pg_isready -U postgres > /dev/null 2>&1; then
        echo "PostgreSQL is ready"
        break
    fi
    echo "Waiting for PostgreSQL... ($i/30)"
    sleep 2
done

# Start EFM agent as efm user
echo "Launching EFM agent for cluster: ${EFM_CLUSTER_NAME}"

# Make sure required directories exist with proper permissions
mkdir -p /var/run/efm-${EFM_VERSION}
chown efm:efm /var/run/efm-${EFM_VERSION}
mkdir -p /var/log/efm-${EFM_VERSION}
chown efm:efm /var/log/efm-${EFM_VERSION}
mkdir -p /var/lock/efm-${EFM_VERSION}
chown efm:efm /var/lock/efm-${EFM_VERSION}

# Create sysconfig file if it doesn't exist
if [ ! -f /etc/sysconfig/efm-${EFM_VERSION} ]; then
    mkdir -p /etc/sysconfig
    cat > /etc/sysconfig/efm-${EFM_VERSION} << EOF
JAVA_HOME=/usr/lib/jvm/default-java
EOF
fi

# Start EFM using runefm.sh (runs as daemon, then exits)
cd /etc/edb/efm-${EFM_VERSION}
sudo -u efm "${EFM_BIN}/runefm.sh" start "${EFM_CLUSTER_NAME}" || {
    echo "Failed to start EFM, checking logs..."
    cat /var/log/efm-${EFM_VERSION}/startup-${EFM_CLUSTER_NAME}.log 2>/dev/null || true
    exit 1
}

# Wait a moment and check if EFM started
sleep 5
if sudo -u efm "${EFM_BIN}/efm" cluster-status "${EFM_CLUSTER_NAME}" > /dev/null 2>&1; then
    echo "EFM agent started successfully"
    sudo -u efm "${EFM_BIN}/efm" cluster-status "${EFM_CLUSTER_NAME}"
else
    echo "EFM might still be initializing, checking startup log..."
    cat /var/log/efm-${EFM_VERSION}/startup-${EFM_CLUSTER_NAME}.log 2>/dev/null || true
fi
