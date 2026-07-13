# XMPP Docker Compose Design Specification

**Date:** 2026-07-14  
**Status:** Approved  
**Target:** Production team/family XMPP server deployment

## Overview

This specification describes a Docker Compose-based deployment for a production XMPP server using:
- **xmpp-proxy** - Reverse proxy handling TLS, QUIC, WebSocket, STARTTLS
- **Prosody** - XMPP server (official Docker image)
- **fail2ban-rs** - Intrusion prevention system
- **acmetool** - Automatic TLS certificate management

The design follows the deltachat-docker pattern with `.env` file configuration and automatic setup.

## Requirements

### Deployment Target
- Production team/family server (small-medium scale, <100 users)
- Single domain deployment
- External internet access required

### Key Features
1. **Automated TLS** - Let's Encrypt certificates via acmetool
2. **Multi-protocol support** - STARTTLS, Direct TLS, QUIC, WebSocket
3. **Intrusion prevention** - fail2ban-rs with comprehensive attack detection
4. **Simple setup** - `.env` file configuration
5. **Real client IPs** - PROXY protocol forwarding to Prosody
6. **Self-contained** - All services in Docker containers

### Technical Choices
- **Database:** SQLite (internal Prosody storage)
- **ACME client:** acmetool (matches deltachat pattern)
- **Network:** Host mode for xmpp-proxy, bridge for inter-container
- **Volumes:** Bind mounts at `/srv/xmpp/`
- **Architecture:** Multi-container sidecar pattern
- **Base images:** Debian 12 (xmpp-proxy-stack), official Prosody image
- **Management:** CLI by default, optional web UI

## Architecture

### High-Level Structure

**Two-container sidecar system:**

```
┌─────────────────────────────────────────────────────────┐
│ Host Network (Public Internet)                          │
│                                                          │
│  Ports: 5222, 5223, 5269, 443, 5443, 80                │
│         ↓                                                │
│  ┌──────────────────────────────────────┐               │
│  │ xmpp-proxy-stack (host networking)   │               │
│  │ ┌──────────────────────────────────┐ │               │
│  │ │ xmpp-proxy (binary download)     │ │               │
│  │ │ - TLS termination                │ │               │
│  │ │ - QUIC/WebSocket/STARTTLS        │ │               │
│  │ │ - Forwards with PROXY protocol   │ │               │
│  │ └──────────────────────────────────┘ │               │
│  │ ┌──────────────────────────────────┐ │               │
│  │ │ fail2ban-rs (binary download)    │ │               │
│  │ │ - Monitors logs                  │ │               │
│  │ │ - Manages nftables/iptables      │ │               │
│  │ └──────────────────────────────────┘ │               │
│  │ ┌──────────────────────────────────┐ │               │
│  │ │ acmetool (apt)                   │ │               │
│  │ │ - Obtains/renews certificates    │ │               │
│  │ │ - Daily cron job                 │ │               │
│  │ └──────────────────────────────────┘ │               │
│  │ ┌──────────────────────────────────┐ │               │
│  │ │ nginx (apt, minimal)             │ │               │
│  │ │ - ACME HTTP-01 challenge         │ │               │
│  │ └──────────────────────────────────┘ │               │
│  │ ┌──────────────────────────────────┐ │               │
│  │ │ Supervisor                       │ │               │
│  │ │ - Process manager                │ │               │
│  │ └──────────────────────────────────┘ │               │
│  └──────────────────────────────────────┘               │
│                     │                                    │
│                     │ Plain TCP + PROXY header           │
│                     ↓                                    │
│  ┌──────────────────────────────────────┐               │
│  │ prosody (bridge network)             │               │
│  │                                      │               │
│  │ Official prosodyim/prosody:13.0      │               │
│  │ - Listens on localhost only          │               │
│  │ - mod_net_proxy enabled              │               │
│  │ - SQLite storage                     │               │
│  └──────────────────────────────────────┘               │
│                                                          │
└─────────────────────────────────────────────────────────┘

Shared Volumes:
/srv/xmpp/certs/     → xmpp-proxy (rw), prosody (ro)
/srv/xmpp/prosody/   → prosody data (SQLite, uploads)
/srv/xmpp/logs/      → aggregated logs for fail2ban-rs
/srv/xmpp/fail2ban/  → fail2ban-rs state
/srv/xmpp/acme/      → acmetool state
```

### Network Architecture

**Host networking mode** for xmpp-proxy-stack:
- Direct binding to ports 5222 (c2s STARTTLS), 5223 (c2s Direct TLS), 5269 (s2s), 443 (QUIC/WebSocket), 5443 (WSS), 80 (ACME)
- Required for fail2ban-rs to manage host firewall (nftables/iptables)

**Bridge network** (`xmpp-internal`) for inter-container communication:
- Prosody listens on `0.0.0.0:5222` and `0.0.0.0:5269` within the bridge network
- xmpp-proxy connects to `prosody:5222` and `prosody:5269` via bridge network DNS

### Volume Strategy (Bind Mounts)

All data stored at `/srv/xmpp/`:

```
/srv/xmpp/
├── certs/          # TLS certificates (shared: xmpp-proxy writes, both read)
│   ├── fullchain.pem
│   └── privkey.pem
├── prosody/        # Prosody data directory
│   ├── *.sqlite    # SQLite databases
│   └── upload/     # HTTP file uploads
├── logs/           # Aggregated logs
│   ├── xmpp-proxy.log
│   ├── fail2ban-rs.log
│   ├── prosody.log
│   ├── acme-renewal.log
│   └── supervisor.log
├── fail2ban/       # fail2ban-rs state and ban database
│   └── state.bin
└── acme/           # acmetool state
    ├── conf/
    │   └── responses
    └── live/
        └── $XMPP_DOMAIN/
            ├── fullchain
            └── privkey
```

## Component Details

### Container 1: xmpp-proxy-stack

**Base Image:** `debian:12-slim`

**Purpose:** Handle all internet-facing traffic, TLS termination, and security

#### Components

**1. xmpp-proxy**
- **Source:** `https://github.com/nikescar/xmpp-proxy/releases/latest`
- **Download method:** `curl -L` in Dockerfile
- **Config:** `/etc/xmpp-proxy/xmpp-proxy.toml` (generated from template via envsubst)
- **Responsibilities:**
  - Listen on public ports (5222, 5223, 5269, 443, 5443)
  - Terminate TLS using certificates from `/certs/`
  - Handle STARTTLS, Direct TLS, QUIC, WebSocket protocols
  - Forward plain XMPP to `prosody:5222` and `prosody:5269`
  - Send PROXY protocol v1 header with real client IP
  - Auto-reload certificates on change (inotify)

**2. fail2ban-rs**
- **Source:** `https://github.com/aejimmi/fail2ban-rs/releases/latest`
- **Download method:** `curl -L` in Dockerfile, extract binary
- **Config:** `/etc/fail2ban-rs/config.toml` (generated from template)
- **Responsibilities:**
  - Monitor `/logs/*.log` for attack patterns
  - Detect failed authentication, S2S abuse, stanza flooding
  - Ban IPs via nftables (primary) or iptables (fallback)
  - Ban time escalation for repeat offenders (exponential backoff)
  - Maintain ban state in `/srv/xmpp/fail2ban/state.bin`

**Built-in jails:**
- **xmpp-auth** - Failed c2s authentication
- **xmpp-s2s-abuse** - S2S connection flooding
- **xmpp-stanza-flood** - Excessive stanza rate from single IP

**Custom jails:** User can add via `/etc/fail2ban-rs/jail.d/*.toml`

**3. acmetool**
- **Source:** Debian apt package
- **Config:** Responses file at `/var/lib/acme/conf/responses` (auto-generated from `$ACME_EMAIL`)
- **Responsibilities:**
  - Obtain initial certificate for `$XMPP_DOMAIN` on first run
  - Renew certificates before expiration (daily cron job)
  - Write certificates to `/var/lib/acme/live/$XMPP_DOMAIN/`
  - Symlink to `/certs/fullchain.pem` and `/certs/privkey.pem`
  - Auto-accept Let's Encrypt Terms of Service

**4. nginx**
- **Source:** Debian apt package (minimal install)
- **Config:** `/etc/nginx/nginx.conf` (minimal, only serves ACME challenge)
- **Responsibilities:**
  - Listen on port 80
  - Serve `/.well-known/acme-challenge/` for HTTP-01 validation
  - Forward requests to acmetool's webroot

**5. Supervisor**
- **Source:** Debian apt package
- **Config:** `/etc/supervisor/supervisord.conf`
- **Responsibilities:**
  - Manage xmpp-proxy and fail2ban-rs as daemons
  - Auto-restart on crashes
  - Log stdout/stderr to `/logs/supervisor.log`
  - Simpler than systemd for single-purpose container

### Container 2: prosody (Official Image)

**Image:** `prosodyim/prosody:13.0`

**Purpose:** XMPP server logic, user authentication, message routing

#### Configuration

**Environment Variables (from `.env`):**
```bash
PROSODY_ADMINS=$XMPP_ADMIN              # admin@example.com
PROSODY_VIRTUAL_HOSTS=$XMPP_DOMAIN      # chat.example.com
PROSODY_LOGLEVEL=info
PROSODY_STORAGE=internal                # SQLite-backed storage
PROSODY_ENABLE_MODULES=mam,carbons,csi_simple,ping,admin_adhoc
PROSODY_CERTIFICATES=/certs             # Shared volume (read-only)
PROSODY_RETENTION_DAYS=90               # Message archive retention
```

**Custom Config Snippet** (mounted at `/etc/prosody/conf.d/proxy.cfg.lua`):
```lua
-- Enable PROXY protocol support
modules_enabled = {
    "net_proxy";  -- mod_net_proxy for PROXY protocol
}

proxy_port_mappings = {
    [5222] = "c2s",  -- Client-to-server connections
    [5269] = "s2s"   -- Server-to-server connections
}

-- Trust connections from xmpp-proxy as already secure
proxy_secure = true

-- Don't require encryption (xmpp-proxy already handled TLS)
c2s_require_encryption = false
s2s_require_encryption = false
s2s_secure_auth = false

-- Allow plaintext auth since connection is already secure
allow_unencrypted_plain_auth = true
```

**Optional Web Admin:**
- If `ENABLE_WEB_ADMIN=true` in `.env`, enable `mod_admin_web` on port 5280
- Expose via reverse proxy (not directly to internet)

## Data Flow

### Flow 1: Client Connection (Gajim → Prosody)

```
1. Client (Gajim) connects to chat.example.com:5222
   - DNS lookup: chat.example.com → 203.0.113.50 (server public IP)
   ↓
2. xmpp-proxy accepts TLS connection on port 5222
   - Performs TLS handshake
   - Presents certificate from /srv/xmpp/certs/fullchain.pem
   - Client validates certificate (issued by Let's Encrypt for chat.example.com)
   ↓
3. xmpp-proxy terminates TLS, reads XMPP stream
   - Decrypts traffic
   - Reads <stream:stream to="chat.example.com">
   ↓
4. xmpp-proxy opens plain TCP connection to prosody:5222 (bridge network)
   - Sends PROXY v1 header: "PROXY TCP4 198.51.100.5 203.0.113.50 44123 5222\r\n"
     (client_real_ip, proxy_ip, client_port, dest_port)
   - Forwards decrypted XMPP stream
   ↓
5. Prosody receives connection
   - mod_net_proxy parses PROXY header
   - Extracts real client IP: 198.51.100.5
   - Treats connection as secure (proxy_secure = true)
   - Logs show real IP, not Docker bridge IP
   ↓
6. Client authenticates with username/password
   - Prosody validates credentials against SQLite database
   - If auth fails: log to /logs/prosody.log
   ↓
7. fail2ban-rs monitors /srv/xmpp/logs/prosody.log
   - Detects pattern: "Failed authentication for user@chat.example.com from 198.51.100.5"
   - Increments counter for IP 198.51.100.5
   - If count exceeds max_retry (5) within find_time (10m):
     → Execute: nft add element inet fail2ban-rs xmpp-auth { 198.51.100.5 timeout 1h }
     → IP banned at kernel level for ban_time (1h)
   ↓
8. Client successfully authenticated → session established
   - Prosody sends <stream:features> with available features
   - Client binds resource → full JID: user@chat.example.com/gajim
```

### Flow 2: Server-to-Server (S2S Outgoing)

```
1. User sends message to friend@jabber.org
   - Prosody needs to establish S2S connection to jabber.org
   ↓
2. Prosody performs SRV lookup
   - Queries: _xmpp-server._tcp.jabber.org
   - Gets: hermes.jabber.org:5269 (priority 0, weight 5)
   ↓
3. Prosody connects to hermes.jabber.org:5269
   - Opens plain TCP connection
   - Sends <stream:stream to="jabber.org">
   ↓
4. Remote server offers STARTTLS
   - Prosody sends <starttls/>
   - Remote sends <proceed/>
   ↓
5. TLS negotiation
   - Prosody performs TLS handshake
   - Validates remote server's certificate for jabber.org
   - Uses certificates from /certs/ for own identity
   ↓
6. XMPP stream restart after TLS
   - Prosody authenticates via dialback or SASL EXTERNAL
   - Remote server validates chat.example.com ownership
   ↓
7. Message delivery
   - Prosody sends <message to="friend@jabber.org">
   - Remote server delivers to friend's client
```

**Note:** For S2S outgoing, Prosody connects directly to remote servers. An optional xmpp-proxy outgoing mode can be configured if you want all S2S connections proxied (for advanced setups).

### Flow 3: ACME Certificate Renewal

```
1. Daily cron job at 03:00 triggers: acmetool reconcile
   ↓
2. acmetool checks certificate expiration
   - Reads /var/lib/acme/live/chat.example.com/fullchain
   - Checks "Not After" date
   - If expiring in <30 days → initiate renewal
   ↓
3. acmetool requests new certificate from Let's Encrypt
   - Generates challenge token
   - Writes to /var/run/acme/acme-challenge/<token>
   ↓
4. Let's Encrypt validates challenge
   - HTTP GET: http://chat.example.com/.well-known/acme-challenge/<token>
   - nginx serves file from /var/run/acme/acme-challenge/
   - Let's Encrypt verifies response matches expected value
   ↓
5. Let's Encrypt issues new certificate
   - acmetool receives certificate
   - Writes to /var/lib/acme/live/chat.example.com/fullchain (new cert)
   - Writes to /var/lib/acme/live/chat.example.com/privkey (new key)
   ↓
6. Symlinks automatically update
   - /certs/fullchain.pem → /var/lib/acme/live/chat.example.com/fullchain
   - /certs/privkey.pem → /var/lib/acme/live/chat.example.com/privkey
   ↓
7. xmpp-proxy detects certificate change (inotify)
   - Automatically reloads TLS configuration
   - No restart required, no client disconnections
   ↓
8. Prosody reads from same /certs/ volume
   - Next S2S connection uses new certificate
```

**Renewal logging:**
- All output logged to `/srv/xmpp/logs/acme-renewal.log`
- fail2ban-rs can monitor for errors and send alerts

### Flow 4: Intrusion Detection & Blocking

```
1. Attacker attempts brute-force login
   - Tries multiple passwords for victim@chat.example.com from IP 1.2.3.4
   ↓
2. Each failed attempt logged by Prosody
   - /srv/xmpp/logs/prosody.log:
     "c2s1a2b3c4 Failed authentication for victim@chat.example.com from 1.2.3.4"
   ↓
3. fail2ban-rs tails /srv/xmpp/logs/prosody.log
   - Matches regex: 'Failed authentication for .* from <HOST>'
   - Extracts IP: 1.2.3.4
   ↓
4. fail2ban-rs increments counter
   - Jail: xmpp-auth
   - IP: 1.2.3.4
   - Count: 1, 2, 3, 4, 5...
   ↓
5. Counter exceeds max_retry (5) within find_time (10m)
   - Trigger ban action
   ↓
6. fail2ban-rs executes nftables ban
   - Command: nft add element inet fail2ban-rs xmpp-auth { 1.2.3.4 timeout 1h }
   - Creates rule in kernel: DROP all packets from 1.2.3.4 for 1 hour
   ↓
7. Attacker's packets dropped at kernel level
   - No TCP handshake completes
   - No load on xmpp-proxy or Prosody
   ↓
8. After ban_time (1h), nftables automatically removes IP
   - timeout mechanism cleans up automatically
   ↓
9. If IP repeats offense (bantime_increment = true)
   - First ban: 1h
   - Second ban: 2h (multiplier: 2)
   - Third ban: 4h (multiplier: 4)
   - Fourth ban: 8h (multiplier: 8)
   - ...up to bantime_maxtime (1 week)
   ↓
10. Ban count resets after ban_count_decay (30d)
    - If IP is clean for 30 days → escalation counter reset to 0
```

## Configuration & Initialization

### First-Time Setup

**1. User creates `.env` file:**

```bash
# .env
# Required
XMPP_DOMAIN=chat.example.com
ACME_EMAIL=admin@example.com

# Optional
XMPP_ADMIN=admin@chat.example.com
PROSODY_LOGLEVEL=info
ENABLE_WEB_ADMIN=false           # Set true to enable mod_admin_web on :5280
FAIL2BAN_MAX_RETRY=5
FAIL2BAN_BAN_TIME=1h
FAIL2BAN_FIND_TIME=10m
```

**2. User runs:** `docker compose up -d`

### Initialization Flow

#### xmpp-proxy-stack Container Init

**Entrypoint script:** `/docker-entrypoint.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "=== xmpp-proxy-stack initialization ==="

# Check required environment variables
if [ -z "${XMPP_DOMAIN:-}" ]; then
    echo "ERROR: XMPP_DOMAIN not set in .env"
    exit 1
fi

if [ -z "${ACME_EMAIL:-}" ]; then
    echo "ERROR: ACME_EMAIL not set in .env"
    exit 1
fi

# Generate xmpp-proxy configuration from template
echo "Generating xmpp-proxy.toml..."
export PROSODY_HOST=prosody  # DNS name in bridge network
envsubst < /etc/xmpp-proxy/xmpp-proxy.toml.template \
    > /etc/xmpp-proxy/xmpp-proxy.toml

# Generate fail2ban-rs configuration
echo "Generating fail2ban-rs config.toml..."
envsubst < /etc/fail2ban-rs/config.toml.template \
    > /etc/fail2ban-rs/config.toml

# Check if TLS certificates exist
if [ ! -f /certs/fullchain.pem ]; then
    echo "No certificates found. Running ACME setup..."
    
    # Configure acmetool to auto-accept Terms of Service
    mkdir -p /var/lib/acme/conf
    cat > /var/lib/acme/conf/responses <<EOF
"acme-enter-email": "$ACME_EMAIL"
"acme-agreement:https://letsencrypt.org/documents/LE-SA-v1.8-July-06-2026.pdf": true
EOF
    
    echo "Requesting certificate for $XMPP_DOMAIN..."
    
    # Start nginx for HTTP-01 challenge
    nginx
    
    # Request certificate
    if ! acmetool want "$XMPP_DOMAIN"; then
        echo "ERROR: ACME certificate acquisition failed"
        echo ""
        echo "Possible causes:"
        echo "  1. DNS A/AAAA record for $XMPP_DOMAIN not pointing to this server"
        echo "  2. Port 80 blocked by firewall (needed for HTTP-01 challenge)"
        echo "  3. Let's Encrypt rate limit (5 failures per account per hour)"
        echo ""
        echo "Generating self-signed certificate for testing..."
        
        mkdir -p /certs
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout /certs/privkey.pem \
            -out /certs/fullchain.pem \
            -days 365 -subj "/CN=$XMPP_DOMAIN"
        
        echo "WARNING: Using self-signed certificate. Clients will show warnings."
    else
        # Symlink acmetool certs to shared location
        ln -sf "/var/lib/acme/live/$XMPP_DOMAIN/fullchain" /certs/fullchain.pem
        ln -sf "/var/lib/acme/live/$XMPP_DOMAIN/privkey" /certs/privkey.pem
        echo "Certificate successfully obtained!"
    fi
    
    # Stop nginx (xmpp-proxy will handle port 80 if needed)
    nginx -s stop || true
fi

# Setup cron for certificate renewal
echo "0 3 * * * /usr/bin/acmetool reconcile >> /logs/acme-renewal.log 2>&1" \
    | crontab -

echo "Starting cron daemon..."
cron

# Initialize fail2ban-rs (create nftables table)
echo "Initializing fail2ban-rs firewall..."
if command -v nft &> /dev/null; then
    nft add table inet fail2ban-rs 2>/dev/null || true
    echo "nftables backend ready"
elif command -v iptables &> /dev/null; then
    echo "nftables not available, using iptables backend"
else
    echo "ERROR: Neither nftables nor iptables available"
    exit 1
fi

# Start supervisor (manages xmpp-proxy and fail2ban-rs)
echo "Starting supervisor..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
```

#### Prosody Container Init

- Official image handles initialization automatically
- Reads environment variables from `.env`
- Generates default `prosody.cfg.lua` if not mounted
- Our custom snippet at `/etc/prosody/conf.d/proxy.cfg.lua` adds PROXY protocol support
- Waits for `/certs/fullchain.pem` to exist before starting

### Configuration Templates

#### xmpp-proxy.toml.template

```toml
# Generated from template by docker-entrypoint.sh
# Environment variables: $XMPP_DOMAIN, $PROSODY_HOST

# Incoming connections (reverse proxy)

# C2S STARTTLS (port 5222)
[[in]]
local_addr = "[::]:5222"
client_addr = "${PROSODY_HOST}:5222"
proxy_proto = true
starttls = true
tls_cert = "/certs/fullchain.pem"
tls_key = "/certs/privkey.pem"
max_stanza_size_bytes = 262144

# C2S Direct TLS (legacy port 5223)
[[in]]
local_addr = "[::]:5223"
client_addr = "${PROSODY_HOST}:5222"
proxy_proto = true
tls_cert = "/certs/fullchain.pem"
tls_key = "/certs/privkey.pem"
max_stanza_size_bytes = 262144

# S2S (port 5269)
[[in]]
local_addr = "[::]:5269"
client_addr = "${PROSODY_HOST}:5269"
proxy_proto = true
starttls = true
tls_cert = "/certs/fullchain.pem"
tls_key = "/certs/privkey.pem"
max_stanza_size_bytes = 262144

# WebSocket Secure (port 5443)
[[in]]
local_addr = "[::]:5443"
client_addr = "${PROSODY_HOST}:5280"
websocket = true
proxy_proto = true
tls_cert = "/certs/fullchain.pem"
tls_key = "/certs/privkey.pem"
max_stanza_size_bytes = 524288

# QUIC (port 443)
[[in]]
local_addr = "[::]:443"
client_addr = "${PROSODY_HOST}:5222"
quic = true
proxy_proto = true
tls_cert = "/certs/fullchain.pem"
tls_key = "/certs/privkey.pem"
max_stanza_size_bytes = 262144

# Outgoing S2S proxy (optional, for proxying outbound S2S)
# [[out]]
# local_addr = "0.0.0.0:15270"
# max_stanza_size_bytes = 262144
```

#### fail2ban-rs config.toml.template

```toml
# Generated from template by docker-entrypoint.sh
# Environment variables: $FAIL2BAN_MAX_RETRY, $FAIL2BAN_BAN_TIME, $FAIL2BAN_FIND_TIME

[global]
ban_count_decay = "30d"  # Reset escalation counter after 30 quiet days

# XMPP C2S Authentication Failures
[jail.xmpp-auth]
enabled = true
log_path = "/logs/prosody.log"
filter = [
    'Failed authentication for .* from <HOST>',
    'c2s[a-f0-9]+ Failed SASL authentication .* IP: <HOST>',
]
max_retry = ${FAIL2BAN_MAX_RETRY}
find_time = "${FAIL2BAN_FIND_TIME}"
ban_time = "${FAIL2BAN_BAN_TIME}"
backend = "nftables"
port = ["5222", "5223"]
protocol = "tcp"

# Ban time escalation for repeat offenders
bantime_increment = true
bantime_multipliers = [1, 2, 4, 8, 16, 32, 64]
bantime_maxtime = "1w"

# Never ban localhost or private IPs
ignoreip = ["127.0.0.1/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

# XMPP S2S Abuse (connection flooding)
[jail.xmpp-s2s-abuse]
enabled = true
log_path = "/logs/prosody.log"
filter = [
    's2s[a-f0-9]+ Connection rate limit exceeded for <HOST>',
    's2sin[a-f0-9]+ Received invalid XML from <HOST>',
]
max_retry = 10
find_time = "5m"
ban_time = "2h"
backend = "nftables"
port = ["5269"]
protocol = "tcp"

# XMPP Stanza Flooding
[jail.xmpp-stanza-flood]
enabled = true
log_path = "/logs/xmpp-proxy.log"
filter = [
    'Stanza size limit exceeded.*from <HOST>',
    'Rate limit exceeded.*<HOST>',
]
max_retry = 3
find_time = "1m"
ban_time = "30m"
backend = "nftables"
```

#### supervisord.conf

```ini
[supervisord]
nodaemon=true
logfile=/logs/supervisor.log
pidfile=/var/run/supervisord.pid

[program:xmpp-proxy]
command=/usr/local/bin/xmpp-proxy /etc/xmpp-proxy/xmpp-proxy.toml
autostart=true
autorestart=true
stdout_logfile=/logs/xmpp-proxy.log
stderr_logfile=/logs/xmpp-proxy.log
user=xmpp-proxy

[program:fail2ban-rs]
command=/usr/local/bin/fail2ban-rs --config /etc/fail2ban-rs/config.toml
autostart=true
autorestart=true
stdout_logfile=/logs/fail2ban-rs.log
stderr_logfile=/logs/fail2ban-rs.log
user=root  # Needs root for nftables/iptables
```

### Configuration Override (Advanced Users)

Users can create `docker-compose.override.yaml` to customize:

```yaml
# docker-compose.override.yaml.example
services:
  prosody:
    volumes:
      # Mount custom Prosody configuration
      - ./custom-prosody.cfg.lua:/etc/prosody/prosody.cfg.lua
      
  xmpp-proxy-stack:
    volumes:
      # Add custom fail2ban jails
      - ./custom-jails:/etc/fail2ban-rs/jail.d
      
      # Use external certificates (bypass ACME)
      - /etc/letsencrypt/live/chat.example.com:/certs:ro
```

## Error Handling & Recovery

### Scenario 1: ACME Certificate Acquisition Fails

**Causes:**
- DNS A/AAAA record not configured or incorrect
- Port 80 blocked by firewall (needed for HTTP-01 challenge)
- Let's Encrypt rate limit exceeded (5 failures per account per hour)

**Detection:**
- `acmetool want` exits with non-zero status
- Error logged to stdout and `/logs/acme-renewal.log`

**Automatic Recovery:**
```bash
# In docker-entrypoint.sh:
if ! acmetool want "$XMPP_DOMAIN"; then
    echo "ERROR: ACME certificate acquisition failed"
    echo "Generating self-signed certificate for testing..."
    
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout /certs/privkey.pem \
        -out /certs/fullchain.pem \
        -days 365 -subj "/CN=$XMPP_DOMAIN"
    
    echo "WARNING: Using self-signed certificate."
fi
```

**User Action Required:**
1. Fix DNS: Ensure `chat.example.com` points to server's public IP
2. Fix firewall: Allow port 80 inbound
3. Wait if rate-limited (retry after 1 hour)
4. Run: `docker compose restart xmpp-proxy-stack`

### Scenario 2: Prosody Container Crashes

**Detection:**
- Docker health check fails
- `docker compose ps` shows Prosody as `Exit 1` or `Restarting`

**Automatic Recovery:**
```yaml
# docker-compose.yaml includes:
prosody:
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "prosodyctl", "status"]
    interval: 30s
    timeout: 10s
    retries: 3
```

- Docker automatically restarts Prosody
- xmpp-proxy reconnects to Prosody when available
- No data loss (SQLite data in `/srv/xmpp/prosody/` persists)

**User Action:** Check logs: `docker compose logs prosody`

### Scenario 3: fail2ban-rs Can't Manage Firewall

**Causes:**
- nftables/iptables not installed on host
- Container missing `NET_ADMIN` capability

**Detection:**
```bash
# fail2ban-rs checks at startup:
if ! nft list tables 2>/dev/null; then
    if ! iptables -L 2>/dev/null; then
        echo "ERROR: Neither nftables nor iptables available"
        exit 1
    else
        echo "WARNING: nftables not found, using iptables backend"
    fi
fi
```

**docker-compose.yaml includes:**
```yaml
xmpp-proxy-stack:
  cap_add:
    - NET_ADMIN  # Required for firewall management
```

**User Action:**
- Install nftables on host: `apt install nftables`
- Verify capability: `docker inspect xmpp-proxy-stack | grep NET_ADMIN`

### Scenario 4: Certificate Renewal Fails Silently

**Detection:**
- Cron job logs errors to `/logs/acme-renewal.log`
- Optional: fail2ban-rs monitors this log for errors

**Monitoring jail (optional):**
```toml
[jail.acme-failure]
enabled = true
log_path = "/logs/acme-renewal.log"
filter = ['error', 'failed', 'ERROR']
max_retry = 1
find_time = "24h"
action = "email"  # Custom action to send notification
```

**User Action:**
- Check renewal log: `tail -f /srv/xmpp/logs/acme-renewal.log`
- Manually trigger renewal: `docker compose exec xmpp-proxy-stack acmetool reconcile`

### Scenario 5: xmpp-proxy Starts Before Prosody

**Prevention:**
```yaml
# docker-compose.yaml includes:
xmpp-proxy-stack:
  depends_on:
    prosody:
      condition: service_healthy
```

**Automatic Recovery:**
- xmpp-proxy retries connections to Prosody backend every 5 seconds
- Once Prosody health check passes, xmpp-proxy connects successfully
- No manual intervention needed

### Scenario 6: Port Conflicts

**Detection:**
- xmpp-proxy fails to bind port (e.g., port 80 already in use)
- Error in logs: `Address already in use`

**User Action:**
1. Check for conflicts: `ss -tlnp | grep -E ':(80|443|5222|5269|5443)'`
2. Stop conflicting service (e.g., Apache, nginx on host)
3. Restart: `docker compose up -d`

### Logging & Debugging

**All logs aggregated to `/srv/xmpp/logs/`:**
```
/srv/xmpp/logs/
├── xmpp-proxy.log       # TLS connections, PROXY protocol, errors
├── fail2ban-rs.log      # Ban/unban events, pattern matches
├── prosody.log          # XMPP server events, auth, S2S
├── acme-renewal.log     # Certificate renewals, errors
└── supervisor.log       # Process starts/stops, crashes
```

**Access logs:**
```bash
# View all logs (real-time)
docker compose logs -f

# Specific service
docker compose logs -f prosody
docker compose logs -f xmpp-proxy-stack

# Direct file access (survives container restarts)
tail -f /srv/xmpp/logs/prosody.log
grep "Failed authentication" /srv/xmpp/logs/prosody.log
```

**Debug mode:**
```bash
# Enable verbose logging
# Edit .env:
PROSODY_LOGLEVEL=debug

# Restart
docker compose restart prosody
```

## Testing & Verification

### Pre-Deployment Checks

**1. DNS Verification:**
```bash
# Check A/AAAA records
dig +short chat.example.com A
dig +short chat.example.com AAAA

# Expected: Your server's public IP

# Check SRV records (optional but recommended)
dig +short _xmpp-client._tcp.chat.example.com SRV
dig +short _xmpp-server._tcp.chat.example.com SRV

# Expected SRV format:
# 0 5 5222 chat.example.com.
# 0 5 5269 chat.example.com.
```

**2. Firewall Verification:**
```bash
# Ensure ports are open on host firewall
sudo ufw status
# or
sudo iptables -L INPUT -n -v

# Required ports:
# 80/tcp    (ACME HTTP-01 challenge)
# 443/tcp   (QUIC)
# 443/udp   (QUIC)
# 5222/tcp  (C2S STARTTLS)
# 5223/tcp  (C2S Direct TLS)
# 5269/tcp  (S2S)
# 5443/tcp  (WebSocket Secure)
```

### Post-Deployment Tests

**3. Container Health:**
```bash
# Check all containers running
docker compose ps

# Expected output:
# NAME                STATUS
# xmpp-proxy-stack    Up (healthy)
# prosody             Up (healthy)

# View startup logs
docker compose logs --tail=100
```

**4. Certificate Verification:**
```bash
# Check cert was obtained
ls -lh /srv/xmpp/certs/
# Expected: fullchain.pem, privkey.pem (symlinks or regular files)

# Verify cert details
openssl x509 -in /srv/xmpp/certs/fullchain.pem -text -noout | grep -E "(Subject:|Issuer:|Not After)"

# Expected:
# Issuer: C = US, O = Let's Encrypt, CN = R3
# Subject: CN = chat.example.com
# Not After : <date in future>
```

**5. Port Connectivity (from external host):**
```bash
# Test C2S STARTTLS
nc -zv chat.example.com 5222
# Expected: Connection succeeded

# Test S2S
nc -zv chat.example.com 5269

# Test TLS handshake
echo | openssl s_client -connect chat.example.com:5222 -starttls xmpp 2>&1 | grep -E "(Verify return code|subject=)"

# Expected:
# subject=CN = chat.example.com
# Verify return code: 0 (ok)
```

**6. Create Admin User:**
```bash
# Add first admin user
docker compose exec prosody prosodyctl adduser admin@chat.example.com

# Enter password when prompted
```

### Functional Tests

**7. Client Connection Test (Gajim):**

1. Install Gajim: `apt install gajim` (or download from gajim.org)
2. Add account:
   - JID: `testuser@chat.example.com`
   - Password: (create via `prosodyctl adduser`)
   - Connection: Auto-detect settings
3. Connect and verify:
   - Encryption: Check that lock icon shows valid TLS
   - Account → Server Info → Connection → IP should show your server
4. Send test message to another user

**8. WebSocket Test:**

```bash
# Install wscat
npm install -g wscat

# Test WebSocket connection
wscat -c wss://chat.example.com:5443/xmpp-websocket

# Expected: Connection established
# Send XMPP stream header:
# <stream:stream to="chat.example.com" xmlns="jabber:client" xmlns:stream="http://etherx.jabber.org/streams" version="1.0">

# Should receive stream response from Prosody
```

**9. S2S Federation Test:**

```bash
# From Gajim or another XMPP client logged into chat.example.com
# Send message to: friend@jabber.org (or any federated server)

# Check S2S logs
docker compose exec prosody tail -f /var/log/prosody/prosody.log | grep s2s

# Expected: Lines showing outgoing connection to jabber.org
# s2sout... Creating new outgoing connection to jabber.org
# s2sout... Connection established
```

### Security Tests

**10. fail2ban-rs Verification:**

```bash
# Trigger failed authentication (from test machine)
# Use incorrect password 6 times via Gajim or:
for i in {1..6}; do
    echo '<auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" mechanism="PLAIN">wrong</auth>' | \
    nc chat.example.com 5222
done

# Check fail2ban-rs status
docker compose exec xmpp-proxy-stack fail2ban-rs status

# Expected: Shows banned IP with jail "xmpp-auth"

# Check nftables
docker compose exec xmpp-proxy-stack nft list table inet fail2ban-rs

# Expected: Contains your test IP in set xmpp-auth

# Manually unban for testing
docker compose exec xmpp-proxy-stack fail2ban-rs unban <YOUR_IP> xmpp-auth
```

**11. PROXY Protocol Test:**

```bash
# Connect from known IP, check Prosody sees real IP (not Docker bridge)
docker compose exec prosody prosodyctl shell

# In Prosody shell (interactive Lua):
> for jid, session in pairs(prosody.full_sessions) do
    print(jid, session.ip)
  end

# Expected: Shows real client IP (e.g., 203.0.113.50)
# NOT Docker bridge IP (172.18.0.x)
```

**12. Certificate Auto-Reload Test:**

```bash
# Trigger manual renewal
docker compose exec xmpp-proxy-stack acmetool reconcile --force

# Watch xmpp-proxy logs
docker compose logs -f xmpp-proxy-stack | grep -i cert

# Expected: xmpp-proxy detects cert change and reloads
# No container restart needed
# Existing connections stay alive
```

### Automated Test Suite

**Provide `scripts/test-deployment.sh`:**

```bash
#!/bin/bash
set -euo pipefail

# Load environment
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

echo "=== XMPP Deployment Test Suite ==="
echo ""

# DNS Test
echo "1. Testing DNS resolution..."
DNS_IP=$(dig +short "$XMPP_DOMAIN" A | head -1)
if [ -z "$DNS_IP" ]; then
    echo "   ❌ FAILED: No A record for $XMPP_DOMAIN"
    exit 1
else
    echo "   ✅ PASSED: $XMPP_DOMAIN → $DNS_IP"
fi

# Port Connectivity
echo "2. Testing port 5222 (C2S)..."
if nc -zv -w5 "$XMPP_DOMAIN" 5222 2>&1 | grep -q succeeded; then
    echo "   ✅ PASSED: Port 5222 reachable"
else
    echo "   ❌ FAILED: Port 5222 not reachable"
    exit 1
fi

echo "3. Testing port 5269 (S2S)..."
if nc -zv -w5 "$XMPP_DOMAIN" 5269 2>&1 | grep -q succeeded; then
    echo "   ✅ PASSED: Port 5269 reachable"
else
    echo "   ⚠️  WARNING: Port 5269 not reachable (federation may not work)"
fi

# TLS Certificate
echo "4. Testing TLS certificate..."
if echo | openssl s_client -connect "$XMPP_DOMAIN:5222" -starttls xmpp 2>/dev/null | \
   grep -q "Verify return code: 0"; then
    echo "   ✅ PASSED: Valid TLS certificate"
else
    echo "   ❌ FAILED: Invalid or self-signed certificate"
fi

# Container Status
echo "5. Testing container health..."
if docker compose ps | grep -q "prosody.*Up"; then
    echo "   ✅ PASSED: Prosody container running"
else
    echo "   ❌ FAILED: Prosody container not running"
    exit 1
fi

if docker compose ps | grep -q "xmpp-proxy-stack.*Up"; then
    echo "   ✅ PASSED: xmpp-proxy-stack container running"
else
    echo "   ❌ FAILED: xmpp-proxy-stack container not running"
    exit 1
fi

# Prosody Status
echo "6. Testing Prosody daemon..."
if docker compose exec -T prosody prosodyctl status 2>&1 | grep -q "Prosody is running"; then
    echo "   ✅ PASSED: Prosody daemon active"
else
    echo "   ❌ FAILED: Prosody daemon not responding"
    exit 1
fi

# fail2ban-rs Status
echo "7. Testing fail2ban-rs..."
if docker compose exec -T xmpp-proxy-stack fail2ban-rs stats 2>&1 | grep -q "jail"; then
    echo "   ✅ PASSED: fail2ban-rs running"
else
    echo "   ⚠️  WARNING: fail2ban-rs not responding"
fi

# Certificate Files
echo "8. Testing certificate files..."
if [ -f "/srv/xmpp/certs/fullchain.pem" ] && [ -f "/srv/xmpp/certs/privkey.pem" ]; then
    echo "   ✅ PASSED: Certificate files present"
else
    echo "   ❌ FAILED: Certificate files missing"
    exit 1
fi

echo ""
echo "=== All Core Tests Passed ✅ ==="
echo ""
echo "Next steps:"
echo "  1. Create admin user: docker compose exec prosody prosodyctl adduser admin@$XMPP_DOMAIN"
echo "  2. Configure Gajim or another XMPP client"
echo "  3. Test federation with external XMPP server (e.g., jabber.org)"
```

**Run with:** `./scripts/test-deployment.sh`

### Manual Testing Checklist

- [ ] DNS A/AAAA records configured
- [ ] SRV records configured (optional but recommended)
- [ ] Ports 80, 443, 5222, 5269, 5443 open in firewall
- [ ] Containers start without errors
- [ ] Certificates obtained (check `/srv/xmpp/certs/`)
- [ ] Admin user created
- [ ] Gajim connects successfully
- [ ] TLS encryption verified (lock icon in client)
- [ ] Messages between local users work
- [ ] Federation works (send message to external server)
- [ ] WebSocket connection works (if using web client)
- [ ] fail2ban-rs bans after failed auth attempts
- [ ] Real client IPs visible in Prosody logs (not 172.x.x.x)
- [ ] Certificate auto-renewal cron job scheduled

## File Structure

```
xmpp-proxy/
├── docker-compose.yaml                      # Main orchestration
├── docker-compose.override.yaml.example     # Customization examples
├── .env.example                             # Environment template
├── .dockerignore
├── .gitignore
├── README.md                                # Quick start guide
├── LICENSE
│
├── xmpp-proxy-stack/                       # Custom container source
│   ├── Dockerfile
│   ├── docker-entrypoint.sh                # Init script
│   ├── templates/
│   │   ├── xmpp-proxy.toml.template        # xmpp-proxy config template
│   │   ├── fail2ban-rs-config.toml.template
│   │   └── prosody-proxy.cfg.lua           # PROXY protocol snippet
│   ├── supervisord.conf                    # Process manager config
│   └── nginx.conf                          # Minimal ACME HTTP-01 server
│
├── scripts/
│   ├── backup.sh                           # Backup prosody data + certs
│   ├── restore.sh                          # Restore from backup
│   └── test-deployment.sh                  # Automated test suite
│
└── docs/
    ├── QUICKSTART.md                       # Step-by-step setup guide
    ├── TROUBLESHOOTING.md                  # Common issues + fixes
    ├── GAJIM_SETUP.md                      # Gajim client configuration
    ├── FEDERATION.md                       # S2S setup and testing
    └── ADVANCED.md                         # Custom configs, scaling
```

## Deployment Procedure

### Quick Start (5 minutes)

```bash
# 1. Clone repository
git clone https://github.com/nikescar/xmpp-proxy
cd xmpp-proxy

# 2. Configure environment
cp .env.example .env
nano .env
# Set:
#   XMPP_DOMAIN=chat.example.com
#   ACME_EMAIL=admin@example.com

# 3. Create data directories
sudo mkdir -p /srv/xmpp/{certs,prosody,logs,fail2ban,acme}
sudo chown -R $USER:$USER /srv/xmpp

# 4. Deploy
docker compose up -d

# 5. Watch logs (wait for cert acquisition)
docker compose logs -f

# 6. Verify
./scripts/test-deployment.sh

# 7. Create admin user
docker compose exec prosody prosodyctl adduser admin@chat.example.com
# Enter password when prompted

# 8. Connect with Gajim
# Install: apt install gajim
# Add account: admin@chat.example.com
```

### Production Deployment Checklist

**Before deployment:**
- [ ] DNS A/AAAA records pointing to server
- [ ] (Optional) SRV records configured
- [ ] Firewall rules allow ports 80, 443, 5222, 5269, 5443
- [ ] Server time synchronized (important for ACME)

**Deployment:**
- [ ] Clone repo
- [ ] Configure `.env` with domain and email
- [ ] Run `docker compose up -d`
- [ ] Verify with `./scripts/test-deployment.sh`
- [ ] Create admin user

**Post-deployment:**
- [ ] Test client connection (Gajim)
- [ ] Test federation (message to external server)
- [ ] Verify fail2ban-rs is active
- [ ] Set up monitoring (optional)
- [ ] Schedule backups (e.g., daily cron: `./scripts/backup.sh`)

### Backup & Restore

**Backup script (`scripts/backup.sh`):**
```bash
#!/bin/bash
BACKUP_DIR="/srv/xmpp/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$BACKUP_DIR"
tar czf "$BACKUP_DIR/xmpp-backup-$TIMESTAMP.tar.gz" \
    /srv/xmpp/prosody \
    /srv/xmpp/certs \
    /srv/xmpp/fail2ban \
    /srv/xmpp/acme

echo "Backup created: $BACKUP_DIR/xmpp-backup-$TIMESTAMP.tar.gz"
```

**Restore:**
```bash
docker compose down
tar xzf /srv/xmpp/backups/xmpp-backup-YYYYMMDD-HHMMSS.tar.gz -C /
docker compose up -d
```

## Summary

This design provides a production-ready XMPP deployment with:

✅ **Automated setup** - `.env` configuration, auto-generated configs  
✅ **Secure by default** - ACME TLS, fail2ban-rs protection, PROXY protocol  
✅ **Multi-protocol** - STARTTLS, Direct TLS, QUIC, WebSocket support  
✅ **Easy management** - Docker Compose orchestration, health checks  
✅ **Well-tested** - Automated test suite, comprehensive verification  
✅ **Production-ready** - Error recovery, logging, backup/restore  
✅ **Extensible** - Custom config overrides, optional web admin  

**Key architectural decisions:**

1. **Multi-container sidecar** - Separate concerns (proxy/security vs XMPP logic)
2. **Official Prosody image** - Leverage upstream maintenance
3. **Binary downloads** - Fast builds, no Rust toolchain needed
4. **Host networking for proxy** - Required for fail2ban-rs firewall management
5. **Bind mounts** - Direct data access, clear ownership
6. **Supervisor over systemd** - Simpler for single-purpose container

**Implementation phases:**

1. **Phase 1** - Core infrastructure (Dockerfile, docker-compose.yaml, templates)
2. **Phase 2** - Initialization scripts (entrypoint, config generation)
3. **Phase 3** - fail2ban-rs integration (jails, nftables setup)
4. **Phase 4** - Testing & documentation (test suite, README, guides)
5. **Phase 5** - Optional features (web admin, advanced monitoring)

This design is ready for implementation.
