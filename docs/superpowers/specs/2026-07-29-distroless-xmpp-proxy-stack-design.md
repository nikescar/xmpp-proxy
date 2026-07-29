# Distroless XMPP Proxy Stack with Dynamic Nginx Proxy Management

**Date**: 2026-07-29  
**Status**: Approved  
**Author**: Claude Code (Superpowers TDD)

## Overview

This design migrates the `xmpp-proxy-stack` container from Debian-slim to a distroless base image while maintaining all current functionality (xmpp-proxy, fail2ban-rs) and adding dynamic nginx reverse proxy management capabilities.

### Goals

1. **Security Hardening**: Migrate to `gcr.io/distroless/base-debian13` to minimize attack surface
2. **Certificate Management**: Integrate acme.sh for automated SSL/TLS certificate lifecycle management
3. **Dynamic Proxy Configuration**: Enable runtime addition/removal of HTTP/HTTPS reverse proxy configurations
4. **Process Supervision**: Replace supervisord with Horust (Rust-based, container-native supervisor)
5. **Port Management**: Clean separation - nginx (80/tcp, 443/tcp), xmpp-proxy (5222/tcp, 5223/tcp, 5269/tcp, 443/udp)

### Non-Goals

- Replacing xmpp-proxy or fail2ban-rs implementations
- Migrating to separate sidecar containers
- Changing from host networking mode
- Supporting non-Linux platforms

## Architecture

### Container Structure

**Single All-in-One Distroless Container**: `xmpp-proxy-stack`

```
┌─────────────────────────────────────────────────────────────┐
│  xmpp-proxy-stack (gcr.io/distroless/base-debian13)        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Horust Process Supervisor                           │   │
│  │                                                      │   │
│  │  ┌──────────────┐  ┌────────────────┐              │   │
│  │  │ nginx        │  │ xmpp-proxy     │              │   │
│  │  │ :80,:443/tcp │  │ :5222,:5223    │              │   │
│  │  └──────────────┘  │ :5269,:443/udp │              │   │
│  │                    └────────────────┘              │   │
│  │  ┌──────────────┐  ┌────────────────┐              │   │
│  │  │ fail2ban-rs  │  │ acme-renewer   │              │   │
│  │  │ (nftables)   │  │ (periodic)     │              │   │
│  │  └──────────────┘  └────────────────┘              │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  CLI Tools:                                                 │
│  • nginx-proxy-ctl (add/remove/list proxy configs)         │
│  • acme.sh (certificate management)                         │
└─────────────────────────────────────────────────────────────┘
         │              │                │
         ▼              ▼                ▼
    /srv/xmpp/    /srv/xmpp/      /srv/xmpp/
      certs/         logs/        fail2ban/
```

### Multi-Stage Dockerfile

**Builder Stages** → **Final Distroless Image**

#### Stage 1: nginx-builder
```dockerfile
FROM nginx:1.27.0 AS nginx-builder
# Purpose: Extract nginx binary, configurations, and shared libraries
# Output:
#   - /usr/sbin/nginx
#   - /etc/nginx/
#   - /lib/x86_64-linux-gnu/* (libc, libssl, etc.)
#   - /usr/lib/x86_64-linux-gnu/*
```

#### Stage 2: horust-builder
```dockerfile
FROM rust:alpine AS horust-builder
# Purpose: Download or compile Horust process supervisor
# Strategy:
#   1. Try downloading from GitHub releases (faster)
#   2. Fallback to compiling from source if needed
# Output: /usr/local/bin/horust (statically linked)
```

#### Stage 3: acme-builder
```dockerfile
FROM alpine:latest AS acme-builder
# Purpose: Install acme.sh certificate management tool
# Steps:
#   - Clone from https://github.com/acmesh-official/acme.sh.git
#   - Install to /app with --nocron --auto-upgrade 0
# Output: /app/acme.sh and dependencies
```

#### Stage 4: binaries-builder
```dockerfile
FROM debian:13-slim AS binaries-builder
# Purpose: Download pre-compiled xmpp-proxy and fail2ban-rs
# Architecture detection: x86_64 or aarch64
# Sources:
#   - xmpp-proxy: https://github.com/nikescar/xmpp-proxy/releases
#   - fail2ban-rs: https://github.com/aejimmi/fail2ban-rs/releases
# Output: musl-linked static binaries
```

#### Stage 5: tools-builder
```dockerfile
FROM debian:13-slim AS tools-builder
# Purpose: Create configuration files and scripts
# Outputs:
#   - nginx-proxy-ctl bash script
#   - Horust service definitions (*.toml)
#   - Nginx config templates
#   - Entrypoint script
#   - busybox-static (for entrypoint shell support)
```

#### Final Stage: distroless
```dockerfile
FROM gcr.io/distroless/base-debian13:latest

# Copy binaries from all builder stages
COPY --from=nginx-builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-builder /etc/nginx /etc/nginx
COPY --from=nginx-builder /lib/x86_64-linux-gnu /lib/x86_64-linux-gnu
COPY --from=nginx-builder /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu

COPY --from=horust-builder /usr/local/bin/horust /usr/local/bin/horust
COPY --from=acme-builder /app /app
COPY --from=binaries-builder /usr/local/bin/xmpp-proxy /usr/local/bin/xmpp-proxy
COPY --from=binaries-builder /usr/local/bin/fail2ban-rs /usr/local/bin/fail2ban-rs
COPY --from=tools-builder /usr/local/bin/nginx-proxy-ctl /usr/local/bin/nginx-proxy-ctl
COPY --from=tools-builder /etc/horust/services/ /etc/horust/services/
COPY --from=tools-builder /etc/nginx/templates/ /etc/nginx/templates/
COPY --from=tools-builder /bin/busybox /bin/busybox

# Create necessary directories
RUN ["/bin/busybox", "mkdir", "-p", "/certs", "/logs", "/etc/xmpp-proxy", "/etc/fail2ban-rs"]

EXPOSE 80 443 5222 5223 5269

ENTRYPOINT ["/usr/local/bin/horust"]
```

## Component Design

### Horust Service Definitions

Horust manages all processes via TOML configuration files in `/etc/horust/services/`.

#### nginx.toml
```toml
command = "/usr/sbin/nginx -g 'daemon off;'"
start-delay = "0s"
stdout = "/logs/nginx-stdout.log"
stderr = "/logs/nginx-stderr.log"
working-directory = "/etc/nginx"

[restart]
strategy = "always"
backoff = "5s"
attempts = 0

[healthiness]
http-endpoint = "http://localhost:80/health"

[termination]
signal = "TERM"
wait = "10s"
```

#### xmpp-proxy.toml
```toml
command = "/usr/local/bin/xmpp-proxy /etc/xmpp-proxy/xmpp-proxy.toml"
start-delay = "2s"
start-after = ["nginx.toml"]
stdout = "/logs/xmpp-proxy-stdout.log"
stderr = "/logs/xmpp-proxy-stderr.log"

[restart]
strategy = "always"
backoff = "5s"
attempts = 0

[termination]
signal = "TERM"
wait = "15s"
```

#### fail2ban-rs.toml
```toml
command = "/usr/local/bin/fail2ban-rs --config /etc/fail2ban-rs/config.toml"
start-delay = "3s"
start-after = ["xmpp-proxy.toml"]
stdout = "/logs/fail2ban-rs-stdout.log"
stderr = "/logs/fail2ban-rs-stderr.log"
user = "root"

[restart]
strategy = "always"
backoff = "10s"
attempts = 0

[termination]
signal = "TERM"
wait = "5s"
```

#### acme-renewer.toml
```toml
command = "/app/acme.sh --cron --home /app --config-home /etc/acme.sh/default"
start-delay = "86400s"  # Start first renewal check after 24 hours
stdout = "/logs/acme-renewer-stdout.log"
stderr = "/logs/acme-renewer-stderr.log"

[restart]
strategy = "on-failure"
backoff = "3600s"  # Retry every hour on failure
attempts = 24  # Give up after 24 attempts (1 day)

[termination]
signal = "TERM"
wait = "30s"
```

### nginx-proxy-ctl CLI Tool

**Location**: `/usr/local/bin/nginx-proxy-ctl`  
**Language**: Bash (for simplicity and no compilation overhead)  
**Testing**: Bats (Bash Automated Testing System)

#### Interface
```bash
# Add a new proxy location
nginx-proxy-ctl add <location-path> <upstream-url> [options]

# Remove a proxy location
nginx-proxy-ctl remove <location-path>

# List all configured proxies
nginx-proxy-ctl list

# Validate nginx configuration
nginx-proxy-ctl validate

# Auto-discover containers with labels (optional)
nginx-proxy-ctl discover [--watch]
```

#### Examples
```bash
# Add API proxy
nginx-proxy-ctl add /api/ http://localhost:8000/

# Add with custom headers
nginx-proxy-ctl add /app/ http://app-backend:3000/ \
  --header "X-Custom: value" \
  --websocket

# Remove proxy
nginx-proxy-ctl remove /api/

# List all proxies
nginx-proxy-ctl list
# Output:
# /api/ -> http://localhost:8000/
# /app/ -> http://app-backend:3000/ [websocket]
```

#### Implementation Structure
```bash
#!/bin/bash
# nginx-proxy-ctl - Dynamic nginx proxy configuration manager

set -euo pipefail

NGINX_CONF_DIR="/etc/nginx/conf.d"
TEMPLATE_FILE="/etc/nginx/templates/location-proxy.conf.template"
NGINX_BIN="/usr/sbin/nginx"

# Testable functions (for bats)
function validate_location_path() { ... }
function validate_upstream_url() { ... }
function generate_proxy_config() { ... }
function add_proxy() { ... }
function remove_proxy() { ... }
function list_proxies() { ... }
function reload_nginx() { ... }
function discover_containers() { ... }

# Main command dispatch
case "${1:-}" in
  add) add_proxy "$@" ;;
  remove) remove_proxy "$@" ;;
  list) list_proxies ;;
  validate) validate_nginx ;;
  discover) discover_containers "$@" ;;
  *) usage; exit 1 ;;
esac
```

#### Proxy Configuration Template

**File**: `/etc/nginx/templates/location-proxy.conf.template`

```nginx
location ${LOCATION_PATH} {
    proxy_pass ${UPSTREAM_URL};
    
    # Standard proxy headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    
    # WebSocket support (if enabled)
    ${WEBSOCKET_HEADERS}
    
    # Custom headers (if provided)
    ${CUSTOM_HEADERS}
    
    # Timeouts
    proxy_connect_timeout ${PROXY_TIMEOUT:-60s};
    proxy_send_timeout ${PROXY_TIMEOUT:-60s};
    proxy_read_timeout ${PROXY_TIMEOUT:-60s};
}
```

#### Docker Label Auto-Discovery

Containers can expose proxy configuration via labels:

```yaml
# Example docker-compose.yaml
services:
  api-backend:
    image: my-api:latest
    labels:
      - "nginx.proxy.enable=true"
      - "nginx.proxy.location=/api/"
      - "nginx.proxy.port=8000"
      - "nginx.proxy.websocket=false"
```

`nginx-proxy-ctl discover` scans Docker API and generates configs automatically.

### Certificate Management

#### Initial Certificate Acquisition

**Entrypoint Logic** (runs before Horust starts):

```bash
#!/bin/busybox sh
# entrypoint.sh

# Check if certificates exist
if [ ! -f /certs/fullchain.pem ] || [ ! -f /certs/privkey.pem ]; then
    echo "No certificates found. Acquiring via ACME..."
    
    # Ensure nginx is running for HTTP-01 challenge
    /usr/sbin/nginx
    
    # Configure acme.sh
    /app/acme.sh --register-account \
        --home /app \
        --config-home /etc/acme.sh/default \
        --email "${ACME_EMAIL}"
    
    # Issue certificate
    /app/acme.sh --issue \
        --home /app \
        --config-home /etc/acme.sh/default \
        --domain "${XMPP_DOMAIN}" \
        --webroot /var/run/acme/acme-challenge \
        --keylength 4096
    
    if [ $? -eq 0 ]; then
        # Symlink to /certs/
        ln -sf "/etc/acme.sh/default/${XMPP_DOMAIN}/fullchain.cer" /certs/fullchain.pem
        ln -sf "/etc/acme.sh/default/${XMPP_DOMAIN}/${XMPP_DOMAIN}.key" /certs/privkey.pem
        echo "Certificate acquired successfully!"
    else
        echo "ACME acquisition failed. Generating self-signed certificate..."
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout /certs/privkey.pem \
            -out /certs/fullchain.pem \
            -days 365 -subj "/CN=${XMPP_DOMAIN}"
        echo "WARNING: Using self-signed certificate."
    fi
    
    # Stop nginx (Horust will restart it)
    /usr/sbin/nginx -s stop 2>/dev/null || true
fi

# Generate runtime configs from templates
envsubst < /etc/templates/xmpp-proxy.toml.template > /etc/xmpp-proxy/xmpp-proxy.toml
envsubst < /etc/templates/fail2ban-rs-config.toml.template > /etc/fail2ban-rs/config.toml

# Start Horust
exec /usr/local/bin/horust
```

#### Certificate Renewal

- Horust runs `acme-renewer.toml` service daily
- acme.sh checks certificate expiry (auto-renews if < 30 days)
- On renewal success: sends `SIGHUP` to nginx (reload without downtime)
- On renewal failure: logs error, retries in 1 hour (via Horust backoff)

### Port Allocation

| Service      | Protocol | Port(s)           | Purpose                          |
|--------------|----------|-------------------|----------------------------------|
| nginx        | TCP      | 80                | HTTP (ACME challenges, redirects)|
| nginx        | TCP      | 443               | HTTPS reverse proxy              |
| xmpp-proxy   | TCP      | 5222              | XMPP C2S (STARTTLS)              |
| xmpp-proxy   | TCP      | 5223              | XMPP C2S (Direct TLS)            |
| xmpp-proxy   | TCP      | 5269              | XMPP S2S                         |
| xmpp-proxy   | UDP      | 443               | XMPP over QUIC                   |

**Conflict Resolution**: nginx and xmpp-proxy can coexist because they use different protocols for port 443 (TCP vs UDP).

## Data Flow

### Certificate Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Container Startup (Entrypoint)                          │
│    └─> Check /certs/fullchain.pem exists?                  │
│         ├─ No: Run acme.sh --issue                         │
│         │   └─> HTTP-01 challenge via nginx :80            │
│         │       └─> Success: Symlink to /certs/            │
│         │       └─> Failure: Generate self-signed          │
│         └─ Yes: Skip to step 2                             │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Horust Starts Services                                  │
│    ├─> nginx (reads /certs/fullchain.pem)                  │
│    ├─> xmpp-proxy (reads /certs/fullchain.pem)             │
│    ├─> fail2ban-rs                                         │
│    └─> acme-renewer (scheduled for +24h)                   │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Daily Renewal Check (acme-renewer service)              │
│    └─> acme.sh --cron                                      │
│         ├─> Cert expires in > 30 days: No action           │
│         └─> Cert expires in < 30 days:                     │
│             └─> Renew via HTTP-01 challenge                │
│                 └─> Update symlinks in /certs/             │
│                     └─> Send SIGHUP to nginx (reload)      │
└─────────────────────────────────────────────────────────────┘
```

### Nginx Proxy Configuration Flow

```
┌─────────────────────────────────────────────────────────────┐
│ User: docker exec xmpp-proxy-stack nginx-proxy-ctl add ... │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ nginx-proxy-ctl                                             │
│  1. Validate location path (no duplicates, valid syntax)    │
│  2. Validate upstream URL (reachable, valid format)         │
│  3. Generate config from template                           │
│  4. Write to /etc/nginx/conf.d/proxy-<hash>.conf           │
│  5. Test config: nginx -t                                   │
│     ├─ Success: nginx -s reload                            │
│     └─ Failure: Delete config, return error                │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Nginx reloads gracefully                                    │
│  - Keeps existing connections open                          │
│  - New connections use updated config                       │
└─────────────────────────────────────────────────────────────┘
```

### Docker Container Auto-Discovery Flow

```
┌─────────────────────────────────────────────────────────────┐
│ User: nginx-proxy-ctl discover --watch                     │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Scan Docker API for containers with nginx.proxy.* labels   │
│  Container: api-backend                                     │
│    nginx.proxy.enable=true                                  │
│    nginx.proxy.location=/api/                               │
│    nginx.proxy.port=8000                                    │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Generate proxy config                                       │
│  location /api/ {                                           │
│    proxy_pass http://172.17.0.3:8000/;                     │
│    ...                                                      │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Write config, reload nginx                                  │
│                                                             │
│ --watch mode: Listen for Docker events                     │
│   Container start → Add proxy                               │
│   Container stop  → Remove proxy                            │
└─────────────────────────────────────────────────────────────┘
```

## Error Handling & Resilience

### Certificate Acquisition Failures

**Scenario**: Initial ACME challenge fails (DNS not ready, port 80 blocked, rate limits)

**Handling**:
1. Log detailed error message with troubleshooting steps:
   - Check DNS A/AAAA record points to this server
   - Verify port 80 is open in firewall
   - Check Let's Encrypt rate limits (5 failures/account/hour)
2. Generate self-signed certificate as fallback
3. Services start normally (xmpp-proxy, nginx use self-signed cert)
4. User can manually retry: `docker exec xmpp-proxy-stack /app/acme.sh --issue ...`

**Prevention**: Entrypoint pre-flight checks DNS resolution and port 80 availability before attempting ACME.

### Service Crash Handling

**Horust Restart Policies**:

| Service       | Restart Strategy | Backoff | Max Attempts |
|---------------|------------------|---------|--------------|
| nginx         | always           | 5s      | unlimited    |
| xmpp-proxy    | always           | 5s      | unlimited    |
| fail2ban-rs   | always           | 10s     | unlimited    |
| acme-renewer  | on-failure       | 3600s   | 24 (1 day)   |

**Crash Logging**: All service stdout/stderr streams to `/logs/<service>-{stdout,stderr}.log`

**User Notification**: On repeated crashes (>3 in 5 minutes), consider emitting metrics or webhook (future enhancement).

### Configuration Validation

**nginx-proxy-ctl Validation Steps**:

1. **Location Path Validation**:
   - Must start with `/`
   - No duplicate entries in `/etc/nginx/conf.d/`
   - Valid nginx location syntax

2. **Upstream URL Validation**:
   - Valid URL format (`http://` or `https://`)
   - Optional: DNS resolution check
   - Optional: TCP connection test to upstream

3. **Nginx Syntax Test**:
   - Write config to temp file
   - Run `nginx -t -c /tmp/test-config`
   - If test fails: delete temp file, return error
   - If test passes: move to `/etc/nginx/conf.d/`, reload

4. **Atomic Updates**:
   ```bash
   # Atomic config update
   temp_file=$(mktemp)
   generate_config > "$temp_file"
   
   if nginx -t -c "$temp_file" 2>&1 | grep -q "successful"; then
       mv "$temp_file" "/etc/nginx/conf.d/proxy-${hash}.conf"
       nginx -s reload
   else
       rm "$temp_file"
       echo "ERROR: Invalid nginx configuration"
       exit 1
   fi
   ```

### Port Conflicts

**Entrypoint Pre-flight Check**:

```bash
# Check required ports are available
for port in 80:tcp 443:tcp 443:udp 5222:tcp 5223:tcp 5269:tcp; do
    proto="${port#*:}"
    num="${port%:*}"
    if ss -${proto:0:1}ln | grep -q ":${num} "; then
        echo "ERROR: Port ${port} already in use"
        exit 1
    fi
done
```

**On Conflict**: Container fails to start with clear error message. User investigates with `ss -tulpn` on host.

### Volume Permissions

**Distroless UID/GID**: Runs as `nonroot` user (UID 65532) by default.

**Solution**: Entrypoint checks write permissions:

```bash
for dir in /certs /logs /var/lib/fail2ban-rs; do
    if ! touch "${dir}/.write-test" 2>/dev/null; then
        echo "ERROR: No write permission to ${dir}"
        echo "Fix: chown -R 65532:65532 /srv/xmpp/{certs,logs,fail2ban}"
        exit 1
    fi
    rm "${dir}/.write-test"
done
```

**Docker Compose User Override** (if needed):
```yaml
services:
  xmpp-proxy-stack:
    user: "0:0"  # Run as root if host volumes have restrictive permissions
```

### Graceful Shutdown

**Horust Termination Flow** (on `docker stop`):

1. Horust receives SIGTERM from Docker
2. Horust sends SIGTERM to all services (parallel)
3. Waits for configured timeout:
   - nginx: 10s (drains connections)
   - xmpp-proxy: 15s (drains XMPP streams)
   - fail2ban-rs: 5s
4. If service doesn't exit: Horust sends SIGKILL
5. Horust exits with code 0

**Connection Draining**:
- nginx: Uses `worker_shutdown_timeout` directive
- xmpp-proxy: Closes listeners, finishes in-flight stanzas

## Testing Strategy

### Test-Driven Development Workflow

**Red → Green → Refactor**:

1. Write failing test for a specific feature
2. Implement minimal code to pass the test
3. Refactor code while keeping tests green
4. Repeat for each feature increment

### Test Structure

```
xmpp-proxy-stack/
├── Dockerfile
├── docker-entrypoint.sh
├── nginx-proxy-ctl
├── templates/
│   ├── nginx.conf
│   ├── location-proxy.conf.template
│   ├── xmpp-proxy.toml.template
│   └── fail2ban-rs-config.toml.template
├── horust-services/
│   ├── nginx.toml
│   ├── xmpp-proxy.toml
│   ├── fail2ban-rs.toml
│   └── acme-renewer.toml
└── tests/
    ├── setup_suite.bash       # Bats setup helpers
    ├── teardown_suite.bash    # Bats teardown helpers
    ├── helpers/
    │   ├── docker.bash        # Docker compose helpers
    │   ├── wait.bash          # Wait/retry utilities
    │   └── http.bash          # HTTP assertion helpers
    ├── unit/
    │   ├── test_add_proxy.bats
    │   ├── test_remove_proxy.bats
    │   ├── test_list_proxies.bats
    │   ├── test_config_validation.bats
    │   ├── test_docker_discovery.bats
    │   └── test_template_rendering.bats
    └── integration/
        ├── test_distroless_build.bats
        ├── test_service_startup.bats
        ├── test_horust_supervision.bats
        ├── test_acme_flow.bats
        ├── test_proxy_e2e.bats
        └── test_graceful_shutdown.bats
```

### Unit Tests (Bats)

**Scope**: Test `nginx-proxy-ctl` functions in isolation

**Mock Strategy**: Mock external dependencies (nginx, docker API, file system)

**Example Test Suite**: `tests/unit/test_add_proxy.bats`

```bash
#!/usr/bin/env bats

# Load helpers
load '../helpers/docker'
load '../helpers/http'

# Mock nginx binary
setup() {
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    export NGINX_CONF_DIR="$BATS_TEST_TMPDIR/conf.d"
    mkdir -p "$NGINX_CONF_DIR"
    
    # Source the CLI script functions
    source "$BATS_TEST_DIRNAME/../../nginx-proxy-ctl"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "add_proxy creates valid config file" {
    run add_proxy /api/ http://localhost:8000/
    
    [ "$status" -eq 0 ]
    [ -f "$NGINX_CONF_DIR"/proxy-*.conf ]
}

@test "add_proxy rejects invalid location path" {
    run add_proxy api/ http://localhost:8000/  # Missing leading /
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid location path" ]]
}

@test "add_proxy rejects duplicate location" {
    add_proxy /api/ http://localhost:8000/
    
    run add_proxy /api/ http://localhost:9000/  # Duplicate
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "already exists" ]]
}

@test "add_proxy validates upstream URL format" {
    run add_proxy /api/ not-a-url
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid upstream URL" ]]
}

@test "add_proxy includes websocket headers when --websocket flag" {
    run add_proxy /ws/ http://localhost:8080/ --websocket
    
    [ "$status" -eq 0 ]
    config_file=$(ls "$NGINX_CONF_DIR"/proxy-*.conf)
    grep -q "Upgrade \$http_upgrade" "$config_file"
    grep -q "Connection \"upgrade\"" "$config_file"
}

@test "add_proxy calls nginx reload after successful config" {
    # Mock nginx binary tracks calls
    run add_proxy /api/ http://localhost:8000/
    
    [ "$status" -eq 0 ]
    [ -f /tmp/nginx-reload-called ]  # Mock creates this file
}

@test "add_proxy rolls back on nginx test failure" {
    # Mock nginx -t to fail
    export MOCK_NGINX_TEST_FAIL=1
    
    run add_proxy /api/ http://localhost:8000/
    
    [ "$status" -eq 1 ]
    [ ! -f "$NGINX_CONF_DIR"/proxy-*.conf ]  # Config should be deleted
}
```

**Other Unit Test Suites**:

- `test_remove_proxy.bats`: Test config deletion and reload
- `test_list_proxies.bats`: Test parsing and formatting output
- `test_config_validation.bats`: Test validation logic edge cases
- `test_docker_discovery.bats`: Test Docker API label parsing
- `test_template_rendering.bats`: Test nginx config template substitution

**Test Execution**:
```bash
# Run all unit tests (fast)
bats tests/unit/

# Run specific test file
bats tests/unit/test_add_proxy.bats

# Run with verbose output
bats -t tests/unit/
```

### Integration Tests (Bats + Docker)

**Scope**: Test the complete distroless container in a real Docker environment

**Setup**: Use docker-compose to spin up test environment

**Example Test Suite**: `tests/integration/test_service_startup.bats`

```bash
#!/usr/bin/env bats

load '../helpers/docker'
load '../helpers/wait'

setup_suite() {
    # Build the distroless image
    docker-compose -f tests/docker-compose.test.yml build
    
    # Start containers
    docker-compose -f tests/docker-compose.test.yml up -d
    
    # Wait for services to be healthy
    wait_for_service xmpp-proxy-stack 30
}

teardown_suite() {
    # Capture logs on failure
    docker-compose -f tests/docker-compose.test.yml logs > test-logs.txt
    
    # Clean up
    docker-compose -f tests/docker-compose.test.yml down -v
}

@test "container starts successfully" {
    run docker ps --filter "name=xmpp-proxy-stack" --format "{{.Status}}"
    
    [[ "$output" =~ "Up" ]]
}

@test "horust is running as PID 1" {
    run docker exec xmpp-proxy-stack ps aux
    
    [[ "$output" =~ "1.*horust" ]]
}

@test "nginx service is running" {
    run docker exec xmpp-proxy-stack ps aux
    
    [[ "$output" =~ "nginx" ]]
}

@test "xmpp-proxy service is running" {
    run docker exec xmpp-proxy-stack ps aux
    
    [[ "$output" =~ "xmpp-proxy" ]]
}

@test "fail2ban-rs service is running" {
    run docker exec xmpp-proxy-stack ps aux
    
    [[ "$output" =~ "fail2ban-rs" ]]
}

@test "nginx responds on port 80" {
    run curl -s -o /dev/null -w "%{http_code}" http://localhost:80/health
    
    [ "$output" = "200" ]
}

@test "all required ports are listening" {
    for port in 80 443 5222 5223 5269; do
        run ss -tlnp | grep ":${port} "
        [ "$status" -eq 0 ]
    done
    
    # Check UDP port 443
    run ss -ulnp | grep ":443 "
    [ "$status" -eq 0 ]
}

@test "certificates exist in /certs/" {
    run docker exec xmpp-proxy-stack ls /certs/
    
    [[ "$output" =~ "fullchain.pem" ]]
    [[ "$output" =~ "privkey.pem" ]]
}

@test "service logs are being written" {
    sleep 5  # Let services run for a bit
    
    run docker exec xmpp-proxy-stack ls /logs/
    
    [[ "$output" =~ "nginx-stdout.log" ]]
    [[ "$output" =~ "xmpp-proxy-stdout.log" ]]
    [[ "$output" =~ "fail2ban-rs-stdout.log" ]]
}
```

**Example Test Suite**: `tests/integration/test_proxy_e2e.bats`

```bash
#!/usr/bin/env bats

load '../helpers/docker'
load '../helpers/http'

setup_suite() {
    # Start test backend service
    docker run -d --name test-backend \
        --network container:xmpp-proxy-stack \
        hashicorp/http-echo -text="Backend Response" -listen=:8000
}

teardown_suite() {
    docker rm -f test-backend
}

@test "nginx-proxy-ctl add creates working proxy" {
    # Add proxy configuration
    run docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://localhost:8000/
    
    [ "$status" -eq 0 ]
    
    # Test the proxy works
    run curl -s http://localhost:80/api/
    
    [[ "$output" =~ "Backend Response" ]]
}

@test "nginx-proxy-ctl list shows added proxy" {
    docker exec xmpp-proxy-stack nginx-proxy-ctl add /test/ http://localhost:8000/
    
    run docker exec xmpp-proxy-stack nginx-proxy-ctl list
    
    [[ "$output" =~ "/test/ -> http://localhost:8000/" ]]
}

@test "nginx-proxy-ctl remove deletes proxy" {
    docker exec xmpp-proxy-stack nginx-proxy-ctl add /temp/ http://localhost:8000/
    
    run docker exec xmpp-proxy-stack nginx-proxy-ctl remove /temp/
    
    [ "$status" -eq 0 ]
    
    # Verify proxy no longer works
    run curl -s -o /dev/null -w "%{http_code}" http://localhost:80/temp/
    
    [ "$output" = "404" ]
}

@test "proxy includes correct headers" {
    docker exec xmpp-proxy-stack nginx-proxy-ctl add /headers/ http://localhost:8000/
    
    run curl -s -H "X-Test: value" http://localhost:80/headers/
    
    # Backend would echo headers - verify X-Forwarded-* headers are set
    # (Requires test backend that returns headers)
}
```

**Example Test Suite**: `tests/integration/test_acme_flow.bats`

```bash
#!/usr/bin/env bats

load '../helpers/wait'

# Uses Pebble (Let's Encrypt test server) for ACME testing

setup_suite() {
    # Start Pebble ACME server
    docker run -d --name pebble \
        --network test-network \
        letsencrypt/pebble pebble -config /test/config/pebble-config.json
    
    # Configure container to use Pebble
    export ACME_SERVER="https://pebble:14000/dir"
}

teardown_suite() {
    docker rm -f pebble
}

@test "acme.sh issues certificate on first run" {
    # Start container (should trigger ACME flow)
    docker-compose -f tests/docker-compose.acme-test.yml up -d
    
    wait_for_log "Certificate acquired successfully" 60
    
    run docker exec xmpp-proxy-stack ls /certs/
    
    [[ "$output" =~ "fullchain.pem" ]]
    [[ "$output" =~ "privkey.pem" ]]
}

@test "acme.sh falls back to self-signed on failure" {
    # Simulate ACME failure (block port 80)
    export BLOCK_PORT_80=true
    
    docker-compose -f tests/docker-compose.acme-test.yml up -d
    
    wait_for_log "Generating self-signed certificate" 30
    
    run docker exec xmpp-proxy-stack openssl x509 -in /certs/fullchain.pem -noout -issuer
    
    [[ "$output" =~ "CN = ${XMPP_DOMAIN}" ]]  # Self-signed
}

@test "acme-renewer service runs renewal check" {
    # Mock cert near expiry (modify acme.sh state)
    # Trigger renewal check
    docker exec xmpp-proxy-stack /app/acme.sh --cron --force
    
    run docker logs xmpp-proxy-stack
    
    [[ "$output" =~ "Renew:" ]]
}
```

**Other Integration Test Suites**:

- `test_distroless_build.bats`: Verify image builds successfully for x86_64 and aarch64
- `test_horust_supervision.bats`: Test service restarts on crash
- `test_graceful_shutdown.bats`: Test SIGTERM handling and connection draining

**Test Execution**:
```bash
# Run all integration tests (slower)
bats tests/integration/

# Run specific test file
bats tests/integration/test_proxy_e2e.bats
```

### Test Helpers

**File**: `tests/helpers/docker.bash`

```bash
# Wait for Docker container to be healthy
wait_for_service() {
    local container="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if docker ps --filter "name=$container" --filter "health=healthy" | grep -q "$container"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    return 1
}

# Wait for log message to appear
wait_for_log() {
    local message="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if docker logs xmpp-proxy-stack 2>&1 | grep -q "$message"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    return 1
}
```

**File**: `tests/helpers/http.bash`

```bash
# Assert HTTP status code
assert_http_status() {
    local url="$1"
    local expected="$2"
    
    local actual=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    
    if [ "$actual" != "$expected" ]; then
        echo "Expected HTTP $expected, got $actual"
        return 1
    fi
}

# Assert response contains text
assert_response_contains() {
    local url="$1"
    local text="$2"
    
    local response=$(curl -s "$url")
    
    if ! echo "$response" | grep -q "$text"; then
        echo "Response does not contain: $text"
        echo "Actual response: $response"
        return 1
    fi
}
```

### CI/CD Integration

**GitHub Actions Workflow** (example):

```yaml
name: Test Distroless XMPP Proxy Stack

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install bats
        run: npm install -g bats
      - name: Run unit tests
        run: bats tests/unit/
        working-directory: xmpp-proxy-stack

  integration-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install bats
        run: npm install -g bats
      - name: Build distroless image
        run: docker-compose -f tests/docker-compose.test.yml build
        working-directory: xmpp-proxy-stack
      - name: Run integration tests
        run: bats tests/integration/
        working-directory: xmpp-proxy-stack
      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v3
        with:
          name: test-logs
          path: xmpp-proxy-stack/test-logs.txt
```

## Environment Variables

| Variable                | Required | Default | Description                                    |
|-------------------------|----------|---------|------------------------------------------------|
| `XMPP_DOMAIN`           | Yes      | -       | Domain for XMPP and ACME certificate           |
| `ACME_EMAIL`            | Yes      | -       | Email for ACME account registration            |
| `ACME_SERVER`           | No       | Let's Encrypt | ACME server URL (for testing with Pebble) |
| `FAIL2BAN_MAX_RETRY`    | No       | 5       | Max failed attempts before ban                 |
| `FAIL2BAN_BAN_TIME`     | No       | 1h      | Ban duration                                   |
| `FAIL2BAN_FIND_TIME`    | No       | 10m     | Time window for counting failures              |
| `NGINX_WORKER_PROCESSES`| No       | auto    | Number of nginx worker processes               |
| `PROXY_TIMEOUT`         | No       | 60s     | Default proxy timeout for upstream connections |

## File System Layout

```
/ (distroless root)
├── usr/
│   ├── sbin/
│   │   └── nginx                     # Nginx binary
│   └── local/
│       └── bin/
│           ├── horust                # Process supervisor
│           ├── xmpp-proxy            # XMPP reverse proxy
│           ├── fail2ban-rs           # Intrusion prevention
│           └── nginx-proxy-ctl       # Dynamic proxy config CLI
├── app/
│   └── acme.sh                       # ACME client
├── bin/
│   └── busybox                       # Shell for entrypoint
├── etc/
│   ├── horust/
│   │   └── services/
│   │       ├── nginx.toml
│   │       ├── xmpp-proxy.toml
│   │       ├── fail2ban-rs.toml
│   │       └── acme-renewer.toml
│   ├── nginx/
│   │   ├── nginx.conf               # Main nginx config
│   │   ├── conf.d/                  # Dynamic proxy configs
│   │   │   └── proxy-*.conf
│   │   └── templates/
│   │       └── location-proxy.conf.template
│   ├── xmpp-proxy/
│   │   └── xmpp-proxy.toml          # Generated at runtime
│   ├── fail2ban-rs/
│   │   └── config.toml              # Generated at runtime
│   ├── acme.sh/
│   │   └── default/                 # acme.sh config home
│   └── templates/                   # Runtime generation templates
│       ├── xmpp-proxy.toml.template
│       └── fail2ban-rs-config.toml.template
├── certs/                           # Mounted volume
│   ├── fullchain.pem -> /etc/acme.sh/default/...
│   └── privkey.pem -> /etc/acme.sh/default/...
├── logs/                            # Mounted volume
│   ├── nginx-stdout.log
│   ├── xmpp-proxy-stdout.log
│   ├── fail2ban-rs-stdout.log
│   └── acme-renewer-stdout.log
└── var/
    └── lib/
        └── fail2ban-rs/             # Mounted volume
            └── fail2ban-rs.db
```

## Migration Path

For users upgrading from the current Debian-slim based stack:

### 1. Backup Current Setup
```bash
# Backup certificates
cp -r /srv/xmpp/certs /srv/xmpp/certs.backup

# Backup configs
docker exec xmpp-proxy-stack tar czf /tmp/configs.tar.gz /etc/xmpp-proxy /etc/fail2ban-rs
docker cp xmpp-proxy-stack:/tmp/configs.tar.gz ./configs-backup.tar.gz
```

### 2. Update Docker Compose

The `docker-compose.yaml` service definition changes:

**Before**:
```yaml
xmpp-proxy-stack:
  build:
    context: ./xmpp-proxy-stack
    args:
      XMPP_PROXY_VERSION: ${XMPP_PROXY_VERSION:-latest}
      FAIL2BAN_RS_VERSION: ${FAIL2BAN_RS_VERSION:-latest}
```

**After**:
```yaml
xmpp-proxy-stack:
  build:
    context: ./xmpp-proxy-stack
    dockerfile: Dockerfile.distroless  # New dockerfile
    args:
      XMPP_PROXY_VERSION: ${XMPP_PROXY_VERSION:-latest}
      FAIL2BAN_RS_VERSION: ${FAIL2BAN_RS_VERSION:-latest}
      HORUST_VERSION: ${HORUST_VERSION:-0.1.8}
```

### 3. Rebuild and Restart

```bash
# Build new distroless image
docker-compose build xmpp-proxy-stack

# Stop old container
docker-compose stop xmpp-proxy-stack

# Start new container (entrypoint will reuse existing certs)
docker-compose up -d xmpp-proxy-stack

# Verify services are running
docker exec xmpp-proxy-stack ps aux
```

### 4. Test nginx-proxy-ctl

```bash
# Add a test proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl add /test/ http://localhost:8000/

# List proxies
docker exec xmpp-proxy-stack nginx-proxy-ctl list

# Remove test proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /test/
```

### Rollback Plan

If issues occur:

```bash
# Stop distroless container
docker-compose stop xmpp-proxy-stack

# Restore old Dockerfile
mv xmpp-proxy-stack/Dockerfile.distroless xmpp-proxy-stack/Dockerfile.distroless.new
mv xmpp-proxy-stack/Dockerfile.debian xmpp-proxy-stack/Dockerfile

# Rebuild with old setup
docker-compose build xmpp-proxy-stack
docker-compose up -d xmpp-proxy-stack

# Restore configs if needed
docker cp configs-backup.tar.gz xmpp-proxy-stack:/tmp/
docker exec xmpp-proxy-stack tar xzf /tmp/configs-backup.tar.gz -C /
```

## Security Considerations

### Distroless Benefits

- **No shell**: Eliminates shell-based exploits
- **No package manager**: Prevents runtime package installation
- **Minimal attack surface**: Only runtime dependencies included
- **Reduced CVE exposure**: Fewer packages = fewer vulnerabilities

### Remaining Attack Vectors

1. **Horust**: Process supervisor has elevated privileges (PID 1)
   - Mitigation: Use official releases, verify checksums

2. **nginx**: Web server exposed on public ports
   - Mitigation: Keep updated, use minimal config, fail2ban-rs protection

3. **acme.sh**: Shell script with external network access
   - Mitigation: Runs only periodically, no persistent shell access

4. **Volume Permissions**: Shared volumes with host
   - Mitigation: Use nonroot user (UID 65532), set correct host permissions

### Runtime Security

- **Capabilities**: Only `NET_ADMIN` for fail2ban-rs (nftables/iptables)
- **Read-only root**: Consider `--read-only` flag with writable volumes
- **No privileged mode**: Not required with host networking

## Future Enhancements

**Out of scope for initial implementation**:

1. **Prometheus Metrics**: Export service health and proxy metrics
2. **Webhook Notifications**: Alert on certificate renewal failures or service crashes
3. **Advanced Load Balancing**: Upstream health checks and failover
4. **Rate Limiting**: Per-proxy rate limiting via nginx
5. **mTLS Support**: Client certificate authentication for proxied services
6. **Web UI**: Browser-based proxy management (vs CLI only)
7. **Container Label Watchers**: Real-time Docker event monitoring for auto-discovery
8. **Multi-Domain Support**: ACME certificates for multiple domains

## Appendix A: Example docker-compose.yaml

```yaml
services:
  prosody:
    image: prosodyim/prosody:13.0
    container_name: prosody
    restart: unless-stopped
    env_file: .env
    environment:
      PROSODY_ADMINS: ${XMPP_ADMIN:-admin@${XMPP_DOMAIN}}
      PROSODY_VIRTUAL_HOSTS: ${XMPP_DOMAIN}
      PROSODY_LOGLEVEL: ${PROSODY_LOGLEVEL:-info}
      PROSODY_STORAGE: internal
      PROSODY_ENABLE_MODULES: mam,carbons,csi_simple,ping,admin_adhoc,admin_shell,http,admin_web2,bosh
      PROSODY_CERTIFICATES: /certs
      PROSODY_RETENTION_DAYS: ${PROSODY_RETENTION_DAYS:-90}
    volumes:
      - /srv/xmpp/prosody:/var/lib/prosody
      - /srv/xmpp/certs:/certs:ro
      - /srv/xmpp/logs/prosody:/var/log/prosody
      - ./xmpp-proxy-stack/templates/prosody-proxy.cfg.lua:/etc/prosody/conf.d/proxy.cfg.lua:ro
    ports:
      - "127.0.0.1:15222:5222"
      - "127.0.0.1:15269:5269"
      - "0.0.0.0:5280:5280"
    networks:
      - xmpp-internal
    healthcheck:
      test: ["CMD", "prosodyctl", "status"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  xmpp-proxy-stack:
    build:
      context: ./xmpp-proxy-stack
      dockerfile: Dockerfile.distroless
      args:
        XMPP_PROXY_VERSION: ${XMPP_PROXY_VERSION:-latest}
        FAIL2BAN_RS_VERSION: ${FAIL2BAN_RS_VERSION:-latest}
        HORUST_VERSION: ${HORUST_VERSION:-0.1.8}
    container_name: xmpp-proxy-stack
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    env_file: .env
    volumes:
      - /srv/xmpp/certs:/certs
      - /srv/xmpp/logs:/logs
      - /srv/xmpp/fail2ban:/var/lib/fail2ban-rs
      - /srv/xmpp/acme:/etc/acme.sh
    depends_on:
      prosody:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "/usr/sbin/nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  xmpp-internal:
    driver: bridge
```

## Appendix B: Example .env File

```bash
# Required Configuration
XMPP_DOMAIN=chat.example.com
ACME_EMAIL=admin@example.com

# Optional Configuration
XMPP_ADMIN=admin@chat.example.com
PROSODY_LOGLEVEL=info
ENABLE_WEB_ADMIN=false
FAIL2BAN_MAX_RETRY=5
FAIL2BAN_BAN_TIME=1h
FAIL2BAN_FIND_TIME=10m

# Binary Versions
XMPP_PROXY_VERSION=latest
FAIL2BAN_RS_VERSION=latest
HORUST_VERSION=0.1.8

# ACME Configuration
ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory  # Production
# ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory  # Staging

# Nginx Configuration
NGINX_WORKER_PROCESSES=auto
PROXY_TIMEOUT=60s
```

## Appendix C: Complete nginx-proxy-ctl Usage

```bash
# Add proxy with all options
nginx-proxy-ctl add /api/ http://backend:8000/ \
    --websocket \
    --header "X-Custom: value" \
    --header "X-Another: test" \
    --timeout 120s

# Remove proxy
nginx-proxy-ctl remove /api/

# List all proxies (human-readable)
nginx-proxy-ctl list
# Output:
# /api/ -> http://backend:8000/ [websocket] [timeout: 120s]
#   X-Custom: value
#   X-Another: test

# List all proxies (JSON for scripting)
nginx-proxy-ctl list --json
# Output:
# [
#   {
#     "location": "/api/",
#     "upstream": "http://backend:8000/",
#     "websocket": true,
#     "timeout": "120s",
#     "headers": {
#       "X-Custom": "value",
#       "X-Another": "test"
#     }
#   }
# ]

# Validate current nginx configuration
nginx-proxy-ctl validate
# Output:
# ✓ nginx configuration is valid

# Auto-discover containers with labels
nginx-proxy-ctl discover
# Output:
# Discovered 2 containers with proxy labels:
#   api-backend: /api/ -> http://172.17.0.3:8000/
#   web-app: /app/ -> http://172.17.0.4:3000/ [websocket]
# 
# Add these proxies? [y/N]

# Watch for container events (runs in foreground)
nginx-proxy-ctl discover --watch
# Output:
# Watching for container events...
# [2026-07-29 10:30:00] Container api-backend started: added /api/
# [2026-07-29 10:35:00] Container api-backend stopped: removed /api/
```

---

## Summary

This design migrates the xmpp-proxy-stack to a hardened distroless base while adding dynamic nginx proxy management capabilities. The all-in-one container approach maintains deployment simplicity, Horust provides robust process supervision, and the bash-based nginx-proxy-ctl CLI enables runtime configuration with full TDD coverage via bats tests.

**Key Deliverables**:
1. Multi-stage Dockerfile producing distroless image
2. Horust service definitions for all processes
3. nginx-proxy-ctl CLI with add/remove/list/validate/discover commands
4. Comprehensive bats test suites (unit + integration)
5. acme.sh integration for automated certificate management
6. Migration guide and rollback plan

**Success Criteria**:
- All tests pass (unit + integration)
- Container builds for x86_64 and aarch64
- Successful certificate acquisition via ACME
- Dynamic proxy configuration works end-to-end
- Graceful shutdown drains connections properly
- Security hardening verified (no shell, minimal packages)
