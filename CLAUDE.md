# xmpp-proxy Development Guide

This guide helps Claude Code assist with both Rust development and Docker infrastructure work on the xmpp-proxy project.

## 1. Project Overview & Architecture

### 1.1 What xmpp-proxy Does

xmpp-proxy is a reverse proxy and outgoing proxy for XMPP servers and clients:

**Reverse proxy mode:**
- TLS termination for incoming connections
- Forwards plain TCP to Prosody XMPP server
- Handles STARTTLS, Direct TLS, QUIC, WebSocket, and WebTransport

**Outgoing proxy mode:**
- Accepts plain TCP from Prosody
- Establishes TLS connections to remote XMPP servers
- Performs SRV lookups and certificate validation

**Key feature:** Stanza size limiting without full XML parsing - minimal overhead while protecting against oversized stanzas.

### 1.2 Two-Container Architecture

The Docker stack uses two containers:

**`prosody` container:**
- Runs official Prosody 13.0 image
- Listens on localhost only: 15222 (C2S), 15269 (S2S), 15280 (HTTP)
- Configured to accept PROXY protocol headers
- Uses internal bridge network for container-to-container communication

**`xmpp-proxy-stack` container:**
- Bundles: xmpp-proxy + nginx + fail2ban-rs + acme.sh + horust
- Uses host networking (critical for PROXY protocol)
- Distroless base image for security
- Single container supervision via horust

### 1.3 Critical Networking Concepts

**Why host networking is required:**
- PROXY protocol v1 needs to preserve real client IP addresses
- Standard bridge networking would show all connections as coming from Docker bridge IP
- Host networking allows xmpp-proxy to see actual source IPs and pass them to Prosody

**How PROXY protocol works:**
- xmpp-proxy accepts connection from internet (e.g., 203.0.113.45:54321)
- Terminates TLS and establishes plain TCP to Prosody
- Sends header: `PROXY TCP4 203.0.113.45 127.0.0.1 54321 15222\r\n`
- Prosody's mod_net_proxy parses header and logs real client IP
- Enables proper rate limiting, abuse prevention, and logging

**Port mapping flow:**
```
Internet → xmpp-proxy-stack (host network) → Prosody (bridge network)
5222/tcp → xmpp-proxy (TLS termination) → 127.0.0.1:15222 (PROXY protocol)
5223/tcp → xmpp-proxy (Direct TLS) → 127.0.0.1:15222 (PROXY protocol)
5269/tcp → xmpp-proxy (S2S TLS) → 127.0.0.1:15269 (PROXY protocol)
443/udp → xmpp-proxy (QUIC) → 127.0.0.1:15222 (PROXY protocol)
```

**Why nginx is included:**
- Primary: ACME HTTP-01 challenge validation (port 80)
- Secondary: Dynamic reverse proxy capability via nginx-proxy-ctl
- Example: Proxy `/api/` to Prosody's HTTP API without rebuilding container

### 1.4 Data Persistence & Volumes

All data stored in `/srv/xmpp/`:

**`/srv/xmpp/prosody`** → Container `/var/lib/prosody`
- Prosody database, user data, offline messages
- **Critical:** Must be owned by UID 100:102 (prosody user in container)
- Common issue: Docker auto-creates as root, causing crash loop

**`/srv/xmpp/certs`** → Shared between both containers
- TLS certificates and private keys
- Written by acme.sh in xmpp-proxy-stack
- Read by Prosody (if configured for TLS) and xmpp-proxy

**`/srv/xmpp/logs`** → Container `/logs` (xmpp-proxy-stack only)
- xmpp-proxy logs: `/logs/xmpp-proxy-stdout.log`, `/logs/xmpp-proxy-stderr.log`
- nginx logs: `/logs/nginx-stdout.log`, `/logs/nginx-stderr.log`
- fail2ban-rs logs: `/logs/fail2ban-rs-stdout.log`

**`/srv/xmpp/fail2ban`** → Container `/var/lib/fail2ban-rs`
- Ban state persistence
- Survives container restarts

**`/srv/xmpp/acme`** → Container `/etc/acme.sh`
- acme.sh account info and renewal state
- Prevents re-registration on container restart

### 1.5 The Distroless + Horust Model

**Why distroless:**
- Minimal attack surface: no package manager, no shell, no utilities
- Only contains: application binaries, runtime dependencies, minimal CA certs
- Challenge: Debugging requires busybox workaround

**Why horust (process supervisor):**
- Need to run multiple processes in one container: xmpp-proxy, nginx, fail2ban-rs, acme.sh cron
- Traditional init systems (systemd, s6) too heavy for distroless
- Horust: lightweight, single binary, TOML config, proper signal handling
- Service definitions in `xmpp-proxy-stack/horust-services/*.toml`

**Why bundle instead of separate containers:**
- Host networking constraint: Only one container can bind to standard ports
- TLS cert coordination: All services need immediate access to updated certs
- Operational simplicity: Single container to manage, one health check
- Trade-off: Less granular resource limits, harder to debug individual services

**Service startup order:**
1. `docker-entrypoint.sh` runs (initializes certs if missing)
2. horust starts and supervises:
   - nginx (always runs, handles ACME challenges)
   - xmpp-proxy (waits for certs to exist)
   - fail2ban-rs (reads xmpp-proxy logs)
   - acme.sh cron (daily renewal check)
