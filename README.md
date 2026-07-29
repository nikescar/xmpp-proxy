
<h1 align="center">
  <br>
  <img src="https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/master/contrib/logo/xmpp_proxy_color.png" alt="logo" width="200">
  <br>
  xmpp-proxy
  <br>
  <br>
</h1>

[![Build Status](https://ci.moparisthe.best/job/moparisthebest/job/xmpp-proxy/job/master/badge/icon%3Fstyle=plastic)](https://ci.moparisthe.best/job/moparisthebest/job/xmpp-proxy/job/master/)

xmpp-proxy is a reverse proxy and outgoing proxy for XMPP servers and clients, providing [STARTTLS], [Direct TLS], [QUIC],
[WebSocket C2S], [WebSocket S2S], and [WebTransport] connectivity to plain-text XMPP servers and clients and limiting stanza sizes without an XML parser.

xmpp-proxy in reverse proxy (incoming) mode will:
  1. listen on any number of interfaces/ports
  2. accept any STARTTLS, Direct TLS, QUIC, WebSocket, or WebTransport c2s or s2s connections from the internet
  3. terminate TLS
  4. for s2s require a client cert and validate it correctly (using CAs, host-meta, host-meta2, and POSH) for SASL EXTERNAL auth
  5. connect them to a local real XMPP server over plain-text TCP
  6. send the [PROXY protocol] v1 header if configured, so the XMPP server knows the real client IP
  7. limit incoming stanza sizes as configured

xmpp-proxy in outgoing mode will:
  1. listen on any number of interfaces/ports
  2. accept any plain-text TCP or WebSocket connection from a local XMPP server or client
  3. look up the required SRV, [host-meta], [host-meta2], and [POSH] records
  4. connect to a real XMPP server across the internet over STARTTLS, Direct TLS, QUIC, WebSocket, or WebTransport
  5. fallback to next SRV target or defaults as required to fully connect
  6. perform all the proper required certificate validation logic
  7. limit incoming stanza sizes as configured

#### Installation
  * `cargo install xmpp-proxy`
  * Download static binary from [xmpp-proxy](https://code.moparisthebest.com/moparisthebest/xmpp-proxy/releases)
    or [xmpp-proxy (github mirror)](https://github.com/moparisthebest/xmpp-proxy/releases)
  * your favorite package manager

#### Configuration
  * `mkdir /etc/xmpp-proxy/ && cp xmpp-proxy.toml /etc/xmpp-proxy/`
  * edit `/etc/xmpp-proxy/xmpp-proxy.toml` as needed, file is annotated clearly with comments
  * put your TLS key/cert in `/etc/xmpp-proxy/`
  * Example systemd unit is provided in xmpp-proxy.service and locks it down with bare minimum permissions.  Need to
    set the permissions correctly: `chown -Rv 'systemd-network:' /etc/xmpp-proxy/`
  * start xmpp-proxy: `Usage: xmpp-proxy [/path/to/xmpp-proxy.toml (default /etc/xmpp-proxy/xmpp-proxy.toml]`

#### How do I adapt my running Prosody config to use this instead?

You have 2 options here, use xmpp-proxy as only a reverse proxy, or as both reverse and outgoing proxy, I'll cover both:

###### Reverse proxy and outgoing proxy

In this mode both prosody doesn't need to do any TLS at all, so it needs no certs. xmpp-proxy need proper TLS
certificates, move prosody's TLS key to `/etc/xmpp-proxy/le.key` and TLS cert to `/etc/xmpp-proxy/fullchain.cer`, and
use the provided `xmpp-proxy.toml` configuration as-is.

Edit `/etc/prosody/prosody.cfg.lua`, Add this to modules_enabled:
```
"net_proxy";
```
Until prosody-modules is updated, use my fork [mod_net_proxy.lua](https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/refs/heads/master/contrib/prosody-modules/mod_net_proxy.lua).

Add this config:
```
-- only need to listen on localhost
interfaces = { "127.0.0.1" }

-- we don't need prosody doing any encryption, xmpp-proxy does this now
-- these are likely set to true somewhere in your file, find them, make them false
-- you can also remove all certificates from your config
s2s_require_encryption = false
s2s_secure_auth = false
c2s_require_encryption = false
allow_unencrypted_plain_auth = true

-- xmpp-proxy outgoing is listening on this port, make all outgoing s2s connections directly to here
proxy_out = { "127.0.0.1", 15270 }
-- mark connections to/from proxy as secure, xmpp-proxy guarantees this
proxy_secure = true

-- handle PROXY protocol on these ports
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- don't listen on any normal c2s/s2s ports (xmpp-proxy listens on these now)
-- you might need to comment these out further down in your config file if you set them
c2s_ports = {}
legacy_ssl_ports = {}
-- you MUST have at least one s2s_ports defined if you want outgoing S2S to work, don't ask.. 
s2s_ports = {15268}
```

###### Reverse proxy only, prosody makes outgoing connections directly itself

In this mode both prosody and xmpp-proxy need proper TLS certificates, copy prosody's TLS key to `/etc/xmpp-proxy/le.key`
and TLS cert to `/etc/xmpp-proxy/fullchain.cer`, and use the provided `xmpp-proxy.toml` configuration as-is.

Edit `/etc/prosody/prosody.cfg.lua`, Add these to modules_enabled:
```
"net_proxy";
```
Until prosody-modules is updated, use my fork [mod_net_proxy.lua](https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/refs/heads/master/contrib/prosody-modules/mod_net_proxy.lua).

Add this config:
```
-- mark connections from proxy as secure, xmpp-proxy guarantees this
proxy_secure_in = true

-- handle PROXY protocol on these ports
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- don't listen on any normal c2s/s2s ports (xmpp-proxy listens on these now)
-- you might need to comment these out further down in your config file if you set them
c2s_ports = {}
legacy_ssl_ports = {}
-- you MUST have at least one s2s_ports defined if you want outgoing S2S to work, don't ask.. 
s2s_ports = {15268}
```

#### Customize the build

If you are a grumpy power user who wants to build xmpp-proxy with exactly the features you want, nothing less, nothing
more, this section is for you!

xmpp-proxy has multiple compile-time features, some of which are required, they are grouped as such:

choose between 1-4 directions:
  1. `c2s-incoming` - enables a server to accept incoming c2s connections
  2. `c2s-outgoing` - enables a client to make outgoing c2s connections
  3. `s2s-incoming` - enables a server to accept incoming s2s connections
  4. `s2s-outgoing` - enables a server to make outgoing s2s connections

choose between 1-4 transport protocols:
  1. `tls` - enables STARTTLS/TLS support
  2. `quic` - enables QUIC support
  3. `websocket` - enables WebSocket support, also enables TLS incoming support if the appropriate directions are enabled
  4. `webtransport` - enables WebTransport support, also enables QUIC

choose exactly 1 of these methods to get trusted CA roots, not needed if only `c2s-incoming` is enabled:
  1. `tls-ca-roots-native` - reads CA roots from operating system
  2. `tls-ca-roots-bundled` - bundles CA roots into the binary from the `webpki-roots` project

choose any of these optional features:
  1. `logging` - enables configurable logging

So to build only supporting reverse proxy STARTTLS/TLS, no QUIC, run: `cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls`
To build a reverse proxy only, but supporting all of STARTTLS/TLS/QUIC, run: `cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls,quic`

#### Development

1. `check-all-features.sh` is used to check compilation with all supported feature permutations
2. `integration/test.sh` uses [Rootless podman](https://wiki.archlinux.org/title/Podman#Rootless_Podman) to run many tests
    through xmpp-proxy on a real network with real dns, web, and xmpp servers, all of these should pass before pushing commits,
    and write new tests to cover new functionality.
3. To submit code changes submit a PR on [github](https://github.com/moparisthebest/xmpp-proxy) or
   [code.moparisthebest.com](https://code.moparisthebest.com/moparisthebest/xmpp-proxy) or send me a patch via email,
   XMPP, fediverse, or carrier pigeon.

#### Docker Compose Deployment

A complete Docker Compose stack is included that provides:
  * **Prosody XMPP server** (prosodyim/prosody:13.0) with MAM, carbons, and web admin enabled
  * **xmpp-proxy** (reverse proxy and outgoing proxy for STARTTLS/TLS/QUIC/WebSocket support)
  * **nginx** (ACME HTTP-01 challenge handling for Let's Encrypt)
  * **fail2ban-rs** (rate limiting and abuse protection)
  * **supervisord** (process management for the proxy stack)
  * Automatic TLS certificate management with acmetool
  * PROXY protocol support for preserving client IPs
  * WebSocket support on port 5280
  * Full backup and restore scripts

###### Quick Start

1. Copy the example environment file and edit it:
   ```
   cp .env.example .env
   nano .env
   ```
   Set at minimum: `XMPP_DOMAIN`, `ACME_EMAIL`

2. Start the stack:
   ```
   docker compose up -d
   ```

3. The stack exposes:
   * `5222/tcp` - XMPP C2S (STARTTLS)
   * `5223/tcp` - XMPP C2S (Direct TLS)
   * `5269/tcp` - XMPP S2S (Server-to-Server)
   * `443/udp` - XMPP over QUIC
   * `5280/tcp` - HTTP/WebSocket (for BOSH and WebSocket clients)
   * `80/tcp` - HTTP (ACME challenge only)

4. Data persists in `/srv/xmpp/`:
   * `prosody/` - Prosody data (accounts, messages, etc.)
   * `certs/` - TLS certificates
   * `logs/` - All service logs
   * `fail2ban/` - fail2ban-rs database
   * `acme/` - acmetool state

5. Backup and restore:
   ```
   ./scripts/backup.sh      # Creates timestamped backup in /srv/xmpp/backups/
   ./scripts/restore.sh /path/to/backup.tar.gz
   ```

###### Architecture

The Docker deployment uses two containers:
  * **prosody** - Runs Prosody XMPP server on localhost-only ports with PROXY protocol support enabled
  * **xmpp-proxy-stack** - Bundles xmpp-proxy, nginx, fail2ban-rs, and supervisord using host networking for PROXY protocol support

Prosody listens on localhost:15222 (C2S) and localhost:15269 (S2S). xmpp-proxy terminates TLS on the public ports, sends the PROXY protocol header, and forwards to Prosody. This preserves the real client IP for logging and rate limiting.

###### Customization

Put local overrides in `docker-compose.override.yaml` (see `docker-compose.override.yaml.example`). Common customizations:
  * Change Prosody modules: set `PROSODY_ENABLE_MODULES` in `.env`
  * Adjust log levels: `PROSODY_LOGLEVEL`, `XMPP_PROXY_LOG_LEVEL`
  * Change data paths: modify volume mounts in override file
  * Add custom Prosody modules: drop them in `./prosody-modules/` directory

####  License
GNU/AGPLv3 - Check LICENSE.md for details

Thanks [rxml](https://github.com/horazont/rxml) for afl-fuzz seeds

#### Todo
  1. seamless Tor integration, connecting to and from .onion domains
  2. Write WebTransport XEP
  3. Document systemd activation support
  4. Document use-as-a-library support

[STARTTLS]: https://datatracker.ietf.org/doc/html/rfc6120#section-5
[Direct TLS]: https://xmpp.org/extensions/xep-0368.html
[QUIC]: https://xmpp.org/extensions/xep-0467.html
[WebSocket C2S]: https://datatracker.ietf.org/doc/html/rfc7395
[WebSocket S2S]: https://xmpp.org/extensions/xep-0468.html
[WebTransport]: https://www.w3.org/TR/webtransport/
[POSH]: https://datatracker.ietf.org/doc/html/rfc7711
[host-meta]: https://xmpp.org/extensions/xep-0156.html
[host-meta2]: https://xmpp.org/extensions/inbox/host-meta-2.html
[PROXY protocol]: https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt

## Distroless Deployment (Recommended)

The xmpp-proxy-stack now uses a hardened distroless base image for improved security.

### Features

- **Minimal Attack Surface**: Based on `gcr.io/distroless/base-debian13` with no shell or package manager
- **Process Supervision**: Horust manages nginx, xmpp-proxy, fail2ban-rs, and acme.sh
- **Automated Certificates**: acme.sh handles SSL/TLS certificate acquisition and renewal
- **Dynamic Proxying**: nginx-proxy-ctl CLI for adding/removing reverse proxy configurations at runtime

### Quick Start

1. Configure environment variables:
```bash
cp .env.example .env
nano .env  # Set XMPP_DOMAIN and ACME_EMAIL
```

2. Build and start:
```bash
docker-compose build xmpp-proxy-stack
docker-compose up -d
```

3. Verify services:
```bash
docker logs xmpp-proxy-stack
docker exec xmpp-proxy-stack /bin/busybox ps aux
```

### Dynamic Nginx Proxy Configuration

Add HTTP/HTTPS reverse proxy locations dynamically:

```bash
# Add a proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://backend:8000/

# Add with WebSocket support
docker exec xmpp-proxy-stack nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket

# List all proxies
docker exec xmpp-proxy-stack nginx-proxy-ctl list

# Remove a proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /api/

# Validate nginx configuration
docker exec xmpp-proxy-stack nginx-proxy-ctl validate
```

### Certificate Management

Certificates are automatically acquired via Let's Encrypt:

- **Initial acquisition**: On first run, HTTP-01 challenge via nginx
- **Renewal**: Daily check, auto-renews if expiring in < 30 days
- **Fallback**: Self-signed certificate if ACME fails (check DNS and port 80)

View certificate details:
```bash
docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/
```

Manual renewal (if needed):
```bash
docker exec xmpp-proxy-stack /app/acme.sh --renew -d your-domain.com --force
```

### Architecture

```
┌─────────────────────────────────────────────┐
│  Horust Process Supervisor                 │
│  ├─ nginx (HTTP/HTTPS proxy)               │
│  ├─ xmpp-proxy (XMPP reverse proxy)        │
│  ├─ fail2ban-rs (intrusion prevention)     │
│  └─ acme-renewer (daily cert renewal)      │
└─────────────────────────────────────────────┘
```

### Troubleshooting

**ACME certificate acquisition fails:**
1. Check DNS: `dig +short your-domain.com` should return your server IP
2. Check port 80: `ss -tlnp | grep :80`
3. Check logs: `docker logs xmpp-proxy-stack 2>&1 | grep -i acme`
4. Use self-signed for testing: Container falls back automatically

**Volume permission errors:**
```bash
chown -R 65532:65532 /srv/xmpp/{certs,logs,fail2ban,acme}
```

**View service logs:**
```bash
docker exec xmpp-proxy-stack /bin/busybox cat /logs/nginx-stdout.log
docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log
```

## Migrating from Debian-slim to Distroless

If upgrading from the old Debian-slim based stack:

### 1. Backup Current Setup

```bash
# Backup certificates
cp -r /srv/xmpp/certs /srv/xmpp/certs.backup

# Backup configuration
docker exec xmpp-proxy-stack tar czf /tmp/configs.tar.gz /etc/xmpp-proxy /etc/fail2ban-rs
docker cp xmpp-proxy-stack:/tmp/configs.tar.gz ./configs-backup.tar.gz
```

### 2. Rebuild with Distroless

```bash
# Pull latest code
git pull origin main

# Rebuild
docker-compose build xmpp-proxy-stack

# Stop old container
docker-compose stop xmpp-proxy-stack

# Start new distroless container
docker-compose up -d xmpp-proxy-stack
```

### 3. Verify Migration

```bash
# Check container is running
docker ps | grep xmpp-proxy-stack

# Verify services
docker exec xmpp-proxy-stack /bin/busybox ps aux

# Check certificates
docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/

# Test nginx-proxy-ctl
docker exec xmpp-proxy-stack nginx-proxy-ctl list
```

### Rollback (if needed)

```bash
# Stop distroless container
docker-compose stop xmpp-proxy-stack

# Rename Dockerfiles
mv xmpp-proxy-stack/Dockerfile.distroless xmpp-proxy-stack/Dockerfile.distroless.new
mv xmpp-proxy-stack/Dockerfile.debian xmpp-proxy-stack/Dockerfile

# Update docker-compose.yaml to use Dockerfile instead of Dockerfile.distroless

# Rebuild
docker-compose build xmpp-proxy-stack
docker-compose up -d xmpp-proxy-stack
```
