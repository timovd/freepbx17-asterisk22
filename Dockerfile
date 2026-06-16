# syntax=docker/dockerfile:1.7
FROM debian:12-slim

ARG ASTERISK_VERSION=22.10.0
ARG FREEPBX_VERSION=17.0-latest
ARG DEBIAN_FRONTEND=noninteractive

ENV ASTERISK_VERSION=${ASTERISK_VERSION} \
    FREEPBX_VERSION=${FREEPBX_VERSION} \
    FREEPBX_SRC=/usr/src/freepbx \
    ASTERISK_USER=asterisk \
    ASTERISK_GROUP=asterisk \
    APACHE_RUN_USER=asterisk \
    APACHE_RUN_GROUP=asterisk \
    PHP_VERSION=8.2

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release locales tzdata tini supervisor \
    build-essential autoconf automake bison flex libtool libtool-bin pkg-config subversion git \
    libasound2-dev libbluetooth-dev libc-client-dev libcurl4-openssl-dev libedit-dev libical-dev \
    libiksemel-dev libjansson-dev libldap2-dev liblua5.2-dev libncurses5-dev libneon27-dev \
    libnewt-dev libogg-dev libopus-dev libpopt-dev libresample1-dev libsrtp2-dev libspandsp-dev \
    libspeex-dev libspeexdsp-dev libsqlite3-dev libssl-dev libtiff-dev liburiparser-dev \
    libvorbis-dev libxml2-dev libxslt1-dev uuid-dev unixodbc unixodbc-dev odbc-mariadb \
    default-libmysqlclient-dev mariadb-client \
    apache2 \
    php8.2 libapache2-mod-php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-gd php8.2-intl php8.2-mbstring \
    php8.2-mysql php8.2-soap php8.2-xml php8.2-zip php8.2-bcmath php8.2-ldap php8.2-redis \
    php-pear nodejs npm \
    postfix mailutils libsasl2-modules rsyslog logrotate cron sudo vim gettext-base netcat-openbsd procps \
    sox mpg123 lame ffmpeg sqlite3 iproute2 iputils-ping dnsutils \
 && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Users/groups used by FreePBX and Asterisk.
RUN groupadd -r asterisk \
 && useradd -r -g asterisk -d /var/lib/asterisk -s /usr/sbin/nologin asterisk \
 && usermod -aG audio,dialout,www-data asterisk

# Compile Asterisk from the exact upstream tarball requested.
RUN mkdir -p /usr/src/asterisk-build \
 && cd /usr/src/asterisk-build \
 && wget -O asterisk.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz" \
 && tar xzf asterisk.tar.gz --strip-components=1 \
 && contrib/scripts/get_mp3_source.sh \
 && ./configure --with-pjproject-bundled --with-jansson-bundled \
 && make menuselect.makeopts \
 && menuselect/menuselect --enable CORE-SOUNDS-EN-WAV --enable MOH-OPSOUND-WAV --enable EXTRA-SOUNDS-EN-WAV menuselect.makeopts \
 && make -j"$(nproc)" \
 && make install \
 && make samples \
 && sed -i 's/^;runuser = .*/runuser = asterisk/' /etc/asterisk/asterisk.conf \
 && sed -i 's/^;rungroup = .*/rungroup = asterisk/' /etc/asterisk/asterisk.conf \
 && ldconfig \
 && cd / \
 && rm -rf /usr/src/asterisk-build

# Download FreePBX release tarball requested. Installation happens at runtime after MariaDB is reachable.
RUN mkdir -p /usr/src \
 && wget -O /tmp/freepbx.tgz "http://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}.tgz" \
 && mkdir -p "${FREEPBX_SRC}" \
 && tar xzf /tmp/freepbx.tgz -C "${FREEPBX_SRC}" --strip-components=1 \
 && rm -f /tmp/freepbx.tgz

COPY apache/freepbx.conf.template /etc/apache2/sites-available/freepbx.conf.template
COPY odbc/odbc.ini /etc/odbc.ini
COPY odbc/odbcinst.ini /etc/odbcinst.ini
COPY logrotate/asterisk /etc/logrotate.d/asterisk
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
 && a2enmod rewrite headers expires \
 && a2dissite 000-default.conf \
 && sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 120M/' /etc/php/8.2/apache2/php.ini \
 && sed -i 's/^post_max_size = .*/post_max_size = 120M/' /etc/php/8.2/apache2/php.ini \
 && sed -i 's/^memory_limit = .*/memory_limit = 512M/' /etc/php/8.2/apache2/php.ini \
 && sed -i 's/^max_execution_time = .*/max_execution_time = 300/' /etc/php/8.2/apache2/php.ini \
 && sed -i 's/^User .*/User asterisk/' /etc/apache2/apache2.conf \
 && sed -i 's/^Group .*/Group asterisk/' /etc/apache2/apache2.conf \
 && mkdir -p /run/apache2 /run/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/www/html \
 && chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/www/html /run/asterisk \
 && chown -R asterisk:asterisk /usr/lib/asterisk || true

VOLUME ["/etc/asterisk", "/var/lib/asterisk", "/var/log/asterisk", "/var/spool/asterisk", "/var/www/html"]

EXPOSE 80 443 5060/tcp 5060/udp 5061/tcp 5061/udp 5160/udp 5161/udp 10000-10100/udp

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
