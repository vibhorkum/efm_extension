# EFM Extension for PostgreSQL

A PostgreSQL extension (version 14+) to manage EDB Failover Manager (EFM) clusters through SQL.

## Version 1.1 Features

- **Enhanced Security**: Uses `fork/execve` instead of `system()` to prevent command injection
- **Input Validation**: Strict validation of IP addresses, priorities, and cluster names
- **Structured Returns**: Composite types for better integration with monitoring tools
- **Native JSONB**: Direct JSONB output for cluster status
- **Caching**: Shared memory cache to reduce shell call latency
- **Background Worker**: Optional periodic polling with history persistence
- **Observability**: Prometheus/Grafana/Zabbix compatible metrics views
- **Error Handling**: Maps EFM exit codes to PostgreSQL SQLSTATE codes with stderr capture

## Functions and Views

```sql
-- Core Management Functions --
efm_extension.efm_cluster_status(text)      -- Returns SETOF text ('text' or 'json')
efm_extension.efm_cluster_status_json()     -- Returns jsonb (native)
efm_extension.efm_get_nodes()               -- Returns SETOF node_status (structured)
efm_extension.efm_allow_node(text)          -- Returns integer
efm_extension.efm_disallow_node(text)       -- Returns integer
efm_extension.efm_set_priority(text, text)  -- Returns integer
efm_extension.efm_failover()                -- Returns integer
efm_extension.efm_switchover()              -- Returns integer
efm_extension.efm_resume_monitoring()       -- Returns integer
efm_extension.efm_list_properties()         -- Returns SETOF text

-- Cache Management --
efm_extension.efm_cache_stats()             -- Returns cache_stats
efm_extension.efm_invalidate_cache()        -- Returns void

-- Monitoring Integration --
efm_extension.zabbix_node_discovery()       -- Returns jsonb (LLD format)
efm_extension.cleanup_status_history(int)   -- Returns bigint (rows deleted)

-- Views --
efm_extension.efm_local_properties          -- Parsed config key-value pairs
efm_extension.efm_nodes_details             -- Structured node information
efm_extension.efm_metrics                   -- Prometheus/Grafana metrics
```

## Prerequisites

### 1. EFM Installation
EFM must be installed and configured. See [EDB documentation](https://www.enterprisedb.com/docs/).

### 2. Sudo Configuration
Create a restrictive sudoers file for the PostgreSQL user:

```bash
# /etc/sudoers.d/efm_postgres

# Read-only commands (status queries)
Cmnd_Alias EFM_READONLY = /usr/edb/efm-*/bin/efm cluster-status *, \
                          /usr/edb/efm-*/bin/efm cluster-status-json *

# Write commands (node management)
Cmnd_Alias EFM_WRITE = /usr/edb/efm-*/bin/efm allow-node *, \
                       /usr/edb/efm-*/bin/efm disallow-node *, \
                       /usr/edb/efm-*/bin/efm set-priority *, \
                       /usr/edb/efm-*/bin/efm resume *

# Critical commands (failover/switchover)
Cmnd_Alias EFM_CRITICAL = /usr/edb/efm-*/bin/efm promote *

# Grant permissions (adjust user as needed)
postgres ALL=(efm) NOPASSWD: EFM_READONLY
postgres ALL=(efm) NOPASSWD: EFM_WRITE
postgres ALL=(efm) NOPASSWD: EFM_CRITICAL
```

### 3. PostgreSQL Configuration
Set GUC parameters in `postgresql.conf` or via `ALTER SYSTEM`:

```sql
-- Required settings
ALTER SYSTEM SET efm.cluster_name TO 'efm';
ALTER SYSTEM SET efm.command_path TO '/usr/edb/efm-4.9/bin/efm';
ALTER SYSTEM SET efm.properties_location TO '/etc/edb/efm-4.9';

-- Optional settings (shown with defaults)
ALTER SYSTEM SET efm.sudo_path TO '/usr/bin/sudo';
ALTER SYSTEM SET efm.sudo_user TO 'efm';
ALTER SYSTEM SET efm.cache_ttl TO 5;  -- seconds, 0 = disabled

-- Apply changes
SELECT pg_reload_conf();
```

### 4. Background Worker (Optional)
For caching and history persistence, add to `postgresql.conf`:

```
shared_preload_libraries = 'efm_extension'

# Background worker settings
efm.bgw_enabled = true
efm.bgw_interval = 10          # Poll every 10 seconds
efm.bgw_database = 'postgres'
efm.bgw_persist_history = true # Write to efm_status_history table
```

## Installation

```bash
# Requires PostgreSQL 14+ development headers
git clone https://github.com/vibhorkum/efm_extension
cd efm_extension

# Check PostgreSQL version
make check-version

# Build and install
make
sudo make install
```

## Usage

### Basic Setup

```sql
-- Create extension (requires superuser)
CREATE EXTENSION efm_extension;

-- Grant monitoring access to non-superuser
-- This grants access to read-only functions and views only
SELECT efm_extension.grant_access_to_user('monitoring_user');
```

### Access Control

The extension separates monitoring (read-only) and management (write) functions:

**Monitoring Functions** (accessible by granted users):
- `efm_cluster_status()`, `efm_cluster_status_json()`, `efm_get_nodes()`
- `efm_list_properties()`, `efm_cache_stats()`, `efm_is_available()`
- `zabbix_node_discovery()`, all views

**Management Functions** (superuser only):
- `efm_allow_node()`, `efm_disallow_node()`, `efm_set_priority()`
- `efm_failover()`, `efm_switchover()`, `efm_resume_monitoring()`
- `efm_invalidate_cache()`

### Cluster Status

```sql
-- Text output (legacy)
SELECT efm_extension.efm_cluster_status('text');

-- Native JSONB (recommended)
SELECT efm_extension.efm_cluster_status_json();

-- Structured node details
SELECT * FROM efm_extension.efm_nodes_details;

-- Example output:
--   node_ip    |   role   | db_status | xlog        | agent_status
-- -------------+----------+-----------+-------------+--------------
--  172.17.0.1  | Primary  | UP        | 0/50001234  | UP
--  172.17.0.2  | Standby  | UP        | 0/50001234  | UP
```

### Node Management

```sql
-- Allow a node to join
SELECT efm_extension.efm_allow_node('172.17.0.3');

-- Remove a node
SELECT efm_extension.efm_disallow_node('172.17.0.3');

-- Set failover priority (0 = highest)
SELECT efm_extension.efm_set_priority('172.17.0.2', '1');
```

### Failover Operations

```sql
-- Trigger failover (promotes highest priority standby)
SELECT efm_extension.efm_failover();

-- Graceful switchover
SELECT efm_extension.efm_switchover();

-- Resume monitoring after pause
SELECT efm_extension.efm_resume_monitoring();
```

### Monitoring Integration

```sql
-- Prometheus/Grafana metrics
SELECT * FROM efm_extension.efm_metrics;

-- Example output:
--         metric_name        | value |                    labels
-- ---------------------------+-------+----------------------------------------------
--  efm_cluster_nodes_total   |   3   | {"cluster": "efm"}
--  efm_node_status           |   1   | {"node_ip": "172.17.0.1", "node_type": "Primary"}
--  efm_cache_hit_ratio       | 0.85  | {"cluster": "efm"}

-- Zabbix LLD discovery
SELECT efm_extension.zabbix_node_discovery();
-- Returns: {"data": [{"{#NODE_IP}": "172.17.0.1", "{#NODE_TYPE}": "Primary"}, ...]}
```

### Cache Management

```sql
-- View cache statistics
SELECT * FROM efm_extension.efm_cache_stats();

-- Force cache refresh
SELECT efm_extension.efm_invalidate_cache();

-- Query historical status (if bgw_persist_history = true)
SELECT collected_at, status_json->'nodes'
FROM efm_extension.efm_status_history
ORDER BY collected_at DESC
LIMIT 10;

-- Cleanup old history (default: 7 days retention)
SELECT efm_extension.cleanup_status_history(7);
```

### Configuration Properties

```sql
-- View EFM configuration
SELECT * FROM efm_extension.efm_local_properties;

-- Example output:
--        name         |         value
-- --------------------+------------------------
--  db.user            | efm
--  db.port            | 5444
--  auto.failover      | true
--  minimum.standbys   | 0
```

## GUC Parameters Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `efm.cluster_name` | string | (required) | EFM cluster name |
| `efm.command_path` | string | `/usr/edb/efm-4.9/bin/efm` | Path to EFM binary |
| `efm.sudo_path` | string | `/usr/bin/sudo` | Path to sudo |
| `efm.sudo_user` | string | `efm` | User to run EFM commands as |
| `efm.properties_location` | string | `/etc/edb/efm-4.9` | EFM config directory |
| `efm.cache_ttl` | integer | `5` | Cache TTL in seconds (0 = disabled) |
| `efm.bgw_enabled` | boolean | `false` | Enable background worker |
| `efm.bgw_interval` | integer | `10` | BGW polling interval (seconds) |
| `efm.bgw_database` | string | `postgres` | Database for BGW connection |
| `efm.bgw_persist_history` | boolean | `false` | Persist status to history table |
| `efm.debug` | boolean | `false` | Log exact EFM commands to server log |

## Security Considerations

1. **Command Injection Prevention**: All external commands use `fork/execve` with explicit argument arrays - no shell interpretation
2. **Input Validation**: IP addresses and priorities are strictly validated before use
3. **Privilege Separation**: Uses sudo to run EFM commands as the `efm` user
4. **Audit Logging**: All management operations are logged to PostgreSQL server log
5. **Access Control**: Functions are `SECURITY DEFINER` with `REVOKE ALL FROM PUBLIC`

## Upgrading from 1.0

```sql
ALTER EXTENSION efm_extension UPDATE TO '1.1';
```

The upgrade adds new types, functions, and views while maintaining backward compatibility with existing functions.

## Dependencies

- PostgreSQL 14 or later
- `dblink` extension
- `pgcrypto` extension
- EDB Failover Manager

## License

PostgreSQL License

