# EFM Configuration Options Matrix

## Overview
This document catalogs all known EDB Failover Manager (EFM) configuration properties, their types, defaults, and validation requirements. This matrix serves as the reference for implementing proper validation and support in the efm_extension.

**Status**: DRAFT - Requires verification against latest official EFM documentation
**Last Updated**: 2026-02-10
**EFM Version Range**: 3.10 - 5.x (estimated)

## Matrix Format
Each option entry includes:
- **Name**: Exact property name as it appears in .properties file
- **Type**: Data type (boolean, integer, string, enum, list)
- **Default**: Default value if not specified
- **Required**: Whether property must be defined
- **Validation**: Constraints (ranges, patterns, allowed values)
- **Description**: Purpose and behavior
- **Since**: EFM version when introduced (if known)
- **Status**: active, deprecated, or removed

---

## Database Connection Properties

### db.user
- **Type**: string
- **Default**: (none - required)
- **Required**: ✅ Yes
- **Validation**: Valid PostgreSQL username
- **Description**: PostgreSQL database user for EFM agent connections
- **Since**: 1.0
- **Status**: ✅ active

### db.password.encrypted
- **Type**: string (encrypted)
- **Default**: (none - required)
- **Required**: ✅ Yes
- **Validation**: Hex-encoded encrypted password
- **Description**: Encrypted password for database connections (use efm encrypt utility)
- **Since**: 1.0
- **Status**: ✅ active

### db.port
- **Type**: integer
- **Default**: 5432
- **Required**: ✅ Yes
- **Validation**: 1-65535
- **Description**: PostgreSQL server port number
- **Since**: 1.0
- **Status**: ✅ active

### db.database
- **Type**: string
- **Default**: (none - required)
- **Required**: ✅ Yes
- **Validation**: Valid database name
- **Description**: Database name for EFM monitoring connections
- **Since**: 1.0
- **Status**: ✅ active

### db.service.owner
- **Type**: string
- **Default**: (platform-specific)
- **Required**: ✅ Yes (for service control)
- **Validation**: Valid system username
- **Description**: OS user that owns the PostgreSQL service
- **Since**: 1.0
- **Status**: ✅ active

### db.service.name
- **Type**: string
- **Default**: (platform-specific)
- **Required**: ✅ Yes (for service control)
- **Validation**: System service name
- **Description**: Name of PostgreSQL systemd/init service
- **Since**: 1.0
- **Status**: ✅ active

### db.bin
- **Type**: string (path)
- **Default**: (none - required)
- **Required**: ✅ Yes
- **Validation**: Valid directory path
- **Description**: Directory containing PostgreSQL binaries (pg_ctl, etc.)
- **Since**: 1.0
- **Status**: ✅ active

### db.recovery.conf.dir
- **Type**: string (path)
- **Default**: (PostgreSQL data directory)
- **Required**: ❌ No
- **Validation**: Valid directory path
- **Description**: Directory for recovery configuration (PG < 12: recovery.conf location; PG >= 12: data dir for standby.signal)
- **Since**: 1.0
- **Status**: ✅ active

### db.reuse.connection.count
- **Type**: integer
- **Default**: 0
- **Required**: ❌ No
- **Validation**: >= 0
- **Description**: Number of times to reuse database connection before reconnecting (0 = reconnect each time)
- **Since**: 2.0+ (estimated)
- **Status**: ✅ active

### db.data.dir
- **Type**: string (path)
- **Default**: (derived from PostgreSQL)
- **Required**: ⚠️ Recommended
- **Validation**: Valid directory path
- **Description**: PostgreSQL data directory (PGDATA)
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active
- **Notes**: May be required in newer EFM versions

---

## JDBC/SSL Properties

### jdbc.ssl
- **Type**: boolean
- **Default**: false
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Enable SSL/TLS for database connections
- **Since**: 1.0
- **Status**: ✅ active

### jdbc.ssl.mode
- **Type**: enum
- **Default**: verify-ca
- **Required**: ❌ No (if jdbc.ssl=false)
- **Validation**: disable, allow, prefer, require, verify-ca, verify-full
- **Description**: SSL connection mode (PostgreSQL sslmode values)
- **Since**: 2.0+ (estimated)
- **Status**: ✅ active

### jdbc.sslcert
- **Type**: string (path)
- **Default**: (none)
- **Required**: ❌ No
- **Validation**: Valid file path
- **Description**: Path to client SSL certificate
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

### jdbc.sslkey
- **Type**: string (path)
- **Default**: (none)
- **Required**: ❌ No
- **Validation**: Valid file path
- **Description**: Path to client SSL private key
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

### jdbc.sslrootcert
- **Type**: string (path)
- **Default**: (none)
- **Required**: ❌ No
- **Validation**: Valid file path
- **Description**: Path to SSL root certificate
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

---

## Network/Binding Properties

### bind.address
- **Type**: string (ip:port)
- **Default**: (none - required)
- **Required**: ✅ Yes
- **Validation**: IPv4/IPv6:port format
- **Description**: IP address and port for EFM agent listening
- **Since**: 1.0
- **Status**: ✅ active

### admin.port
- **Type**: integer
- **Default**: (bind.address port + 1)
- **Required**: ✅ Yes
- **Validation**: 1-65535
- **Description**: Administrative command port
- **Since**: 1.0
- **Status**: ✅ active

### bind.interface
- **Type**: string
- **Default**: (all interfaces)
- **Required**: ❌ No
- **Validation**: Network interface name
- **Description**: Network interface to bind to
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

---

## Monitoring/Timeout Properties

### local.period
- **Type**: integer (seconds)
- **Default**: 10
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Interval between local database health checks
- **Since**: 1.0
- **Status**: ✅ active

### local.timeout
- **Type**: integer (seconds)
- **Default**: 60
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Timeout for local database operations
- **Since**: 1.0
- **Status**: ✅ active

### local.timeout.final
- **Type**: integer (seconds)
- **Default**: 10
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Final timeout before declaring database down
- **Since**: 1.0
- **Status**: ✅ active

### remote.timeout
- **Type**: integer (seconds)
- **Default**: 10
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Timeout for remote agent communication
- **Since**: 1.0
- **Status**: ✅ active

### node.timeout
- **Type**: integer (seconds)
- **Default**: 50
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Time before a non-responsive node is considered failed
- **Since**: 1.0
- **Status**: ✅ active

### notification.timeout
- **Type**: integer (seconds)
- **Default**: 30
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Timeout for notification script execution
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

---

## Failover Behavior Properties

### auto.failover
- **Type**: boolean
- **Default**: true
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Enable automatic failover on primary failure
- **Since**: 1.0
- **Status**: ✅ active

### auto.reconfigure
- **Type**: boolean
- **Default**: true
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Automatically reconfigure standbys to follow new primary
- **Since**: 1.0
- **Status**: ✅ active

### promotable
- **Type**: boolean
- **Default**: true
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Whether this standby is eligible for promotion
- **Since**: 1.0
- **Status**: ✅ active

### minimum.standbys
- **Type**: integer
- **Default**: 0
- **Required**: ❌ No
- **Validation**: >= 0
- **Description**: Minimum number of standbys required before failover
- **Since**: 1.0
- **Status**: ✅ active

### recovery.check.period
- **Type**: integer (seconds)
- **Default**: 2
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Interval for checking standby recovery progress
- **Since**: 1.0
- **Status**: ✅ active

### auto.resume.period
- **Type**: integer (seconds)
- **Default**: 0
- **Required**: ❌ No
- **Validation**: >= 0
- **Description**: Time to wait before auto-resuming monitoring after stop (0 = disabled)
- **Since**: 2.0+ (estimated)
- **Status**: ✅ active

### stable.nodes.timeout
- **Type**: integer (seconds)
- **Default**: 30
- **Required**: ❌ No
- **Validation**: > 0
- **Description**: Time to wait for cluster to stabilize before failover
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

---

## Node Management Properties

### auto.allow.hosts
- **Type**: boolean
- **Default**: false
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Automatically allow new nodes to join cluster
- **Since**: 1.0
- **Status**: ✅ active

### is.witness
- **Type**: boolean
- **Default**: false
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Designate this agent as a witness (voting only, no database)
- **Since**: 2.0+ (estimated)
- **Status**: ✅ active

---

## Network Testing Properties

### pingServerIp
- **Type**: string (IP address or comma-separated list)
- **Default**: 8.8.8.8
- **Required**: ❌ No
- **Validation**: Valid IPv4/IPv6 addresses
- **Description**: IP address(es) to ping for network connectivity testing
- **Since**: 1.0
- **Status**: ✅ active

### pingServerCommand
- **Type**: string (command)
- **Default**: /bin/ping -q -c3 -w5
- **Required**: ❌ No
- **Validation**: Valid command path
- **Description**: Command to execute for ping testing
- **Since**: 1.0
- **Status**: ✅ active

---

## Virtual IP Properties

### virtualIp
- **Type**: string (IP address)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid IPv4/IPv6 address
- **Description**: Virtual IP address to assign to primary node
- **Since**: 1.0
- **Status**: ✅ active

### virtualIp.interface
- **Type**: string
- **Default**: (none - required if virtualIp set)
- **Required**: ⚠️ Conditional (if virtualIp set)
- **Validation**: Network interface name
- **Description**: Network interface for virtual IP assignment
- **Since**: 1.0
- **Status**: ✅ active

### virtualIp.netmask
- **Type**: string (netmask)
- **Default**: (none - required if virtualIp set)
- **Required**: ⚠️ Conditional (if virtualIp set)
- **Validation**: Valid netmask (e.g., 255.255.255.0 or /24)
- **Description**: Network mask for virtual IP
- **Since**: 1.0
- **Status**: ✅ active

### virtualIp.single
- **Type**: boolean
- **Default**: false
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Use single VIP mode (vs. multiple VIPs)
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

---

## Script/Hook Properties

### script.notification
- **Type**: string (path)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid file path, executable
- **Description**: Script to execute for event notifications
- **Since**: 1.0
- **Status**: ✅ active

### script.fence
- **Type**: string (path)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid file path, executable
- **Description**: Script to fence (isolate) failed primary node
- **Since**: 1.0
- **Status**: ✅ active

### script.post.promotion
- **Type**: string (path)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid file path, executable
- **Description**: Script to run after standby promotion
- **Since**: 1.0
- **Status**: ✅ active

### script.resumed
- **Type**: string (path)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid file path, executable
- **Description**: Script to run when monitoring is resumed
- **Since**: 2.0+ (estimated)
- **Status**: ✅ active

### script.db.failure
- **Type**: string (path)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid file path, executable
- **Description**: Script to run when database failure is detected
- **Since**: 2.0+ (estimated)
- **Status**: ✅ active

### script.master.isolated
- **Type**: string (path)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid file path, executable
- **Description**: Script to run when primary is isolated from cluster
- **Since**: 2.0+ (estimated)
- **Status**: ✅ active

### script.remote.pre.promotion
- **Type**: string (path)
- **Default**: (none - disabled if not set)
- **Required**: ❌ No
- **Validation**: Valid file path, executable
- **Description**: Script to run on remote nodes before promotion
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

---

## System/Sudo Properties

### sudo.command
- **Type**: string (command)
- **Default**: sudo
- **Required**: ❌ No
- **Validation**: Valid command path
- **Description**: Sudo command for elevated operations
- **Since**: 1.0
- **Status**: ✅ active

### sudo.user.command
- **Type**: string (command template)
- **Default**: sudo -u %u
- **Required**: ❌ No
- **Validation**: Command with %u placeholder
- **Description**: Sudo command template for user-specific operations
- **Since**: 1.0
- **Status**: ✅ active

---

## Logging Properties

### jgroups.loglevel
- **Type**: enum
- **Default**: INFO
- **Required**: ❌ No
- **Validation**: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- **Description**: JGroups communication library log level
- **Since**: 1.0
- **Status**: ✅ active

### efm.loglevel
- **Type**: enum
- **Default**: INFO
- **Required**: ❌ No
- **Validation**: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- **Description**: EFM agent log level
- **Since**: 1.0
- **Status**: ✅ active

### log.file
- **Type**: string (path)
- **Default**: (installation-specific)
- **Required**: ❌ No
- **Validation**: Valid file path
- **Description**: Path to EFM log file
- **Since**: 3.0+ (estimated)
- **Status**: ✅ active

---

## JVM Properties

### jvm.options
- **Type**: string (JVM arguments)
- **Default**: -Xmx32m
- **Required**: ❌ No
- **Validation**: Valid JVM options
- **Description**: JVM command-line options for EFM agent
- **Since**: 1.0
- **Status**: ✅ active

---

## Licensing/Email Properties

### efm.license
- **Type**: string (license key)
- **Default**: (none - may be required for enterprise features)
- **Required**: ⚠️ Conditional
- **Validation**: Valid license string
- **Description**: EFM license key
- **Since**: 1.0
- **Status**: ✅ active

### user.email
- **Type**: string (email address)
- **Default**: (none - recommended)
- **Required**: ❌ No
- **Validation**: Valid email format
- **Description**: Administrator email for notifications
- **Since**: 1.0
- **Status**: ✅ active

---

## Additional Properties (EFM 4.0+)

### application.name
- **Type**: string
- **Default**: (cluster_name)
- **Required**: ❌ No
- **Validation**: Valid string
- **Description**: Application name for database connections
- **Since**: 4.0+ (estimated)
- **Status**: ✅ active

### reconfigure.num.sync
- **Type**: integer
- **Default**: 0
- **Required**: ❌ No
- **Validation**: >= 0
- **Description**: Number of synchronous standbys to configure after failover
- **Since**: 4.0+ (estimated)
- **Status**: ✅ active

### use.replay.tiebreaker
- **Type**: boolean
- **Default**: false
- **Required**: ❌ No
- **Validation**: true, false
- **Description**: Use WAL replay position as tiebreaker for promotion
- **Since**: 4.0+ (estimated)
- **Status**: ✅ active

---

## Summary Statistics

### By Status
- ✅ Active: ~60 properties
- ⚠️ Deprecated: 0 (pending official docs review)
- ❌ Removed: 0 (pending official docs review)

### By Requirement
- Required: 8 properties
- Conditional: 3 properties
- Optional: ~49 properties

### By Type
- String: ~30
- Integer: ~15
- Boolean: ~12
- Enum: ~3
- Path: ~15 (subset of string)

---

## Validation Rules Summary

### Common Patterns
1. **Boolean**: Must be literal `true` or `false` (case-insensitive recommended)
2. **Integer**: Numeric, non-negative unless specified
3. **Path**: Must be absolute or relative, file/dir existence checked at runtime
4. **IP Address**: Valid IPv4/IPv6 format, optional CIDR notation
5. **Port**: Integer 1-65535
6. **Email**: Standard email format (RFC 5322 subset)
7. **Enum**: Case-sensitive match against allowed values

### Interdependencies
1. If `virtualIp` set → `virtualIp.interface` and `virtualIp.netmask` required
2. If `jdbc.ssl=true` → `jdbc.ssl.mode` should be set
3. If `is.witness=true` → certain db.* properties may be optional

---

## Notes for Implementation

### Priority Levels
1. **P0 - Critical**: Required properties, core failover behavior
2. **P1 - High**: Common optional properties (timeouts, monitoring)
3. **P2 - Medium**: Advanced features (VIP, scripts, witness)
4. **P3 - Low**: Rarely used properties (JVM tuning, advanced SSL)

### Unknown Property Handling
**Recommendation**: Store unknown properties as pass-through key-value pairs with a WARNING log entry. This ensures:
- Forward compatibility with newer EFM versions
- Custom/vendor-specific properties are preserved
- Users are alerted to potential typos

### Case Sensitivity
**EFM Standard**: Property names are case-sensitive. Values may be case-insensitive for booleans/enums (verify in official docs).

---

## References
- [ ] EDB Failover Manager Official Documentation (pending URL)
- [ ] EFM Release Notes (pending URL)
- [ ] Sample properties.conf.in template (pending verification)
- [x] Current efm_extension README (44 properties observed)

**TODO**: Verify this matrix against official EFM 5.x documentation once accessible.
