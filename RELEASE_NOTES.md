# EFM Extension Release Notes

## Version 1.1.0 (March 2026)

This is the first production release of the EFM Extension for PostgreSQL. The extension provides SQL-level management and monitoring of EDB Failover Manager (EFM) clusters.

### Requirements

- PostgreSQL 14 or later
- EDB Failover Manager (EFM) 4.x or 5.x
- Dependencies: `dblink`, `pgcrypto` extensions

### Core Features

#### Cluster Management Functions

| Function | Description |
|----------|-------------|
| `efm_cluster_status(text)` | Returns cluster status as text ('text' or 'json' format) |
| `efm_cluster_status_json()` | Returns cluster status as native JSONB |
| `efm_get_nodes()` | Returns structured node information (SETOF node_status) |
| `efm_allow_node(ip)` | Allow a node to join the cluster |
| `efm_disallow_node(ip)` | Remove a node from the cluster |
| `efm_set_priority(ip, priority)` | Set failover priority for a node |
| `efm_failover()` | Trigger manual failover |
| `efm_switchover()` | Trigger graceful switchover |
| `efm_resume_monitoring()` | Resume EFM monitoring after pause |
| `efm_list_properties()` | List EFM configuration properties (sensitive values redacted) |
| `efm_is_available()` | Check if EFM is available and responding |

#### Caching System

- **Shared Memory Cache**: Reduces EFM shell call latency with configurable TTL
- `efm_cache_stats()` - View cache hit/miss statistics
- `efm_invalidate_cache()` - Force cache refresh
- Configurable via `efm.cache_ttl` (default: 5 seconds, 0 to disable)

#### Background Worker

Optional background worker for continuous monitoring:
- Periodic EFM status polling
- Automatic cache updates
- Optional history persistence to `efm_status_history` table
- Configurable polling interval

#### Monitoring Integration

| View/Function | Description |
|---------------|-------------|
| `efm_nodes_details` | Structured view of all cluster nodes |
| `efm_local_properties` | Parsed EFM configuration key-value pairs |
| `efm_metrics` | Prometheus/Grafana compatible metrics |
| `zabbix_node_discovery()` | Zabbix LLD format for auto-discovery |
| `cleanup_status_history(days)` | Cleanup old history records |

#### pgpool-II Integration

- `pg_is_in_recovery()` - pgpool-aware recovery status check
- `pg_last_wal_replay_lsn()` - Unified LSN interface for primary/standby
- `pgpool_backendpid_details()` - Query pgpool backend information
- Encrypted credential storage for pgpool connections

### Security Features

1. **Command Injection Prevention**
   - Uses `fork/execve` instead of `system()` - no shell interpretation
   - Explicit argument arrays prevent injection attacks

2. **Input Validation**
   - Strict IPv4 address validation (rejects leading zeros, out-of-range octets)
   - Priority validation (0-999, numeric only)
   - Cluster name validation (alphanumeric, underscores, hyphens)

3. **Privilege Separation**
   - Functions use `SECURITY DEFINER` with restricted `search_path`
   - `REVOKE ALL FROM PUBLIC` on all functions
   - Management functions require superuser
   - Monitoring functions can be granted to non-superusers via `grant_access_to_user()`

4. **Sensitive Data Protection**
   - Passwords and license keys automatically redacted in `efm_list_properties()`
   - Encryption key configurable via `efm.encryption_key` (superuser only)

### Configuration Parameters (GUCs)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `efm.cluster_name` | string | (required) | EFM cluster name |
| `efm.command_path` | string | - | Full path to EFM binary |
| `efm.properties_location` | string | `/etc/edb/efm-4.9` | EFM config directory |
| `efm.java_home` | string | (from env) | Path to Java installation |
| `efm.sudo_path` | string | `/usr/bin/sudo` | Path to sudo binary |
| `efm.sudo_user` | string | `efm` | User to run EFM commands as |
| `efm.cache_ttl` | integer | `5` | Cache TTL in seconds (0 = disabled) |
| `efm.debug` | boolean | `false` | Log exact EFM commands to server log |
| `efm.encryption_key` | string | `efm` | Encryption key for pgpool credentials |
| `efm.bgw_enabled` | boolean | `false` | Enable background worker |
| `efm.bgw_interval` | integer | `10` | BGW polling interval (seconds) |
| `efm.bgw_database` | string | `postgres` | Database for BGW connection |
| `efm.bgw_persist_history` | boolean | `false` | Persist status to history table |

### Sudo Configuration

The extension requires sudo access to run EFM commands. Example sudoers configuration:

```bash
# /etc/sudoers.d/efm_postgres
# SETENV allows passing JAVA_HOME which EFM requires

Cmnd_Alias EFM_READONLY = /usr/edb/efm-*/bin/efm cluster-status *, \
                          /usr/edb/efm-*/bin/efm cluster-status-json *

Cmnd_Alias EFM_WRITE = /usr/edb/efm-*/bin/efm allow-node *, \
                       /usr/edb/efm-*/bin/efm disallow-node *, \
                       /usr/edb/efm-*/bin/efm set-priority *, \
                       /usr/edb/efm-*/bin/efm resume *

Cmnd_Alias EFM_CRITICAL = /usr/edb/efm-*/bin/efm promote *

postgres ALL=(efm) NOPASSWD: SETENV: EFM_READONLY
postgres ALL=(efm) NOPASSWD: SETENV: EFM_WRITE
postgres ALL=(efm) NOPASSWD: SETENV: EFM_CRITICAL
```

### Error Handling

- EFM exit codes mapped to PostgreSQL SQLSTATE codes
- Stderr output captured and included in error details
- Internal exit codes for timeout (-3), I/O errors (-4), and wait failures (-5)
- Handles EFM quirk where `cluster-status-json` returns exit code 1 on success

### Internal Exit Codes

| Code | Meaning |
|------|---------|
| `-1` | Child process terminated by signal |
| `-2` | Unknown wait status |
| `-3` | Command timed out |
| `-4` | I/O error reading command output |
| `-5` | waitpid() failed |

### Known Limitations

1. IPv6 addresses not currently supported for node management
2. Background worker requires `shared_preload_libraries` configuration
3. Some EFM versions return exit code 1 even on success (handled automatically)

### Installation

```bash
# Build and install
make
sudo make install

# In PostgreSQL
CREATE EXTENSION efm_extension;

# Configure required parameters
ALTER SYSTEM SET efm.cluster_name TO 'your_cluster';
ALTER SYSTEM SET efm.command_path TO '/usr/edb/efm-5.2/bin/efm';
ALTER SYSTEM SET efm.java_home TO '/usr/lib/jvm/java-11-openjdk';
SELECT pg_reload_conf();
```

### Quick Start

```sql
-- Check EFM availability
SELECT * FROM efm_extension.efm_is_available();

-- Get cluster status as JSON
SELECT efm_extension.efm_cluster_status_json();

-- View node details
SELECT * FROM efm_extension.efm_nodes_details;

-- View metrics (Prometheus/Grafana compatible)
SELECT * FROM efm_extension.efm_metrics;

-- Grant monitoring access to a user
SELECT efm_extension.grant_access_to_user('monitoring_user');
```

### Debugging

Enable debug logging to see exact commands being executed:

```sql
SET efm.debug = on;
SELECT efm_extension.efm_cluster_status_json();
-- Check PostgreSQL log for: LOG: EFM command: /usr/bin/sudo -n -u efm ...
```

### License

PostgreSQL License

### Contributors

- EDB Development Team
- Community Contributors
