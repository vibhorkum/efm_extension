# EFM Extension - Compatibility Matrix

## PostgreSQL Version Support

### Supported Versions

This extension supports **only officially maintained PostgreSQL versions** as defined by the PostgreSQL Global Development Group:

| PostgreSQL Version | Support Status | Build Status | Notes |
|-------------------|----------------|--------------|-------|
| 17.x | ✅ Supported | Tested | Current stable |
| 16.x | ✅ Supported | Tested | Current stable |
| 15.x | ✅ Supported | Tested | Current stable |
| 14.x | ✅ Supported | Tested | Current stable |
| 13.x | ✅ Supported | Tested | Current stable |
| 12.x | ✅ Supported | Tested | Minimum supported |
| 11.x | ❌ Unsupported | - | EOL November 2023 |
| 10.x | ❌ Unsupported | - | EOL November 2022 |

**Last Updated**: 2026-02-10

**Policy**: This extension follows PostgreSQL's [versioning policy](https://www.postgresql.org/support/versioning/). When a PostgreSQL major version reaches end-of-life, support is removed in the next extension release.

### Version Detection

The extension uses compile-time checks to ensure compatibility:

```c
#if PG_VERSION_NUM < 120000
#error "PostgreSQL 12 or later is required"
#endif
```

**Build Failure Behavior**: Attempting to build on unsupported PostgreSQL versions will fail with a clear error message at compile time.

---

## EFM Version Support

### Supported EFM Versions

| EFM Version | Support Status | Configuration Mode | Notes |
|-------------|----------------|-------------------|-------|
| 5.x | ✅ Supported | `efm.version = 5` | Latest, recommended |
| 4.x | ✅ Supported | `efm.version = 4` | Maintained for compatibility |
| 3.10 | ⚠️ Limited | Legacy | Read-only support, no new features |
| 3.x (< 3.10) | ❌ Unsupported | - | Too old, security risks |

**Default**: EFM 4.x behavior for backward compatibility.

### Version Selection Mechanism

The extension uses a GUC parameter to determine EFM behavior:

```sql
-- Set in postgresql.conf or via ALTER SYSTEM
SET efm.version = 5;  -- Use EFM 5.x mode
SET efm.version = 4;  -- Use EFM 4.x mode (default)
```

**Validation**: The parameter accepts only `4` or `5`. Invalid values are rejected at runtime.

---

## EFM 4.x vs 5.x Behavioral Differences

### Configuration Property Changes

#### New in EFM 5.x

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `db.data.dir` | path | (auto-detected) | PostgreSQL data directory (required in 5.x) |
| `application.name` | string | (cluster_name) | Application name for connections |
| `reconfigure.num.sync` | integer | 0 | Number of sync standbys after failover |
| `use.replay.tiebreaker` | boolean | false | Use WAL position for promotion decisions |
| `stable.nodes.timeout` | integer | 30 | Cluster stabilization timeout (seconds) |

#### Deprecated in EFM 5.x

| Property | Replacement | Migration Notes |
|----------|-------------|-----------------|
| `db.recovery.conf.dir` | `db.data.dir` | 5.x uses PostgreSQL 12+ standby.signal approach |
| (none currently) | - | Full compatibility maintained for 4.x properties |

#### Changed Defaults in EFM 5.x

| Property | EFM 4.x Default | EFM 5.x Default | Reason |
|----------|----------------|----------------|--------|
| `minimum.standbys` | 0 | 1 | Safer failover (requires at least one standby) |
| `auto.reconfigure` | true | true | (unchanged) |
| `use.replay.tiebreaker` | N/A | false | New property |

### Command Behavior Changes

#### EFM 5.x Command Updates

1. **cluster-status-json**
   - EFM 4.x: Basic JSON output
   - EFM 5.x: Enhanced JSON with additional metrics (WAL lag, sync state)

2. **promote**
   - EFM 4.x: Simple promotion
   - EFM 5.x: Considers `use.replay.tiebreaker` setting

3. **set-priority**
   - EFM 4.x: Simple priority setting
   - EFM 5.x: Validates against `reconfigure.num.sync` constraints

### How the Extension Handles Differences

The extension adapts its behavior based on the `efm.version` setting:

#### Property Validation

```c
// Pseudo-code example
if (efm_version == 5) {
    // Require db.data.dir in EFM 5.x
    if (property_missing("db.data.dir")) {
        ereport(ERROR, "db.data.dir is required in EFM 5.x");
    }
} else {
    // EFM 4.x allows db.recovery.conf.dir instead
    if (property_missing("db.data.dir") && property_missing("db.recovery.conf.dir")) {
        ereport(WARNING, "db.data.dir recommended for EFM 5.x compatibility");
    }
}
```

#### Command Execution

- Extension passes version-appropriate flags to EFM binary
- JSON parsing adapts to version-specific output formats
- Property lists filtered based on version compatibility

---

## Backward Compatibility Guarantees

### Extension API Stability

**Guaranteed Stable** (no breaking changes):
- ✅ All SQL function signatures remain unchanged
- ✅ GUC parameter names remain unchanged
- ✅ View schemas remain compatible
- ✅ Extension upgrade path from 1.0 → 1.x

**May Change** (with migration guide):
- ⚠️ Internal property validation rules (strict vs permissive modes)
- ⚠️ Error message formats
- ⚠️ Performance characteristics

### Configuration Compatibility

**EFM 4.x → 5.x Migration**:

1. **Assessment**: Review your properties file against the compatibility matrix
2. **Required Changes**:
   ```properties
   # Add for EFM 5.x (if not present)
   db.data.dir=/var/lib/postgresql/data
   
   # Optional: Set application name
   application.name=my_cluster
   ```

3. **Testing**: Set `efm.version = 5` and validate with `efm_validate_properties()` (future function)

4. **Rollback**: Change `efm.version = 4` to revert to 4.x behavior

**No Downtime Required**: Version parameter can be changed with `pg_reload_conf()`

### PostgreSQL Upgrade Path

**Upgrading PostgreSQL** (e.g., 14 → 15):

1. ✅ Extension is binary-compatible (rebuild not required for minor PG upgrades)
2. ✅ Recompile extension for major PG upgrades
3. ✅ No schema changes required
4. ✅ No configuration changes required

**Process**:
```bash
# After PostgreSQL upgrade
cd efm_extension
make clean
make PG_CONFIG=/usr/pgsql-15/bin/pg_config
sudo make install PG_CONFIG=/usr/pgsql-15/bin/pg_config
# Then restart PostgreSQL
```

---

## Testing Matrix

The extension is tested across the compatibility matrix:

| PostgreSQL | EFM 4.x | EFM 5.x | Platform |
|------------|---------|---------|----------|
| 17 | ✅ | ✅ | Ubuntu 24.04 |
| 16 | ✅ | ✅ | Ubuntu 24.04, 22.04 |
| 15 | ✅ | ✅ | Ubuntu 22.04 |
| 14 | ✅ | ✅ | Ubuntu 22.04 |
| 13 | ✅ | ✅ | Ubuntu 20.04 |
| 12 | ✅ | ✅ | Ubuntu 20.04 |

**CI/CD**: All combinations tested automatically on every commit.

---

## Migration Scenarios

### Scenario 1: Fresh Install (EFM 5.x)

```sql
-- Install extension
CREATE EXTENSION efm_extension;

-- Configure for EFM 5.x
ALTER SYSTEM SET efm.version = 5;
ALTER SYSTEM SET efm.cluster_name = 'my_cluster';
ALTER SYSTEM SET efm.command_path = '/usr/edb/efm-5.0/bin/efm';
ALTER SYSTEM SET efm.properties_location = '/etc/edb/efm-5.0';
SELECT pg_reload_conf();
```

### Scenario 2: Upgrade from EFM 3.10 → 5.x

```sql
-- Step 1: Update EFM binary (external)
-- Step 2: Update extension configuration
ALTER SYSTEM SET efm.version = 5;
ALTER SYSTEM SET efm.command_path = '/usr/edb/efm-5.0/bin/efm';
ALTER SYSTEM SET efm.properties_location = '/etc/edb/efm-5.0';

-- Step 3: Validate configuration
SELECT * FROM efm_extension.efm_local_properties WHERE name = 'db.data.dir';
-- If NULL, add to properties file

-- Step 4: Reload configuration
SELECT pg_reload_conf();
```

### Scenario 3: Downgrade EFM 5.x → 4.x

```sql
-- Step 1: Change version
ALTER SYSTEM SET efm.version = 4;
ALTER SYSTEM SET efm.command_path = '/usr/edb/efm-4.9/bin/efm';
ALTER SYSTEM SET efm.properties_location = '/etc/edb/efm-4.9';

-- Step 2: Reload
SELECT pg_reload_conf();

-- Note: EFM 5.x-specific properties in config file are ignored in 4.x mode
```

---

## Deprecation Policy

### Extension Deprecation Timeline

When support for a PostgreSQL or EFM version is removed:

1. **Announcement**: Deprecation notice in release notes (N-2 versions before removal)
2. **Warning Phase**: Compile-time warnings for deprecated versions (N-1 version)
3. **Removal**: Support removed, build fails (N version)

**Example**:
- Extension 1.1 (2025-Q3): Announce PG 12 deprecation (warning)
- Extension 1.2 (2026-Q1): PG 12 builds with warnings
- Extension 1.3 (2026-Q3): PG 12 support removed (build fails)

### Property Deprecation

When EFM properties are deprecated:

1. Properties remain **functional** but generate warnings
2. Migration guide provided in release notes
3. After 2 major EFM versions, deprecated properties may be removed

---

## Frequently Asked Questions

### Q: Can I use EFM 5.x with PostgreSQL 12?
**A**: Yes, EFM 5.x supports PostgreSQL 12+. Set `efm.version = 5` in postgresql.conf.

### Q: What happens if I set the wrong efm.version?
**A**: The extension will use the specified version's behavior. If your actual EFM binary is a different version, commands may fail or behave unexpectedly. Always match `efm.version` to your installed EFM version.

### Q: Can I switch efm.version without restarting PostgreSQL?
**A**: Yes, use `SELECT pg_reload_conf()` after changing the parameter.

### Q: How do I know which EFM version I have installed?
**A**: Run `/usr/edb/efm-*/bin/efm --version` or check `SELECT efm_extension.efm_cluster_status('json')` output.

### Q: Is the extension compatible with community PostgreSQL?
**A**: Yes, the extension works with both community PostgreSQL and EDB Postgres Advanced Server.

---

## Support Lifecycle

| Component | Support Duration | Policy |
|-----------|------------------|--------|
| PostgreSQL | 5 years | Follows official PostgreSQL policy |
| EFM 5.x | Active | Current development |
| EFM 4.x | Maintenance | Security & critical fixes only |
| EFM 3.10 | Limited | Read-only, no new features |
| Extension | Continuous | Aligned with PostgreSQL lifecycle |

**Support Queries**: File issues at https://github.com/vibhorkum/efm_extension/issues

---

## Appendix: Version Detection Reference

### PostgreSQL Version Macros

```c
PG_VERSION_NUM  // Numeric version (e.g., 160001 for 16.1)
PG_MAJORVERSION // String version (e.g., "16")
```

### EFM Version Detection

```bash
# Check installed EFM version
/usr/edb/efm-*/bin/efm --version

# Output example:
# EDB Failover Manager 5.0.1
```

### Runtime Version Checks

```sql
-- Check extension configuration
SHOW efm.version;

-- Check PostgreSQL version
SELECT version();

-- Check loaded extension version
SELECT extversion FROM pg_extension WHERE extname = 'efm_extension';
```
