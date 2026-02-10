# EFM Extension - Architecture Overview

## Purpose
This PostgreSQL extension provides a SQL interface to EDB Failover Manager (EFM) commands, allowing database administrators to execute EFM operations through normal database connections without requiring direct shell access.

## Version Information
- **Extension Version**: 1.0
- **Target EFM Version**: 3.10+ (based on code references)
- **Supported PostgreSQL**: 10+
- **Dependencies**: dblink, pgcrypto

## Architecture Components

### 1. Extension Entry Points

#### C Module (`efm_extension.c`)
- **Module Magic**: Uses `PG_MODULE_MAGIC` for PostgreSQL compatibility
- **Initialization**: `_PG_init()` - Registers custom GUC parameters
- **Memory Management**: Uses `palloc()`/`pfree()` for PostgreSQL memory contexts

#### SQL Interface (`efm_extension--1.0.sql`)
- **Schema**: `efm_extension` (non-relocatable)
- **Security**: All functions use `SECURITY DEFINER`
- **Privileges**: All objects revoked from PUBLIC by default

### 2. Configuration Parameters (GUC)

The extension defines 4 custom PostgreSQL configuration parameters:

| Parameter | Type | Default | Purpose |
|-----------|------|---------|---------|
| `efm.cluster_name` | string | NULL | EFM cluster identifier |
| `efm.edb_sudo` | string | NULL | Sudo command prefix for EFM user |
| `efm.command_path` | string | NULL | Full path to EFM binary |
| `efm.properties_location` | string | NULL | Directory containing EFM properties files |

**Configuration Level**: `PGC_SUSET` (superuser or ALTER SYSTEM)

### 3. SQL Functions Exposed

#### EFM Command Wrappers
- `efm_cluster_status(TEXT)` → SETOF TEXT - Returns cluster status (text/json format)
- `efm_allow_node(TEXT)` → INTEGER - Allow a node to join cluster
- `efm_disallow_node(TEXT)` → INTEGER - Disallow a node from cluster
- `efm_set_priority(TEXT, TEXT)` → INTEGER - Set failover priority for a node
- `efm_failover()` → INTEGER - Promote current standby to primary
- `efm_switchover()` → INTEGER - Perform controlled switchover
- `efm_resume_monitoring()` → INTEGER - Resume EFM monitoring

#### EFM Configuration Access
- `efm_list_properties()` → SETOF TEXT - Lists all properties from EFM config file

#### Views
- `efm_local_properties` - Parsed key=value pairs from properties file
- `efm_nodes_details` - Structured node information from cluster status (JSON)

#### PgPool Integration Functions
- `add_pgpool_monitoring()` - Register a PgPool node for monitoring
- `remove_pgpool_monitoring()` - Unregister a PgPool node
- `pgpool_backendpid_details()` - Get backend connection details
- `pg_is_in_recovery()` - Enhanced recovery check with PgPool awareness
- `pg_last_wal_replay_lsn()` - WAL replay LSN (handles primary/standby)

### 4. Data Flow

```
SQL Function Call
    ↓
requireSuperuser() check
    ↓
get_efm_command() - Build command string
    ↓
command_exists() - Validate EFM binary path
    ↓
check_efm_cluster_name_sudo() - Validate GUC settings
    ↓
system() / popen() - Execute EFM command via shell
    ↓
Parse output / Return result
```

### 5. EFM Properties File Parsing

**Current Implementation** (`efm_list_properties`):
```c
// Constructs command:
cat <properties_location>/<cluster_name>.properties | grep -v "^#" | sed '/^$/d'
```

**Properties File Location**: `{efm.properties_location}/{efm.cluster_name}.properties`

**Parsing Strategy**:
- Uses shell pipeline to filter comments and blank lines
- Returns raw `key=value` lines via SRF (Set Returning Function)
- View `efm_local_properties` splits on `=` delimiter

**Limitations**:
- No validation of property names or values
- No type checking
- No handling of multi-line values
- No detection of duplicate keys
- No enforcement of required properties

### 6. Command Execution Pattern

**Security Model**:
```bash
{efm.edb_sudo} {efm.command_path} <command> {efm.cluster_name} [arguments]
```

Example:
```bash
sudo -u efm /usr/edb/efm-3.10/bin/efm cluster-status efm
```

**Return Values**:
- INTEGER functions: Return shell exit code (0 = success)
- SETOF TEXT functions: Stream command output line-by-line

### 7. Key Data Structures

#### OutputContext (for SRF functions)
```c
typedef struct OutputContext {
    FILE   *fp;      // popen() file handle
    char   *line;    // getline() buffer (malloc'd, not palloc'd)
    size_t len;      // Buffer length
} OutputContext;
```

**Memory Management Note**: 
- `line` buffer allocated by `getline()` (glibc) → freed with `free()`
- Other structures use PostgreSQL palloc/pfree

### 8. Error Handling

**Validation Points**:
1. Superuser check (`requireSuperuser()`) - raises ERROR if not superuser
2. Command existence (`command_exists()`) - raises ERROR if binary not found
3. GUC validation (`check_efm_cluster_name_sudo()`) - raises ERROR if undefined
4. Properties file check (`check_efm_properties_file()`) - raises ERROR if missing

**Error Reporting**:
- Uses `elog(ERROR, ...)` for immediate errors
- Uses `ereport(ERROR, ...)` with proper errcode for superuser check
- Command failures return non-zero exit codes (not raised as errors)

### 9. PostgreSQL Integration

**Build System**: PGXS-based Makefile
- Uses `pg_config` to locate PostgreSQL installation
- Standard contrib module structure

**Extension Control**:
- Requires superuser for installation
- Non-relocatable schema
- Single version (no upgrade paths defined yet)

### 10. Current Limitations & Technical Debt

#### Security Concerns
1. **Command Injection Risk**: Direct string concatenation in `get_efm_command()`
2. **Shell Execution**: Uses `system()` and `popen()` - vulnerable to shell metacharacters
3. **Credential Exposure**: Properties file may contain passwords (though encrypted)

#### Functionality Gaps
1. **No Property Validation**: Unknown properties pass through unchecked
2. **No Type Enforcement**: All properties treated as strings
3. **Limited Error Context**: Command failures don't capture stderr
4. **No Async Support**: All operations are blocking

#### Code Quality
1. **Magic Numbers**: Hardcoded string lengths in buffer allocation
2. **Mixed Memory Management**: Uses both palloc/pfree and malloc/free
3. **Limited Comments**: Minimal inline documentation
4. **No Unit Tests**: Only integration testing possible via pg_regress

## Known EFM Properties (from README example output)

### Database Connection (10 properties)
- `db.user`, `db.password.encrypted`, `db.port`, `db.database`
- `db.service.owner`, `db.service.name`, `db.bin`
- `db.recovery.conf.dir`, `db.reuse.connection.count`

### JDBC/SSL (2 properties)
- `jdbc.ssl` (boolean)
- `jdbc.ssl.mode` (enum: verify-ca, etc.)

### Network Configuration (3 properties)
- `bind.address` (IP:port)
- `admin.port` (integer)
- `pingServerIp`, `pingServerCommand`

### Cluster Behavior (8 properties)
- `auto.allow.hosts` (boolean)
- `auto.failover` (boolean)
- `auto.reconfigure` (boolean)
- `auto.resume.period` (integer)
- `promotable` (boolean)
- `minimum.standbys` (integer)
- `is.witness` (boolean)
- `recovery.check.period` (integer)

### Timeouts (5 properties)
- `local.period`, `local.timeout`, `local.timeout.final`
- `remote.timeout`, `node.timeout`

### Virtual IP (3 properties)
- `virtualIp`, `virtualIp.interface`, `virtualIp.netmask`

### Scripts/Hooks (5 properties)
- `script.notification`, `script.fence`, `script.post.promotion`
- `script.resumed`, `script.db.failure`, `script.master.isolated`

### System Commands (2 properties)
- `sudo.command`, `sudo.user.command`

### Logging (3 properties)
- `jgroups.loglevel` (enum: INFO, DEBUG, etc.)
- `efm.loglevel` (enum)
- `jvm.options` (string)

### Licensing (1 property)
- `efm.license`

### Notifications (1 property)
- `user.email`

**Total: 44 properties identified in sample output**

## Extension Capabilities Summary

| Capability | Current State | Notes |
|------------|---------------|-------|
| Execute EFM commands | ✅ Full | Via sudo wrapper |
| Read EFM properties | ✅ Full | Via cat + grep pipeline |
| Validate properties | ❌ None | No validation layer |
| Parse property types | ❌ None | All strings |
| Detect unknown options | ❌ None | No option registry |
| Generate config files | ❌ None | Read-only access |
| Cluster status monitoring | ✅ Full | Text and JSON formats |
| PgPool integration | ✅ Full | Unique feature |
| WAL/LSN tracking | ✅ Full | Recovery-aware |

## Recommendations for Modernization

### High Priority
1. **Property Validation Framework**: Create table-driven validator
2. **Input Sanitization**: Prevent command injection
3. **Error Handling**: Capture and report stderr from EFM commands
4. **Documentation**: Document all supported EFM versions and properties

### Medium Priority
5. **Type System**: Enforce boolean/integer/string types
6. **Config Generation**: Add functions to write/update properties
7. **Upgrade Path**: Define version migration scripts
8. **Testing**: Add pg_regress tests for all functions

### Low Priority
9. **Async Operations**: Use background workers for long operations
10. **Caching**: Cache property file contents (with invalidation)
