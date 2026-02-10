# EFM Extension - Gap Analysis

## Executive Summary

This document identifies gaps between the current `efm_extension` implementation and a fully-featured EFM configuration management system. The analysis is organized by capability category with prioritized recommendations.

**Analysis Date**: 2026-02-10  
**Extension Version**: 1.0  
**Target EFM Versions**: 3.10 - 5.x

---

## Gap Categories

### A. Missing Option Support
Properties recognized by EFM but not surfaced, validated, or documented by the extension.

### B. Incorrect Defaults or Parsing
Properties that may be parsed incorrectly or with wrong default assumptions.

### C. Missing Validation or Constraints
Properties exposed but without proper type checking or range validation.

### D. Missing Documentation/Examples
Lack of user-facing documentation, templates, or usage examples.

### E. Missing Tests and CI Coverage
No regression tests or continuous integration for existing functionality.

---

## A. Missing Option Support

### A1. Newly Identified EFM Properties (not in README sample)

Based on the Options Matrix research, these properties are likely supported by EFM but not documented in the extension README:

#### Database Connection (3 properties)
- `db.data.dir` - PostgreSQL data directory (PGDATA)
  - **Priority**: P1 - High
  - **Impact**: May be required in EFM 4.0+
  - **Implementation**: Add to options matrix, validate as directory path

- `jdbc.sslcert` - Client SSL certificate path
  - **Priority**: P2 - Medium
  - **Impact**: SSL deployments cannot use client certificates
  - **Implementation**: Add path validation, file existence check

- `jdbc.sslkey` - Client SSL private key path
  - **Priority**: P2 - Medium
  - **Impact**: SSL deployments cannot use client certificates
  - **Implementation**: Add path validation, file existence check, permission check (0600)

- `jdbc.sslrootcert` - SSL root certificate path
  - **Priority**: P2 - Medium
  - **Impact**: SSL certificate validation limited
  - **Implementation**: Add path validation, file existence check

#### Network Configuration (1 property)
- `bind.interface` - Network interface to bind to
  - **Priority**: P2 - Medium
  - **Impact**: Cannot specify binding interface in multi-NIC environments
  - **Implementation**: Add interface name validation

#### Monitoring/Timeouts (1 property)
- `notification.timeout` - Notification script timeout
  - **Priority**: P1 - High
  - **Impact**: Notification scripts may hang indefinitely
  - **Implementation**: Add integer validation (> 0)

#### Failover Behavior (1 property)
- `stable.nodes.timeout` - Cluster stabilization timeout
  - **Priority**: P1 - High
  - **Impact**: Failover timing may not be optimal
  - **Implementation**: Add integer validation (> 0)

#### Virtual IP (1 property)
- `virtualIp.single` - Single VIP mode flag
  - **Priority**: P2 - Medium
  - **Impact**: VIP configuration options limited
  - **Implementation**: Add boolean validation

#### Scripts/Hooks (1 property)
- `script.remote.pre.promotion` - Pre-promotion hook on remote nodes
  - **Priority**: P2 - Medium
  - **Impact**: Cannot run pre-promotion logic on standbys
  - **Implementation**: Add path validation, executable check

#### Logging (1 property)
- `log.file` - EFM log file path
  - **Priority**: P2 - Medium
  - **Impact**: Cannot customize log location via extension
  - **Implementation**: Add path validation

#### Advanced EFM 4.0+ Properties (3 properties)
- `application.name` - Database connection application_name
  - **Priority**: P2 - Medium
  - **Impact**: Database connection tracking limited
  - **Implementation**: Add string validation

- `reconfigure.num.sync` - Synchronous standby count
  - **Priority**: P1 - High
  - **Impact**: Cannot configure synchronous replication post-failover
  - **Implementation**: Add integer validation (>= 0)

- `use.replay.tiebreaker` - Use WAL position for promotion decision
  - **Priority**: P1 - High
  - **Impact**: Promotion logic may not prefer most up-to-date standby
  - **Implementation**: Add boolean validation

**Total Missing Properties**: 13  
**Priority Breakdown**: P1 (5), P2 (8)

---

## B. Incorrect Defaults or Parsing

### B1. Properties View Parsing Logic

**Issue**: The `efm_local_properties` view uses simple string split on `=`:
```sql
split_part(foo, '=', 1) AS name,
split_part(foo, '=', 2) AS value
```

**Problems**:
1. **Multi-`=` Values**: If value contains `=`, only text after first `=` is captured
   - Example: `jvm.options=-Xmx32m -Dfoo=bar` → value becomes just `-Xmx32m -Dfoo`
2. **Whitespace**: Leading/trailing spaces not trimmed
3. **No escape handling**: Cannot represent `=` in values

**Impact**: P0 - Critical  
**Affected Properties**: All properties, especially `jvm.options`, encrypted values

**Recommendation**:
- Improve parsing to split only on first `=`
- Use regex-based parsing: `^([^=]+)=(.*)$`
- Trim whitespace from keys and values (optional for values based on EFM spec)

### B2. Boolean Value Parsing

**Issue**: No validation of boolean values in the extension layer.

**Current Behavior**: Values like `"true"`, `"True"`, `"TRUE"`, `"1"`, `"yes"` may all be used in properties file.

**EFM Standard**: Verify if EFM requires literal `true`/`false` or accepts variations.

**Impact**: P1 - High  
**Affected Properties**: `jdbc.ssl`, `auto.allow.hosts`, `auto.failover`, `auto.reconfigure`, `promotable`, `is.witness`, and all other boolean properties.

**Recommendation**:
- Document EFM's boolean parsing behavior
- Validate boolean properties match EFM's expectations
- Provide clear error messages for invalid values

### B3. Integer Range Validation

**Issue**: No validation of integer ranges in the extension layer.

**Current Behavior**: Negative values or out-of-range values accepted without validation.

**Impact**: P1 - High  
**Affected Properties**: All integer properties (timeouts, ports, counts)

**Recommendation**:
- Add range checks for each integer property
- Validate ports (1-65535)
- Validate positive-only integers where applicable

---

## C. Missing Validation or Constraints

### C1. No Property Type System

**Issue**: The extension treats all properties as opaque strings. No type enforcement or validation.

**Current Behavior**:
- `efm_list_properties()` returns raw lines
- View splits on `=`, no further processing
- Invalid values only caught when EFM reads the file

**Impact**: P0 - Critical  
**Scope**: All 44+ properties

**Recommendation**:
Implement a property validation framework:

```c
typedef enum {
    EFM_PROP_STRING,
    EFM_PROP_INTEGER,
    EFM_PROP_BOOLEAN,
    EFM_PROP_ENUM,
    EFM_PROP_PATH,
    EFM_PROP_IPPORT,
    EFM_PROP_EMAIL
} EfmPropertyType;

typedef struct {
    const char *name;
    EfmPropertyType type;
    bool required;
    const char *default_value;
    const char **enum_values; // For enum types
    int (*validator)(const char *value); // Custom validator
    const char *description;
} EfmPropertyDef;
```

### C2. No Required Property Checks

**Issue**: Extension does not validate that required properties are defined.

**Required Properties** (from Options Matrix):
1. `db.user`
2. `db.password.encrypted`
3. `db.port`
4. `db.database`
5. `db.service.owner`
6. `db.service.name`
7. `db.bin`
8. `bind.address`
9. `admin.port`

**Impact**: P1 - High

**Recommendation**:
- Add a validation function to check required properties
- Expose via SQL: `efm_validate_properties()` returning validation errors

### C3. No Enum Value Validation

**Issue**: Enum properties (log levels, SSL modes) not validated against allowed values.

**Affected Properties**:
- `jgroups.loglevel` - Should be one of: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- `efm.loglevel` - Should be one of: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- `jdbc.ssl.mode` - Should be one of: disable, allow, prefer, require, verify-ca, verify-full

**Impact**: P1 - High

**Recommendation**:
- Create allowed value lists for each enum property
- Validate against whitelist
- Provide clear error messages listing valid options

### C4. No Path Existence Validation

**Issue**: Path properties not checked for existence or accessibility.

**Affected Properties**:
- `db.bin`, `db.recovery.conf.dir`, `db.data.dir` - Directory paths
- All `script.*` properties - Executable file paths
- All `jdbc.ssl*` properties - Certificate file paths

**Impact**: P1 - High

**Recommendation**:
- Add file/directory existence checks
- Check executability for script paths
- Check read permissions for certificates
- Provide warnings (not errors) for missing optional paths

### C5. No IP/Port Format Validation

**Issue**: Network properties not validated for correct format.

**Affected Properties**:
- `bind.address` - Should be `IP:port`
- `admin.port` - Should be 1-65535
- `pingServerIp` - Should be valid IP(s)
- `virtualIp` - Should be valid IP
- `virtualIp.netmask` - Should be valid netmask

**Impact**: P1 - High

**Recommendation**:
- Use regex or inet parsing to validate IP addresses
- Validate port ranges
- Handle IPv4 and IPv6 correctly

### C6. No Email Format Validation

**Issue**: `user.email` not validated for proper email format.

**Impact**: P2 - Medium

**Recommendation**:
- Add basic email regex validation
- Accept RFC 5322 subset (simple user@domain pattern)

### C7. No Interdependency Validation

**Issue**: Conditional requirements not enforced.

**Examples**:
- If `virtualIp` is set → `virtualIp.interface` and `virtualIp.netmask` must be set
- If `jdbc.ssl=true` → `jdbc.ssl.mode` should be set
- If `is.witness=true` → certain db.* properties may be optional

**Impact**: P1 - High

**Recommendation**:
- Implement cross-property validation logic
- Document all interdependencies
- Provide clear error messages for missing conditional properties

---

## D. Missing Documentation/Examples

### D1. No Property Reference Documentation

**Issue**: README shows example output but doesn't document:
- What each property does
- Valid values and ranges
- Which properties are required
- EFM version compatibility

**Impact**: P0 - Critical

**Recommendation**:
- Link to official EFM documentation
- Create extension-specific property guide
- Document extension limitations vs. full EFM capabilities

### D2. No Configuration Templates

**Issue**: No example `.properties` files provided.

**Impact**: P1 - High

**Recommendation**:
- Create `examples/` directory
- Add sample configurations:
  - `minimal.properties` - Required properties only
  - `production.properties` - Production-ready configuration
  - `ssl.properties` - SSL-enabled setup
  - `witness.properties` - Witness node configuration
  - `vip.properties` - Virtual IP configuration

### D3. No Migration Guide

**Issue**: No documentation for upgrading between EFM versions.

**Impact**: P1 - High (if breaking changes exist)

**Recommendation**:
- Document property changes by EFM version
- Provide migration scripts if needed
- Warn about deprecated properties

### D4. No Error Message Reference

**Issue**: Users don't know what error messages mean or how to fix them.

**Impact**: P2 - Medium

**Recommendation**:
- Document common error messages
- Provide troubleshooting guide
- Include resolution steps for each error category

### D5. No Best Practices Guide

**Issue**: No guidance on optimal configurations for different scenarios.

**Impact**: P2 - Medium

**Recommendation**:
- Document recommended timeout values
- Explain failover tuning
- Provide performance tips
- Security hardening guidelines

---

## E. Missing Tests and CI Coverage

### E1. No Regression Tests

**Issue**: No `sql/` and `expected/` directories for pg_regress.

**Impact**: P0 - Critical

**Current State**: Makefile has `REGRESS = efm_extension` but no test files exist.

**Recommendation**:
Create comprehensive regression tests:

1. **Basic Functionality Tests** (`sql/01_basic.sql`):
   - Extension creation
   - GUC parameter validation
   - Permission checks

2. **Properties Parsing Tests** (`sql/02_properties.sql`):
   - Parse valid properties file
   - Handle comments and blank lines
   - Test multi-`=` values
   - Test whitespace handling

3. **Validation Tests** (`sql/03_validation.sql`):
   - Required property checks
   - Type validation (boolean, integer, enum)
   - Range validation
   - Path validation
   - Interdependency validation

4. **Error Handling Tests** (`sql/04_errors.sql`):
   - Missing GUC parameters
   - Invalid property values
   - Missing files
   - Permission errors

5. **Command Tests** (`sql/05_commands.sql`):
   - Mock EFM command execution (if testable)
   - Output parsing
   - JSON vs. text format

### E2. No CI/CD Integration

**Issue**: No automated testing on commits.

**Impact**: P1 - High

**Recommendation**:
- Add GitHub Actions workflow
- Test against multiple PostgreSQL versions (12, 13, 14, 15, 16, 17, 18)
- Test build on multiple platforms (Ubuntu, RHEL, Debian)
- Run regression tests automatically
- Check for memory leaks (valgrind)

### E3. No Security Scanning

**Issue**: No static analysis or vulnerability scanning.

**Impact**: P1 - High

**Recommendation**:
- Integrate CodeQL (already planned in task)
- Add compiler warnings (`-Wall -Wextra -Werror`)
- Check for shell injection vulnerabilities
- Validate secure memory handling

### E4. No Performance Testing

**Issue**: No benchmarks for property parsing or command execution.

**Impact**: P3 - Low

**Recommendation**:
- Create performance baseline
- Test with large properties files (1000+ lines)
- Measure command execution overhead

---

## Gap Priority Summary

### P0 - Critical (Must Fix)
1. **C1**: No property type system
2. **D1**: No property reference documentation
3. **E1**: No regression tests
4. **B1**: Incorrect `=` splitting in properties view

**Estimated Effort**: 3-5 days

### P1 - High (Should Fix)
1. **A**: 5 missing high-priority properties
2. **B2**: Boolean value parsing
3. **B3**: Integer range validation
4. **C2-C7**: Various validation gaps
5. **D2-D3**: Configuration templates and migration guide
6. **E2-E3**: CI/CD and security scanning

**Estimated Effort**: 4-6 days

### P2 - Medium (Nice to Have)
1. **A**: 8 missing medium-priority properties
2. **C6**: Email validation
3. **D4-D5**: Error reference and best practices
4. **E4**: Performance testing

**Estimated Effort**: 2-3 days

### P3 - Low (Future Enhancement)
1. Advanced features (async operations, caching, etc.)

---

## Implementation Roadmap

### Phase 1: Foundation (P0)
1. Create regression test infrastructure
2. Implement property definition table (EfmPropertyDef)
3. Fix properties view parsing logic
4. Document all known properties

### Phase 2: Validation (P1)
1. Implement type validators (boolean, integer, enum, path, ip)
2. Add required property checks
3. Add interdependency validation
4. Create configuration templates

### Phase 3: Integration (P1)
1. Set up CI/CD pipeline
2. Integrate CodeQL scanner
3. Add comprehensive tests for all validators
4. Create migration documentation

### Phase 4: Enhancement (P2)
1. Add missing EFM 4.0+ properties
2. Create troubleshooting guide
3. Add best practices documentation
4. Performance optimization

---

## Backward Compatibility Notes

### Non-Breaking Changes (Additive)
- ✅ Adding new property definitions (unknown properties pass through)
- ✅ Adding validation warnings (not errors)
- ✅ Adding new SQL functions (opt-in)
- ✅ Improving documentation

### Potentially Breaking Changes
- ⚠️ Changing properties view to fix `=` splitting (may affect queries)
- ⚠️ Strict validation of required properties (may reject previously accepted configs)
- ⚠️ Type enforcement (may reject loosely-typed values)

### Mitigation Strategy
1. Add configuration flag: `efm.strict_validation` (default: false)
2. Emit warnings for invalid properties in permissive mode
3. Document migration path in release notes
4. Provide validation tool to check existing configs

---

## Success Criteria

### Must Have
- [ ] All P0 gaps addressed
- [ ] Regression tests with >80% coverage
- [ ] All functions documented
- [ ] CI passing on all supported PG versions

### Should Have
- [ ] All P1 gaps addressed
- [ ] Example configurations for common scenarios
- [ ] Security audit passed (CodeQL)
- [ ] Performance baseline established

### Nice to Have
- [ ] P2 gaps addressed
- [ ] Interactive configuration wizard
- [ ] Migration helper scripts

---

## Open Questions

1. **Official EFM Documentation**: What is the canonical reference for property definitions?
2. **EFM Version Support**: Should we maintain backward compatibility with EFM 3.x?
3. **Breaking Changes**: Is it acceptable to fix the `=` parsing bug with a major version bump?
4. **Validation Mode**: Should strict validation be opt-in or opt-out?
5. **Test Coverage**: Is 80% test coverage sufficient, or aim for 90%+?

---

## Next Steps

1. **Verify Options Matrix** against official EFM documentation
2. **Design property validation framework** (table-driven approach)
3. **Create regression test infrastructure** (sql/, expected/ directories)
4. **Implement P0 fixes** (properties view, basic validation)
5. **Set up CI/CD** (GitHub Actions)
6. **Iterate through P1 and P2 gaps** in priority order

