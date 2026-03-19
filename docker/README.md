# Docker Testing for efm_extension

This directory contains Docker configurations for testing the efm_extension with both a mock EFM and real EDB Failover Manager.

## Quick Start

### Option 1: Mock EFM (No subscription required)

Use this for basic testing without an EDB subscription:

```bash
# Build and start
docker-compose build
docker-compose up -d

# Run all tests
docker-compose exec postgres /tests/run_all_tests.sh

# Run specific tests
docker-compose exec postgres /tests/test_efm_down.sh
docker-compose exec postgres /tests/test_input_validation.sh

# Stop and cleanup
docker-compose down -v
```

### Option 2: Real EFM (Requires EDB subscription)

Use this for integration testing with actual EDB Failover Manager:

```bash
# Set your EDB subscription token
export EDB_SUBSCRIPTION_TOKEN=your_token_here

# Optional: Set versions
export PG_VERSION=16
export EFM_VERSION=4.9

# Build and start
docker-compose -f docker-compose.edb.yml build
docker-compose -f docker-compose.edb.yml up -d

# Wait for EFM to initialize (takes ~60 seconds)
docker-compose -f docker-compose.edb.yml logs -f

# Run tests
docker-compose -f docker-compose.edb.yml exec postgres /tests/run_all_tests.sh

# Stop and cleanup
docker-compose -f docker-compose.edb.yml down -v
```

## Getting an EDB Subscription Token

1. Go to [EDB Repos 2.0](https://www.enterprisedb.com/repos-downloads)
2. Sign in or create an EDB account
3. Select your subscription level
4. Copy your repository token

The token format looks like: `XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX`

## File Structure

```
docker/
├── Dockerfile              # Mock EFM testing (no subscription needed)
├── Dockerfile.edb          # Real EFM testing (requires subscription)
├── docker-compose.yml      # Compose for mock EFM
├── docker-compose.edb.yml  # Compose for real EFM
├── mock_efm.py             # Mock EFM binary (Python script)
├── efm.properties.template # EFM config template for real EFM
├── init-efm.sh             # EFM initialization script
├── README.md               # This file
└── tests/
    ├── run_all_tests.sh         # Complete test suite
    ├── test_efm_down.sh         # EFM unavailability tests
    └── test_input_validation.sh # Security validation tests
```

## Test Scenarios

### Mock EFM Modes

The mock EFM supports different modes via environment variables:

| Mode | Description |
|------|-------------|
| `normal` | EFM responds normally (default) |
| `down` | EFM agent appears to be down |
| `timeout` | EFM commands hang (for timeout testing) |
| `error` | EFM returns error responses |

Example:
```bash
# Test with EFM appearing down
docker-compose run -e MOCK_EFM_MODE=down postgres /tests/test_efm_down.sh
```

### Test Categories

| Test | Description |
|------|-------------|
| `run_all_tests.sh` | Full test suite covering all functionality |
| `test_efm_down.sh` | Verifies PostgreSQL remains stable when EFM is unavailable |
| `test_input_validation.sh` | Tests IP validation, priority validation, injection prevention |

## Building Custom Images

### With Mock EFM

```bash
docker build -f Dockerfile \
  --build-arg PG_VERSION=16 \
  -t efm_extension_test:mock .
```

### With Real EFM

```bash
docker build -f Dockerfile.edb \
  --build-arg EDB_SUBSCRIPTION_TOKEN=your_token \
  --build-arg PG_VERSION=16 \
  --build-arg EFM_VERSION=4.9 \
  -t efm_extension_test:edb .
```

## Connecting to Test Containers

```bash
# Connect via psql
psql -h localhost -p 5433 -U postgres -d testdb

# Or exec into container
docker-compose exec postgres psql -U postgres -d testdb
```

## Troubleshooting

### Build fails with "EDB_SUBSCRIPTION_TOKEN is required"

Make sure you've exported your token:
```bash
export EDB_SUBSCRIPTION_TOKEN=your_token_here
```

### EFM fails to start in real EFM container

Check the logs:
```bash
docker-compose -f docker-compose.edb.yml logs postgres
```

Common issues:
- Invalid subscription token
- Network connectivity to EDB repos
- Missing Java (should be installed automatically)

### Tests fail with "permission denied"

Ensure test scripts are executable:
```bash
chmod +x docker/tests/*.sh
```

### PostgreSQL not ready

The EDB container takes longer to initialize (~60 seconds). Wait for the health check:
```bash
docker-compose -f docker-compose.edb.yml ps
# Wait until STATUS shows "healthy"
```

## Environment Variables

### Mock EFM Container

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_PASSWORD` | postgres | PostgreSQL superuser password |
| `POSTGRES_DB` | testdb | Default database |
| `MOCK_EFM_MODE` | normal | Mock EFM behavior mode |
| `MOCK_EFM_DELAY` | 0 | Delay in seconds before EFM responds |

### Real EFM Container

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_PASSWORD` | postgres | PostgreSQL superuser password |
| `POSTGRES_DB` | testdb | Default database |
| `EFM_DB_PASSWORD` | efm_password | Password for EFM database user |
| `EFM_CLUSTER_NAME` | efm | EFM cluster name |
| `BIND_ADDRESS` | auto-detected | IP address for EFM binding |

## CI/CD Integration

### GitHub Actions Example

```yaml
jobs:
  test-mock:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build and test with mock EFM
        run: |
          cd docker
          docker-compose build
          docker-compose up -d
          sleep 10
          docker-compose exec -T postgres /tests/run_all_tests.sh
          docker-compose down -v

  test-real-efm:
    runs-on: ubuntu-latest
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - name: Build and test with real EFM
        env:
          EDB_SUBSCRIPTION_TOKEN: ${{ secrets.EDB_SUBSCRIPTION_TOKEN }}
        run: |
          cd docker
          docker-compose -f docker-compose.edb.yml build
          docker-compose -f docker-compose.edb.yml up -d
          sleep 60
          docker-compose -f docker-compose.edb.yml exec -T postgres /tests/run_all_tests.sh
          docker-compose -f docker-compose.edb.yml down -v
```

### GitLab CI Example

```yaml
test-mock:
  stage: test
  script:
    - cd docker
    - docker-compose build
    - docker-compose up -d
    - sleep 10
    - docker-compose exec -T postgres /tests/run_all_tests.sh
  after_script:
    - docker-compose down -v

test-real-efm:
  stage: test
  only:
    - main
  variables:
    EDB_SUBSCRIPTION_TOKEN: $EDB_SUBSCRIPTION_TOKEN
  script:
    - cd docker
    - docker-compose -f docker-compose.edb.yml build
    - docker-compose -f docker-compose.edb.yml up -d
    - sleep 60
    - docker-compose -f docker-compose.edb.yml exec -T postgres /tests/run_all_tests.sh
  after_script:
    - docker-compose -f docker-compose.edb.yml down -v
```
