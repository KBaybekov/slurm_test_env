# Stage 1: Build DEB packages
FROM ubuntu:24.04 as slurmbuild

ARG SLURM_VERSION

# Install any required system tools
RUN apt-get update && apt-get install -y \
    # Основные инструменты сборки
    bash-completion \
    build-essential \
    fakeroot \
    devscripts \
    dh-exec \
    equivs \
    git \
    wget \
    python3 \
    # Зависимости для сборки Slurm
    libgtk2.0-dev \
    libhwloc-dev \
    libhdf5-dev \
    libfreeipmi-dev \
    liblua5.3-dev \
    liblz4-dev \
    libmunge-dev \
    libmariadb-dev \
    libnuma-dev \
    libpam0g-dev \
    libperl-dev \
    libipmimonitoring-dev \
    libpmix-dev \
    librdkafka-dev \
    libreadline-dev \
    libhttp-parser-dev \
    libjson-c-dev \
    libyaml-dev \
    libjwt-dev \
    librrd-dev \
    libbpf-dev \
    libdbus-1-dev \
    # Системные зависимости
    man2html \
    freeipmi-tools \
    libibumad3 \
    # Менеджер пакетов Perl
    perl \
    # Очистка кеша
    && apt-get clean \
    && apt-get autoremove \
    && rm -rf /var/lib/apt/lists/*

COPY tmp/slurm-25.11.1 ./slurm-25.11.1/
# Build Slurm DEBs

# !!! revert to downloading & unpacking after testing !!!

#RUN wget https://download.schedmd.com/slurm/slurm-$SLURM_VERSION.tar.bz2 \
#    && tar -xaf slurm*tar.bz2 \
RUN cd slurm-$SLURM_VERSION \
    && mk-build-deps -i debian/control \
    && debuild -us -uc -b \
    && rm -rf slurm-$SLURM_VERSION.tar.bz2

# Stage 2: Runtime image
FROM ubuntu:24.04

ARG SLURM_VERSION

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    # General tools
    bats \
    grep \
    make \
    which \
    # Python versions available in Ubuntu 24.04
    python3.12 \
    # Required by Slurm
    mariadb-server \
    munge \
    # Required by the Slurm REST API
    libhttp-parser2.9 \
    libjwt-gnutls2 \
    libyaml-0-2 \
    libjson-c5 \
    # Additional Slurm dependencies
    libhwloc15 \
    libnuma1 \
    libpmix2 \
    libreadline8 \
    librrd8 \
    libbpf1 \
    libdbus-1-3 \
    libhdf5-103-1t64 \
    libfreeipmi17 \
    liblua5.4-0 \
    libmunge2 \
    libpam0g \
    && rm -rf /var/lib/apt/lists/*

# Install Slurm from DEB packages built in stage 1
COPY --from=slurmbuild /*.deb /tmp/
RUN dpkg -i /tmp/*.deb || true \
    && apt-get update \
    && apt-get install -f -y \
    && apt-get clean \
    && apt-get autoremove \
    && rm -rf /tmp/*.deb \
    && rm -rf /var/lib/apt/lists/*

# Configure mariadb
RUN mkdir -p /var/log/mysql \
    && mysql_install_db \
    && chown -R mysql:mysql /var/lib/mysql \
    && chown -R mysql:mysql /var/log/mysql

# Create Slurm user
RUN groupadd -r slurm && useradd -r -g slurm slurm

# Create config directory
RUN mkdir -p /etc/slurm /var/spool/slurmd \
    && chown slurm:slurm /var/spool/slurmd

# Add Slurm config files
COPY --chown=slurm slurm_config/$SLURM_VERSION/slurm.conf /etc/slurm/slurm.conf
COPY --chown=slurm --chmod=600 slurm_config/$SLURM_VERSION/slurmdbd.conf /etc/slurm/slurmdbd.conf

# Create Munge user
#RUN groupadd -r munge && useradd -r -g munge munge -s /sbin/nologin
# Change ownership of MUNGE files
RUN mkdir /run/munge/ \
    && chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge

# The entrypoint script starts the DB and defines necessary DB constructs
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
