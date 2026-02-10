# EFM Extension Modernization - Implementation Plan

## Overview
This document outlines the step-by-step implementation plan for bringing the efm_extension up to date with modern EFM configuration options and best practices.

**Status**: Ready for Implementation  
**Timeline**: Estimated 10-14 days (phased approach)  
**Risk Level**: Medium (includes potential breaking changes, mitigated by feature flags)

---

## Prerequisites Completed ✅

- [x] Repository structure analyzed (ARCHITECTURE.md)
- [x] EFM options cataloged (EFM_OPTIONS_MATRIX.md)
- [x] Gap analysis completed (GAP_ANALYSIS.md)
- [x] Build system understood (PGXS Makefile)
- [x] Current functionality documented

---

## Phase 1: Foundation & Testing Infrastructure (Days 1-3)

### 1.1 Create Test Infrastructure

**Files to Create**:
- `sql/01_basic.sql` - Basic extension tests
- `expected/01_basic.out` - Expected output
- `sql/02_properties_parse.sql` - Properties parsing tests
- `expected/02_properties_parse.out` - Expected output
- `test/test_properties/minimal.properties` - Test property file
- `test/test_properties/full.properties` - Complete test property file
- `test/test_properties/invalid.properties` - Invalid property file

**Implementation Steps**:
```bash
# Create directory structure
mkdir -p sql expected test/test_properties

# Create minimal test
cat > sql/01_basic.sql <<'EOF'
-- Test extension creation
CREATE EXTENSION efm_extension;

-- Verify schema exists
SELECT COUNT(*) FROM pg_namespace WHERE nspname = 'efm_extension';

-- List all functions
SELECT proname FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
 WHERE n.nspname = 'efm_extension'
 ORDER BY proname;

-- Test superuser requirement (should fail)
SET ROLE postgres; -- This would be a non-superuser in real test
-- SELECT efm_extension.efm_cluster_status('text'); -- Expect ERROR

DROP EXTENSION efm_extension;
EOF
```

**Validation**:
```bash
make installcheck
# Should see test results, some may fail initially
```

**Estimated Time**: 1 day

---

### 1.2 Fix Properties View Parsing Bug

**Problem**: `split_part(foo, '=', 1)` only captures text before first `=`, breaking values with embedded `=`.

**Files to Edit**:
- `efm_extension--1.0.sql` (lines 80-90)

**Changes**:
```sql
-- OLD (incorrect for values with =):
CREATE VIEW efm_local_properties AS
SELECT
    split_part(foo, '=', 1) AS name,
    split_part(foo, '=', 2) AS value
FROM efm_extension.efm_list_properties() foo;

-- NEW (correct parsing):
CREATE VIEW efm_local_properties AS
SELECT
    (regexp_match(foo, '^([^=]+)=(.*)$'))[1] AS name,
    (regexp_match(foo, '^([^=]+)=(.*)$'))[2] AS value
FROM efm_extension.efm_list_properties() foo
WHERE foo ~ '^[^=]+='; -- Only lines with at least one =

-- Alternative with trim:
CREATE VIEW efm_local_properties AS
SELECT
    trim((regexp_match(foo, '^([^=]+)=(.*)$'))[1]) AS name,
    (regexp_match(foo, '^([^=]+)=(.*)$'))[2] AS value
FROM efm_extension.efm_list_properties() foo
WHERE foo ~ '^[^=]+=';
```

**Validation**:
- Add test case with `jvm.options=-Xmx32m -Dfoo=bar`
- Verify full value is captured

**Estimated Time**: 0.5 days (including tests)

---

### 1.3 Add Validation Framework Structure (C Code)

**Files to Edit**:
- `efm_extension.c` (insert after line 16)

**Changes**:
```c
/* Property validation framework */
typedef enum {
    EFM_PROP_STRING,
    EFM_PROP_INTEGER,
    EFM_PROP_BOOLEAN,
    EFM_PROP_ENUM,
    EFM_PROP_PATH_FILE,
    EFM_PROP_PATH_DIR,
    EFM_PROP_IPPORT,
    EFM_PROP_EMAIL,
    EFM_PROP_UNKNOWN
} EfmPropertyType;

typedef struct {
    const char *name;
    EfmPropertyType type;
    bool required;
    const char *default_value;
    const char **allowed_values; /* For enum types, NULL-terminated array */
    const char *description;
    int min_value; /* For integer types */
    int max_value; /* For integer types */
} EfmPropertyDef;

/* Property registry - to be populated */
static const EfmPropertyDef efm_known_properties[] = {
    /* Database Connection Properties */
    {"db.user", EFM_PROP_STRING, true, NULL, NULL, 
     "PostgreSQL database user for EFM agent connections", 0, 0},
    {"db.password.encrypted", EFM_PROP_STRING, true, NULL, NULL,
     "Encrypted password for database connections", 0, 0},
    {"db.port", EFM_PROP_INTEGER, true, "5432", NULL,
     "PostgreSQL server port number", 1, 65535},
    {"db.database", EFM_PROP_STRING, true, NULL, NULL,
     "Database name for EFM monitoring connections", 0, 0},
    
    /* Timeouts */
    {"local.period", EFM_PROP_INTEGER, false, "10", NULL,
     "Interval between local database health checks (seconds)", 1, INT_MAX},
    {"local.timeout", EFM_PROP_INTEGER, false, "60", NULL,
     "Timeout for local database operations (seconds)", 1, INT_MAX},
    
    /* Boolean Properties */
    {"auto.failover", EFM_PROP_BOOLEAN, false, "true", NULL,
     "Enable automatic failover on primary failure", 0, 0},
    {"auto.reconfigure", EFM_PROP_BOOLEAN, false, "true", NULL,
     "Automatically reconfigure standbys to follow new primary", 0, 0},
    
    /* Enum Properties */
    {"efm.loglevel", EFM_PROP_ENUM, false, "INFO", 
     (const char*[]){"TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL", NULL},
     "EFM agent log level", 0, 0},
    
    /* Sentinel */
    {NULL, EFM_PROP_UNKNOWN, false, NULL, NULL, NULL, 0, 0}
};

/* Forward declarations for validation functions */
static const EfmPropertyDef* find_property_def(const char *name);
static bool validate_property_value(const EfmPropertyDef *def, const char *value, char **errmsg);
static bool validate_boolean(const char *value);
static bool validate_integer(const char *value, int min, int max, int *result);
static bool validate_enum(const char *value, const char **allowed_values);
```

**Files to Create**:
- `efm_validation.h` (optional, for cleaner separation)

**Validation**:
- Code compiles without errors
- Makefile still builds successfully

**Estimated Time**: 1 day

---

## Phase 2: Core Validation Implementation (Days 4-6)

### 2.1 Implement Property Validators

**Files to Edit**:
- `efm_extension.c` (add before `_PG_init()`)

**Implementation**:
```c
/*
 * Find property definition by name
 */
static const EfmPropertyDef*
find_property_def(const char *name)
{
    const EfmPropertyDef *def;
    
    for (def = efm_known_properties; def->name != NULL; def++)
    {
        if (strcmp(def->name, name) == 0)
            return def;
    }
    return NULL; /* Unknown property */
}

/*
 * Validate boolean value
 */
static bool
validate_boolean(const char *value)
{
    if (value == NULL || strlen(value) == 0)
        return false;
    
    /* Accept: true, false (case-insensitive) */
    if (pg_strcasecmp(value, "true") == 0 ||
        pg_strcasecmp(value, "false") == 0)
        return true;
    
    return false;
}

/*
 * Validate integer value within range
 */
static bool
validate_integer(const char *value, int min, int max, int *result)
{
    char *endptr;
    long val;
    
    if (value == NULL || strlen(value) == 0)
        return false;
    
    errno = 0;
    val = strtol(value, &endptr, 10);
    
    if (errno != 0 || *endptr != '\0')
        return false; /* Not a valid integer */
    
    if (val < min || val > max)
        return false; /* Out of range */
    
    if (result != NULL)
        *result = (int)val;
    
    return true;
}

/*
 * Validate enum value against allowed list
 */
static bool
validate_enum(const char *value, const char **allowed_values)
{
    const char **p;
    
    if (value == NULL || allowed_values == NULL)
        return false;
    
    for (p = allowed_values; *p != NULL; p++)
    {
        if (strcmp(value, *p) == 0)
            return true;
    }
    return false;
}

/*
 * Main validation function
 */
static bool
validate_property_value(const EfmPropertyDef *def, const char *value, char **errmsg)
{
    int int_val;
    
    if (def == NULL || value == NULL)
    {
        if (errmsg != NULL)
            *errmsg = pstrdup("Invalid property definition or value is NULL");
        return false;
    }
    
    switch (def->type)
    {
        case EFM_PROP_BOOLEAN:
            if (!validate_boolean(value))
            {
                if (errmsg != NULL)
                    *errmsg = psprintf("Property '%s' must be 'true' or 'false', got '%s'",
                                      def->name, value);
                return false;
            }
            break;
            
        case EFM_PROP_INTEGER:
            if (!validate_integer(value, def->min_value, def->max_value, &int_val))
            {
                if (errmsg != NULL)
                    *errmsg = psprintf("Property '%s' must be an integer between %d and %d, got '%s'",
                                      def->name, def->min_value, def->max_value, value);
                return false;
            }
            break;
            
        case EFM_PROP_ENUM:
            if (!validate_enum(value, def->allowed_values))
            {
                StringInfoData allowed_str;
                const char **p;
                
                initStringInfo(&allowed_str);
                for (p = def->allowed_values; *p != NULL; p++)
                {
                    if (p != def->allowed_values)
                        appendStringInfo(&allowed_str, ", ");
                    appendStringInfo(&allowed_str, "%s", *p);
                }
                
                if (errmsg != NULL)
                    *errmsg = psprintf("Property '%s' must be one of [%s], got '%s'",
                                      def->name, allowed_str.data, value);
                
                pfree(allowed_str.data);
                return false;
            }
            break;
            
        case EFM_PROP_STRING:
            /* Basic string validation - just check non-empty for required props */
            if (def->required && strlen(value) == 0)
            {
                if (errmsg != NULL)
                    *errmsg = psprintf("Property '%s' is required and cannot be empty", def->name);
                return false;
            }
            break;
            
        /* TODO: Implement path, IP, email validation */
        case EFM_PROP_PATH_FILE:
        case EFM_PROP_PATH_DIR:
        case EFM_PROP_IPPORT:
        case EFM_PROP_EMAIL:
        case EFM_PROP_UNKNOWN:
        default:
            /* For now, accept unknown types with warning */
            if (def->type == EFM_PROP_UNKNOWN && errmsg != NULL)
                *errmsg = psprintf("Warning: Unknown property type for '%s'", def->name);
            break;
    }
    
    return true;
}
```

**Estimated Time**: 1.5 days

---

### 2.2 Add Validation SQL Function

**Files to Edit**:
- `efm_extension.c` - Add new function
- `efm_extension--1.0.sql` - Add function declaration

**C Code Addition**:
```c
PG_FUNCTION_INFO_V1(efm_validate_properties);

/*
 * efm_validate_properties()
 * 
 * Validates all properties in the current properties file.
 * Returns table of (property_name, is_valid, message)
 */
Datum
efm_validate_properties(PG_FUNCTION_ARGS)
{
    /* Implementation using efm_list_properties() and validation framework */
    /* Returns tuples with validation results */
    
    /* TODO: Implement - returns SETOF validation_result */
    PG_RETURN_NULL();
}
```

**SQL Declaration**:
```sql
CREATE TYPE efm_extension.property_validation_result AS (
    property_name TEXT,
    is_valid BOOLEAN,
    message TEXT,
    severity TEXT  -- 'ERROR', 'WARNING', 'INFO'
);

CREATE FUNCTION efm_validate_properties()
    RETURNS SETOF efm_extension.property_validation_result
    SECURITY DEFINER
AS 'MODULE_PATHNAME', 'efm_validate_properties'
LANGUAGE C VOLATILE STRICT;

REVOKE ALL ON FUNCTION efm_validate_properties() FROM PUBLIC;
```

**Estimated Time**: 1 day

---

### 2.3 Populate Complete Property Registry

**Files to Edit**:
- `efm_extension.c` - Expand `efm_known_properties` array

**Implementation**:
Add all ~60 properties from EFM_OPTIONS_MATRIX.md to the registry with correct types, defaults, and constraints.

**Estimated Time**: 0.5 days

---

### 2.4 Create Regression Tests for Validation

**Files to Create**:
- `sql/03_validation.sql`
- `expected/03_validation.out`
- `test/test_properties/valid_minimal.properties`
- `test/test_properties/invalid_types.properties`

**Test Coverage**:
- Required properties missing → ERROR
- Invalid boolean values → ERROR
- Out-of-range integers → ERROR
- Invalid enum values → ERROR
- Valid configuration → SUCCESS
- Unknown properties → WARNING (pass-through)

**Estimated Time**: 1 day

---

## Phase 3: Documentation & Examples (Days 7-8)

### 3.1 Create Configuration Templates

**Files to Create**:
- `examples/minimal.properties` - Bare minimum config
- `examples/production.properties` - Production-ready setup
- `examples/ssl.properties` - SSL-enabled configuration
- `examples/witness.properties` - Witness node
- `examples/vip.properties` - Virtual IP setup
- `examples/README.md` - Explanation of examples

**Validation**:
Each template should pass `efm_validate_properties()` check.

**Estimated Time**: 0.5 days

---

### 3.2 Update Main README

**Files to Edit**:
- `README.md`

**Additions**:
- Supported EFM versions section
- Link to docs/ directory
- Link to examples/ directory
- Validation function usage
- Migration notes (if breaking changes)
- Updated usage examples

**Estimated Time**: 0.5 days

---

### 3.3 Create User Documentation

**Files to Create**:
- `docs/PROPERTIES_REFERENCE.md` - User-friendly property documentation
- `docs/TROUBLESHOOTING.md` - Common issues and solutions
- `docs/MIGRATION.md` - Upgrading guide
- `docs/CONTRIBUTING.md` - Development guide

**Estimated Time**: 1 day

---

## Phase 4: CI/CD & Security (Days 9-10)

### 4.1 Create GitHub Actions Workflow

**Files to Create**:
- `.github/workflows/ci.yml`

**Workflow Content**:
```yaml
name: CI

on: [push, pull_request]

jobs:
  test:
    strategy:
      matrix:
        pg_version: ['12', '13', '14', '15', '16', '17']
        os: ['ubuntu-22.04', 'ubuntu-24.04']
    
    runs-on: ${{ matrix.os }}
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Install PostgreSQL ${{ matrix.pg_version }}
        run: |
          sudo apt-get update
          sudo apt-get install -y postgresql-${{ matrix.pg_version }} \
            postgresql-server-dev-${{ matrix.pg_version }}
      
      - name: Build extension
        run: |
          export PG_CONFIG=/usr/lib/postgresql/${{ matrix.pg_version }}/bin/pg_config
          make clean
          make
      
      - name: Install extension
        run: |
          export PG_CONFIG=/usr/lib/postgresql/${{ matrix.pg_version }}/bin/pg_config
          sudo make install
      
      - name: Run tests
        run: |
          export PG_CONFIG=/usr/lib/postgresql/${{ matrix.pg_version }}/bin/pg_config
          make installcheck
      
      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: regression-results-pg${{ matrix.pg_version }}-${{ matrix.os }}
          path: regression.diffs
```

**Estimated Time**: 0.5 days

---

### 4.2 Add Security Scanning (CodeQL)

**Files to Create**:
- `.github/workflows/codeql.yml`

**Workflow Content**:
```yaml
name: CodeQL

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  analyze:
    runs-on: ubuntu-latest
    permissions:
      security-events: write
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Initialize CodeQL
        uses: github/codeql-action/init@v2
        with:
          languages: c
      
      - name: Build for analysis
        run: |
          sudo apt-get update
          sudo apt-get install -y postgresql-server-dev-16
          export PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
          make clean
          make
      
      - name: Perform CodeQL Analysis
        uses: github/codeql-action/analyze@v2
```

**Estimated Time**: 0.5 days

---

### 4.3 Security Review of Existing Code

**Focus Areas**:
1. **Command Injection**: Review `get_efm_command()` for shell metacharacter vulnerabilities
2. **Memory Safety**: Ensure all `palloc()` has corresponding `pfree()`
3. **Error Handling**: Check for leaked resources on error paths
4. **Input Validation**: Sanitize all user inputs before shell execution

**Files to Review**:
- `efm_extension.c` (entire file)

**Potential Fixes**:
```c
/* Instead of direct string concatenation, use parameterized approach */
static char *
get_efm_command_safe(char *efm_command, char *efm_argument)
{
    /* Validate inputs for shell metacharacters */
    if (contains_shell_metachar(efm_argument))
        elog(ERROR, "Invalid characters in argument");
    
    /* Rest of implementation */
}

static bool
contains_shell_metachar(const char *str)
{
    const char *dangerous = ";|&$`\\\"'<>()";
    return (strpbrk(str, dangerous) != NULL);
}
```

**Estimated Time**: 1 day

---

## Phase 5: Advanced Features (Days 11-12, Optional)

### 5.1 Add Missing EFM 4.0+ Properties

**Properties to Add** (from Gap Analysis):
- `db.data.dir`
- `jdbc.sslcert`, `jdbc.sslkey`, `jdbc.sslrootcert`
- `bind.interface`
- `notification.timeout`
- `stable.nodes.timeout`
- `virtualIp.single`
- `script.remote.pre.promotion`
- `log.file`
- `application.name`
- `reconfigure.num.sync`
- `use.replay.tiebreaker`

**Implementation**:
Add to `efm_known_properties` array with appropriate validators.

**Estimated Time**: 0.5 days

---

### 5.2 Path Validation Helpers

**Implementation**:
```c
/* Check if path exists and is readable */
static bool validate_path_file(const char *value, char **errmsg)
{
    struct stat st;
    
    if (stat(value, &st) != 0)
    {
        if (errmsg)
            *errmsg = psprintf("File does not exist: %s", value);
        return false;
    }
    
    if (!S_ISREG(st.st_mode))
    {
        if (errmsg)
            *errmsg = psprintf("Path is not a regular file: %s", value);
        return false;
    }
    
    /* Check readability */
    if (access(value, R_OK) != 0)
    {
        if (errmsg)
            *errmsg = psprintf("File is not readable: %s", value);
        return false;
    }
    
    return true;
}

/* Similar for directories, executables, etc. */
```

**Estimated Time**: 0.5 days

---

### 5.3 Improved Error Messages

**Enhancement**:
When validation fails, provide:
- What was wrong
- What was expected
- How to fix it
- Link to documentation

**Example**:
```
ERROR:  Property 'efm.loglevel' validation failed
DETAIL:  Value 'VERBOSE' is not valid. Must be one of: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
HINT:  See https://github.com/vibhorkum/efm_extension/blob/main/docs/PROPERTIES_REFERENCE.md#efm.loglevel
```

**Estimated Time**: 0.5 days

---

### 5.4 Strict Validation Mode (Optional)

**Implementation**:
Add GUC parameter:
```c
DefineCustomBoolVariable("efm.strict_validation",
                        "Enable strict property validation",
                        "When true, unknown properties cause errors instead of warnings",
                        &efm_strict_validation,
                        false, /* default: permissive */
                        PGC_SUSET,
                        0, NULL, NULL, NULL);
```

**Usage**:
```sql
SET efm.strict_validation = true;
SELECT * FROM efm_extension.efm_validate_properties();
-- Now unknown properties return ERROR severity
```

**Estimated Time**: 0.5 days

---

## Phase 6: Final Review & PR (Days 13-14)

### 6.1 Comprehensive Testing

**Tasks**:
- Run full regression test suite
- Test on all supported PostgreSQL versions (12-17)
- Test on different platforms (Ubuntu, RHEL, Debian if possible)
- Verify no memory leaks (valgrind)
- Performance baseline (parsing 1000-line properties file)

**Estimated Time**: 1 day

---

### 6.2 Code Review

**Use code_review tool**:
```
Run automated code review
Address all high-priority issues
Document any accepted technical debt
```

**Estimated Time**: 0.5 days

---

### 6.3 CodeQL Security Scan

**Use codeql_checker tool**:
```
Run CodeQL analysis
Fix all security vulnerabilities
Document any false positives
Create Security Summary
```

**Estimated Time**: 0.5 days

---

### 6.4 PR Preparation

**Tasks**:
1. Squash/organize commits logically:
   - docs: Add architecture, options matrix, gap analysis
   - fix: Correct properties view parsing
   - feat: Add property validation framework
   - feat: Add validation SQL function
   - test: Add comprehensive regression tests
   - docs: Add examples and user documentation
   - ci: Add GitHub Actions workflows
   - security: Fix command injection vulnerabilities

2. Write comprehensive PR description:
   - Summary of changes
   - Link to architecture docs
   - Link to options matrix
   - Link to gap analysis
   - Backward compatibility notes
   - Migration guide
   - Test results
   - How to review

3. Create release notes

**Estimated Time**: 0.5 days

---

## Summary

### Total Estimated Time: 10-14 days

**Phase Breakdown**:
- Phase 1 (Foundation): 3 days
- Phase 2 (Validation): 3 days
- Phase 3 (Documentation): 2 days
- Phase 4 (CI/Security): 2 days
- Phase 5 (Advanced): 2 days (optional)
- Phase 6 (Review/PR): 2 days

### Risk Mitigation

**Technical Risks**:
1. **Breaking Changes**: Mitigated by feature flags and migration guide
2. **Complex Validation Logic**: Mitigated by table-driven approach and comprehensive tests
3. **Memory Leaks**: Mitigated by careful review and valgrind testing
4. **Platform Incompatibility**: Mitigated by CI on multiple platforms

**Process Risks**:
1. **Scope Creep**: Stick to P0 and P1 items, defer P2 to follow-up PR
2. **Testing Coverage**: Aim for 80% minimum, document untested edge cases
3. **Documentation Lag**: Write docs alongside code, not after

### Success Metrics

- [ ] All P0 gaps closed
- [ ] 80%+ test coverage
- [ ] CI passing on PG 12-17
- [ ] Zero critical security issues
- [ ] All functions documented
- [ ] Migration path documented

---

## Files Manifest

### New Files (Created)
```
docs/
  ARCHITECTURE.md            [CREATED]
  EFM_OPTIONS_MATRIX.md      [CREATED]
  GAP_ANALYSIS.md            [CREATED]
  PROPERTIES_REFERENCE.md    [TO CREATE]
  TROUBLESHOOTING.md         [TO CREATE]
  MIGRATION.md               [TO CREATE]
  CONTRIBUTING.md            [TO CREATE]

examples/
  minimal.properties         [TO CREATE]
  production.properties      [TO CREATE]
  ssl.properties             [TO CREATE]
  witness.properties         [TO CREATE]
  vip.properties             [TO CREATE]
  README.md                  [TO CREATE]

sql/
  01_basic.sql               [TO CREATE]
  02_properties_parse.sql    [TO CREATE]
  03_validation.sql          [TO CREATE]
  04_errors.sql              [TO CREATE]

expected/
  01_basic.out               [TO CREATE]
  02_properties_parse.out    [TO CREATE]
  03_validation.out          [TO CREATE]
  04_errors.out              [TO CREATE]

test/test_properties/
  minimal.properties         [TO CREATE]
  full.properties            [TO CREATE]
  invalid.properties         [TO CREATE]
  valid_minimal.properties   [TO CREATE]
  invalid_types.properties   [TO CREATE]

.github/workflows/
  ci.yml                     [TO CREATE]
  codeql.yml                 [TO CREATE]
```

### Modified Files
```
efm_extension.c              [TO MODIFY - add validation framework]
efm_extension--1.0.sql       [TO MODIFY - fix view, add functions]
README.md                    [TO MODIFY - update docs]
.gitignore                   [TO CREATE/MODIFY - exclude build artifacts]
```

---

## Next Action

✅ **Ready to begin Phase 1: Foundation & Testing Infrastructure**

Start with:
1. Create `sql/` and `expected/` directories
2. Write basic extension test (`01_basic.sql`)
3. Fix properties view parsing bug
4. Verify tests pass with `make installcheck`

