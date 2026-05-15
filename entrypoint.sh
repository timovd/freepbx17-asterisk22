#!/usr/bin/env bash
set -euo pipefail

: "${DB_HOST:=mariadb}"
: "${DB_PORT:=3306}"
: "${DB_NAME:=asterisk}"
: "${DB_CDR_NAME:=asteriskcdrdb}"
: "${DB_USER:=freepbx}"
: "${DB_PASSWORD:=freepbxpass}"
: "${DB_ROOT_PASSWORD:=rootpass}"
: "${FREEPBX_ADMIN_USER:=admin}"
: "${FREEPBX_ADMIN_PASSWORD:=changeme-admin}"
: "${FREEPBX_ADMIN_EMAIL:=admin@example.invalid}"
: "${SERVER_NAME:=localhost}"
: "${REDIS_HOST:=redis}"
: "${REDIS_PORT:=6379}"
: "${POSTFIX_MYHOSTNAME:=freepbx.localdomain}"
: "${POSTFIX_RELAYHOST:=}"
: "${POSTFIX_SMTP_USER:=}"
: "${POSTFIX_SMTP_PASSWORD:=}"
: "${POSTFIX_FROM_ADDRESS:=}"

wait_for_tcp() {
  local host="$1" port="$2" name="$3"
  until nc -z "$host" "$port" >/dev/null 2>&1; do
    echo "Waiting for ${name} at ${host}:${port} ..."
    sleep 2
  done
}

render_apache() {
  export SERVER_NAME
  envsubst '${SERVER_NAME}' < /etc/apache2/sites-available/freepbx.conf.template > /etc/apache2/sites-available/freepbx.conf
  a2ensite freepbx.conf >/dev/null
}

configure_odbc() {
  sed -i "s/^Server *=.*/Server = ${DB_HOST}/" /etc/odbc.ini
  sed -i "s/^Database *=.*/Database = ${DB_CDR_NAME}/" /etc/odbc.ini
  sed -i "s/^Port *=.*/Port = ${DB_PORT}/" /etc/odbc.ini
  sed -i "s/^UserName *=.*/UserName = ${DB_USER}/" /etc/odbc.ini
  sed -i "s/^Password *=.*/Password = ${DB_PASSWORD}/" /etc/odbc.ini
}

configure_postfix() {
  postconf -e "myhostname = ${POSTFIX_MYHOSTNAME}"
  postconf -e "inet_interfaces = loopback-only"
  postconf -e "mydestination = localhost"
  if [[ -n "${POSTFIX_RELAYHOST}" ]]; then
    postconf -e "relayhost = ${POSTFIX_RELAYHOST}"
  fi
  if [[ -n "${POSTFIX_SMTP_USER}" && -n "${POSTFIX_SMTP_PASSWORD}" && -n "${POSTFIX_RELAYHOST}" ]]; then
    cat > /etc/postfix/sasl_passwd <<SASL
${POSTFIX_RELAYHOST} ${POSTFIX_SMTP_USER}:${POSTFIX_SMTP_PASSWORD}
SASL
    chmod 600 /etc/postfix/sasl_passwd
    postmap hash:/etc/postfix/sasl_passwd
    postconf -e 'smtp_sasl_auth_enable = yes'
    postconf -e 'smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd'
    postconf -e 'smtp_sasl_security_options = noanonymous'
    postconf -e 'smtp_tls_security_level = may'
  fi
  if [[ -n "${POSTFIX_FROM_ADDRESS}" ]]; then
    cat > /etc/postfix/generic <<GENERIC
root ${POSTFIX_FROM_ADDRESS}
root@localhost ${POSTFIX_FROM_ADDRESS}
asterisk ${POSTFIX_FROM_ADDRESS}
asterisk@localhost ${POSTFIX_FROM_ADDRESS}
vm@asterisk ${POSTFIX_FROM_ADDRESS}
@freepbx.localdomain ${POSTFIX_FROM_ADDRESS}
GENERIC
    postmap /etc/postfix/generic
    postconf -e 'smtp_generic_maps = hash:/etc/postfix/generic'
  fi
}

configure_redis_php() {
  if nc -z "${REDIS_HOST}" "${REDIS_PORT}" >/dev/null 2>&1; then
    cat > /etc/php/8.2/mods-available/redis-session.ini <<REDIS
session.save_handler = redis
session.save_path = "tcp://${REDIS_HOST}:${REDIS_PORT}?persistent=1&weight=1&timeout=2.5"
REDIS
    phpenmod redis redis-session || true
  fi
}

write_supervisor() {
  cat > /etc/supervisor/supervisord.conf <<'SUPERVISOR'
[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:rsyslog]
command=/usr/sbin/rsyslogd -n
autostart=true
autorestart=true
priority=5
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:postfix]
command=/bin/bash -lc "postfix start-fg"
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:apache2]
command=/usr/sbin/apachectl -DFOREGROUND
autostart=true
autorestart=true
priority=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:asterisk]
command=/usr/sbin/asterisk -f -U asterisk -G asterisk
autostart=true
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
SUPERVISOR
}

install_freepbx_once() {
  if [[ ! -f /etc/freepbx.conf && -f /var/lib/asterisk/freepbx.conf.persist ]]; then
    cp /var/lib/asterisk/freepbx.conf.persist /etc/freepbx.conf
  fi

  if [[ -f /etc/freepbx.conf && -x /usr/sbin/fwconsole ]]; then
    echo "FreePBX already installed; skipping installer."
    return
  fi

  echo "Initializing databases..."
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`${DB_CDR_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_CDR_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

  chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/www/html /run/asterisk
  sudo -u asterisk /usr/sbin/asterisk -U asterisk -G asterisk || true
  sleep 5

  cd /usr/src/freepbx
  ./start_asterisk start || true
  ./install -n \
    --dbhost="${DB_HOST}" \
    --dbport="${DB_PORT}" \
    --dbname="${DB_NAME}" \
    --cdrdbname="${DB_CDR_NAME}" \
    --dbuser="${DB_USER}" \
    --dbpass="${DB_PASSWORD}" \
    --webroot=/var/www/html

  fwconsole setting MODULE_REPO http://mirror.freepbx.org || true
  fwconsole ma installall || true
  fwconsole reload || true
  fwconsole setting AMPWEBADDRESS "${SERVER_NAME}" || true
  fwconsole admin --username "${FREEPBX_ADMIN_USER}" --password "${FREEPBX_ADMIN_PASSWORD}" --email "${FREEPBX_ADMIN_EMAIL}" || true
  cp /etc/freepbx.conf /var/lib/asterisk/freepbx.conf.persist || true
  fwconsole stop || true
}

wait_for_tcp "${DB_HOST}" "${DB_PORT}" "MariaDB"
wait_for_tcp "${REDIS_HOST}" "${REDIS_PORT}" "Redis"
render_apache
configure_odbc
configure_postfix
configure_redis_php
install_freepbx_once
write_supervisor

exec "$@"
