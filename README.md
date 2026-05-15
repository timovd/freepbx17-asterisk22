```
 ______             _____  ______   __
|  ____|           |  __ \|  _ \ \ / /
| |__ _ __ ___  ___| |__) | |_) \ V /
|  __| '__/ _ \/ _ \  ___/|  _ < > <
| |  | | |  __/  __/ |    | |_) / . \
|_|  |_|  \___|\___|_|    |____/_/ \_\
Your Open Source Asterisk PBX GUI Solution
```

# FreePBX 17 + Asterisk 22.9.0 on Debian 12 Docker

This project builds a Debian 12 Bookworm image with Asterisk `22.9.0` compiled from the official upstream tarball and FreePBX `17.0-latest` downloaded from the FreePBX package mirror. MariaDB runs as a supported `10.11` service, Redis is provided for PHP session caching, Postfix is preconfigured at container startup, and Fail2ban runs as a sidecar sharing the FreePBX network namespace.

## Build and start

```bash
docker compose build
docker compose up -d
```

Open FreePBX at `http://localhost:8080`.

Default credentials are controlled by environment variables in `docker-compose.yaml`:

- `FREEPBX_ADMIN_USER=admin`
- `FREEPBX_ADMIN_PASSWORD=changeme-admin`
- `FREEPBX_ADMIN_EMAIL=admin@example.invalid`

Change these before first startup.

## Versions

- Debian: 12 Bookworm
- Asterisk: `22.9.0` from `https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz`
- FreePBX: `17.0-latest` from `http://mirror.freepbx.org/modules/packages/freepbx/freepbx-${FREEPBX_VERSION}.tgz`
- MariaDB: `10.11`
- PHP: `8.2`
- Redis: `redis:7-bookworm`

## Postfix relay setup

Set these variables in `docker-compose.yaml` when you need outbound SMTP relay authentication:

```yaml
POSTFIX_RELAYHOST: "[smtp.example.com]:587"
POSTFIX_SMTP_USER: "smtp-user"
POSTFIX_SMTP_PASSWORD: "smtp-password"
POSTFIX_FROM_ADDRESS: "pbx@example.com"
```

The entrypoint writes `/etc/postfix/sasl_passwd`, runs `postmap`, enables SMTP SASL auth, and optionally writes `/etc/postfix/generic` to rewrite sender addresses.

## RTP range

This compose file exposes UDP `10000-10100` as a small default RTP range. For production, align this with FreePBX/Asterisk RTP settings and expand it as needed.

## Fail2ban sidecar

Fail2ban uses `network_mode: service:freepbx`, so its iptables rules are applied in the FreePBX container network namespace. It reads `/var/log/asterisk/security` and `/var/log/asterisk/full` from the shared `freepbx_log` volume.

## Caveats

Running a PBX in Docker is sensitive to NAT, RTP port ranges, kernel capabilities, and persistent volumes. For production, pin every image by digest, use real secrets, configure TLS, restrict management access, and validate SIP/RTP behavior with your carrier.
