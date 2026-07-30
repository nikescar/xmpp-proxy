
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

#### Prosody Integration

###### Reverse proxy and outgoing proxy

In this mode prosody doesn't need to do any TLS. xmpp-proxy needs proper TLS certificates. Move prosody's TLS key to `/etc/xmpp-proxy/le.key` and TLS cert to `/etc/xmpp-proxy/fullchain.cer`.

Edit `/etc/prosody/prosody.cfg.lua`:
```lua
-- Add to modules_enabled (use fork until prosody-modules is updated):
"net_proxy";  -- https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/refs/heads/master/contrib/prosody-modules/mod_net_proxy.lua

-- Listen on localhost only
interfaces = { "127.0.0.1" }

-- Disable encryption (xmpp-proxy handles this)
s2s_require_encryption = false
s2s_secure_auth = false
c2s_require_encryption = false
allow_unencrypted_plain_auth = true

-- xmpp-proxy outgoing
proxy_out = { "127.0.0.1", 15270 }
proxy_secure = true

-- PROXY protocol
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- xmpp-proxy listens on standard ports
c2s_ports = {}
legacy_ssl_ports = {}
s2s_ports = {15268}  -- at least one required for outgoing S2S
```

###### Reverse proxy only

In this mode both prosody and xmpp-proxy need proper TLS certificates. Edit `/etc/prosody/prosody.cfg.lua`:
```lua
-- Add to modules_enabled:
"net_proxy";

-- Mark proxy connections as secure
proxy_secure_in = true

-- PROXY protocol
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- xmpp-proxy listens on standard ports
c2s_ports = {}
legacy_ssl_ports = {}
s2s_ports = {15268}
```

#### Docker Deployment

A complete Docker Compose stack provides:
  * **Prosody XMPP server** with MAM, carbons, and web admin
  * **xmpp-proxy** for STARTTLS/TLS/QUIC/WebSocket support
  * **nginx** for ACME HTTP-01 challenge and dynamic reverse proxying
  * **fail2ban-rs** for rate limiting and abuse protection
  * **Horust** process supervision in a hardened distroless container
  * Automatic TLS certificate management with acme.sh
  * PROXY protocol support for preserving client IPs

###### Quick Start

1. Configure environment:
   ```bash
   cp .env.example .env
   nano .env  # Set XMPP_DOMAIN and ACME_EMAIL
   ```

2. Create Prosody directories with correct ownership (UID 100:102):
   ```bash
   mkdir -p /srv/xmpp/prosody /srv/xmpp/logs/prosody
   chown -R 100:102 /srv/xmpp/prosody /srv/xmpp/logs/prosody
   ```

3. Start services:
   ```bash
   docker compose up -d
   ```

The stack exposes standard XMPP ports (5222, 5223, 5269, 443/udp, 5280, 80).
Data persists in `/srv/xmpp/` (prosody/, certs/, logs/, fail2ban/, acme/).

For development (build from source instead of using published image):
```bash
docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack
docker compose -f docker-compose.dev.yaml up -d
```

###### Architecture

Two containers:
  * **prosody** - Prosody XMPP server on localhost:15222 (C2S) and localhost:15269 (S2S) with PROXY protocol support
  * **xmpp-proxy-stack** - Bundles xmpp-proxy, nginx, fail2ban-rs, and acme.sh in a distroless image, supervised by Horust

xmpp-proxy terminates TLS on public ports, sends PROXY protocol headers, and forwards to Prosody. This preserves real client IPs for logging and rate limiting.

###### nginx-proxy-ctl Usage

Manage dynamic reverse proxy configurations at runtime:

```bash
# Add a reverse proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://localhost:8000/

# Add websocket proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket

# List configured proxies
docker exec xmpp-proxy-stack nginx-proxy-ctl list

# Remove a proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /api/

# Validate nginx configuration
docker exec xmpp-proxy-stack nginx-proxy-ctl validate
```

###### Certificate Management

Certificates are automatically acquired via Let's Encrypt:
- **Initial acquisition**: HTTP-01 challenge via nginx on port 80
- **Renewal**: Daily check, auto-renews if expiring in < 30 days
- **Fallback**: Self-signed certificate if ACME fails

View certificate details:
```bash
docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/
```

###### Customization

Put local overrides in `docker-compose.override.yaml`. Common customizations:
  * Change Prosody modules: set `PROSODY_ENABLE_MODULES` in `.env`
  * Adjust log levels: `PROSODY_LOGLEVEL`, `XMPP_PROXY_LOG_LEVEL`
  * Change data paths: modify volume mounts in override file
  * Add custom Prosody modules: drop them in `./prosody-modules/` directory

###### Troubleshooting

**prosody crash-loops with `usermod: UID '0' already exists`:**
Docker auto-created `/srv/xmpp/prosody` as root. Fix:
```bash
docker compose down
mkdir -p /srv/xmpp/prosody /srv/xmpp/logs/prosody
chown -R 100:102 /srv/xmpp/prosody /srv/xmpp/logs/prosody
docker compose up -d
```

**ACME certificate acquisition fails:**
1. Check DNS: `dig +short your-domain.com` should return your server IP
2. Check port 80: `ss -tlnp | grep :80`
3. Check logs: `docker logs xmpp-proxy-stack 2>&1 | grep -i acme`

**View service logs:**
```bash
docker exec xmpp-proxy-stack /bin/busybox cat /logs/nginx-stdout.log
docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log
```

#### Customize the build

xmpp-proxy has multiple compile-time features. Choose between:

Directions (1-4):
  1. `c2s-incoming` - accept incoming c2s connections
  2. `c2s-outgoing` - make outgoing c2s connections
  3. `s2s-incoming` - accept incoming s2s connections
  4. `s2s-outgoing` - make outgoing s2s connections

Transport protocols (1-4):
  1. `tls` - STARTTLS/TLS support
  2. `quic` - QUIC support
  3. `websocket` - WebSocket support (also enables TLS incoming if appropriate directions enabled)
  4. `webtransport` - WebTransport support (also enables QUIC)

Trusted CA roots (choose exactly 1, not needed if only `c2s-incoming`):
  1. `tls-ca-roots-native` - read CA roots from operating system
  2. `tls-ca-roots-bundled` - bundle CA roots from webpki-roots

Optional features:
  1. `logging` - configurable logging

Examples:
```bash
# Reverse proxy STARTTLS/TLS only
cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls

# Reverse proxy with STARTTLS/TLS/QUIC
cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls,quic
```

#### Development

1. `check-all-features.sh` checks compilation with all supported feature permutations
2. `integration/test.sh` uses [Rootless podman](https://wiki.archlinux.org/title/Podman#Rootless_Podman) to run integration tests through xmpp-proxy on a real network with real dns, web, and xmpp servers. All tests should pass before pushing commits.
3. Submit changes via PR on [github](https://github.com/moparisthebest/xmpp-proxy) or [code.moparisthebest.com](https://code.moparisthebest.com/moparisthebest/xmpp-proxy) or send patch via email, XMPP, fediverse, or carrier pigeon.

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
