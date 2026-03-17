# Dockerfile for efm_extension testing
# This builds PostgreSQL with the efm_extension and includes a mock EFM binary
# for testing without requiring a real EFM installation

ARG PG_VERSION=16
FROM postgres:${PG_VERSION}

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-${PG_MAJOR} \
    git \
    sudo \
    python3 \
    python3-pip \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create efm user for sudo testing
RUN useradd -m -s /bin/bash efm

# Create mock EFM directories
RUN mkdir -p /usr/edb/efm-4.9/bin /etc/edb/efm-4.9

# Copy extension source
WORKDIR /build/efm_extension
COPY . .

# Copy mock EFM binary
COPY docker/mock_efm.py /usr/edb/efm-4.9/bin/efm
RUN chmod +x /usr/edb/efm-4.9/bin/efm

# Create mock properties file
RUN echo "db.user=efm\n\
db.port=5432\n\
db.database=postgres\n\
auto.failover=true\n\
bind.address=172.17.0.2:5430\n\
is.witness=false" > /etc/edb/efm-4.9/efm.properties

# Setup sudo permissions for postgres user
RUN echo "postgres ALL=(efm) NOPASSWD: /usr/edb/efm-4.9/bin/efm" > /etc/sudoers.d/efm_postgres \
    && chmod 440 /etc/sudoers.d/efm_postgres

# Build and install extension
RUN make clean && make && make install

# Copy test scripts
COPY docker/tests/ /tests/
RUN chmod +x /tests/*.sh

# Configure PostgreSQL for testing
RUN echo "shared_preload_libraries = 'efm_extension'" >> /usr/share/postgresql/postgresql.conf.sample
RUN echo "efm.cluster_name = 'efm'" >> /usr/share/postgresql/postgresql.conf.sample
RUN echo "efm.command_path = '/usr/edb/efm-4.9/bin/efm'" >> /usr/share/postgresql/postgresql.conf.sample
RUN echo "efm.properties_location = '/etc/edb/efm-4.9'" >> /usr/share/postgresql/postgresql.conf.sample
RUN echo "efm.cache_ttl = 5" >> /usr/share/postgresql/postgresql.conf.sample

# Health check
HEALTHCHECK --interval=5s --timeout=5s --start-period=10s \
    CMD pg_isready -U postgres || exit 1

# Default command runs PostgreSQL
CMD ["postgres"]
