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

## 2. Component: xmpp-proxy (Rust)

### 2.1 Feature Flag System

**Direction flags (pick one or more):**
- `c2s-incoming` - Accept incoming client-to-server connections
- `c2s-outgoing` - Create outgoing client-to-server connections
- `s2s-incoming` - Accept incoming server-to-server connections
- `s2s-outgoing` - Create outgoing server-to-server connections

**Protocol flags (pick one or more):**
- `tls` - STARTTLS and Direct TLS support
- `quic` - QUIC protocol support (XEP-0467)
- `websocket` - WebSocket support (RFC 7395 for C2S, XEP-0468 for S2S)
  - Note: `websocket` + incoming direction also enables incoming TLS support
- `webtransport` - WebTransport support (W3C spec)
  - **Requires:** Must also enable `quic` feature

**TLS CA root certificates (pick exactly one, unless only `c2s-incoming`):**
- `tls-ca-roots-native` - Load CA certificates from operating system
  - Use when: Deploying on systems with managed CA bundles
  - Pros: Automatically picks up OS updates
  - Cons: Depends on OS certificate store
- `tls-ca-roots-bundled` - Bundle webpki-roots CA certificates in binary
  - Use when: Need reproducible builds, static binaries
  - Pros: Self-contained, no OS dependency
  - Cons: Must rebuild to update CA bundle

**Cannot use both together.** Mutually exclusive by design.

**TLS cryptographic provider (pick exactly one):**
- `tls-ring` - Use ring cryptography library (default)
- `tls-aws-lc-rs` - Use AWS libcrypto (aws-lc) via Rust bindings
- `tls-aws-lc-rs-fips` - Use FIPS-validated AWS libcrypto

**Cannot use multiple TLS providers together.**

**Optional features:**
- `logging` - Enables env_logger and structured logging
- `systemd` - Socket activation support
- `console` - Tokio console debugging support

**Feature flag validation:**
- Use `./check-all-features.sh` to verify all valid combinations compile
- Script tests all supported permutations automatically
- Run before committing changes that affect feature-gated code

### 2.2 Building Workflows

**Default build (all features):**
```bash
cargo build --release
```

**Custom feature build examples:**

Reverse proxy only (STARTTLS/TLS):
```bash
cargo build --release --no-default-features \
  --features c2s-incoming,s2s-incoming,tls,tls-ca-roots-native,tls-ring
```

Reverse proxy with QUIC support:
```bash
cargo build --release --no-default-features \
  --features c2s-incoming,s2s-incoming,tls,quic,tls-ca-roots-native,tls-ring
```

Outgoing proxy only:
```bash
cargo build --release --no-default-features \
  --features c2s-outgoing,s2s-outgoing,tls,quic,tls-ca-roots-bundled,tls-ring
```

Full-featured build with WebSocket and WebTransport:
```bash
cargo build --release --no-default-features \
  --features c2s-incoming,c2s-outgoing,s2s-incoming,s2s-outgoing,\
tls,quic,websocket,webtransport,logging,tls-ca-roots-native,tls-ring
```

**When to use custom builds:**
- Minimize binary size for specific deployment scenarios
- Test feature-gated code in isolation
- Debug feature flag interactions

### 2.3 Testing

**Unit tests:**
```bash
cargo test
```

**Network-dependent tests:**
```bash
cargo test --features net-test
```
- May be flaky (depends on external network)
- Tests SRV resolution, DNS lookups, external connectivity

**Feature-specific tests:**
- Some tests are feature-gated
- Example: WebSocket tests only compile with `websocket` feature
- Run full build before assuming test failure is code issue

**Pre-commit requirements:**
- All `cargo test` must pass
- `./check-all-features.sh` should succeed
- Integration tests (`integration/test.sh`) must pass

### 2.4 Code Structure

**Core files:**
- `src/main.rs` - Entry point
  - Command-line argument parsing (config file path)
  - Config file loading (TOML deserialization)
  - Logging initialization
  - Signal handling (graceful shutdown)
  - Launches incoming/outgoing listeners based on config

- `src/context.rs` - Shared context and configuration
  - Runtime configuration state
  - Shared resources across connections

- `src/in_out.rs` - Core proxy dispatch logic
  - Incoming connection handling
  - Outgoing connection establishment
  - Protocol negotiation
  - Bidirectional data forwarding

**Protocol-specific modules:**
- `src/tls/` - STARTTLS and Direct TLS implementation
  - Certificate loading and validation
  - TLS handshake handling
  - Stream wrapping

- `src/quic/` - QUIC protocol support
  - Quinn-based QUIC implementation
  - Bidirectional stream handling
  - Connection migration

- `src/websocket/` - WebSocket transport
  - HTTP upgrade handling
  - WebSocket frame processing
  - Integration with TLS

- `src/webtransport/` - WebTransport implementation
  - Built on QUIC foundation
  - HTTP/3 upgrade mechanism

**XMPP-specific logic:**
- `src/srv.rs` - Service discovery
  - SRV record resolution (_xmpp-client._tcp, _xmpp-server._tcp)
  - host-meta and host-meta2 lookups (XEP-0156)
  - POSH (PKIX Over Secure HTTP) support (RFC 7711)
  - Fallback chain for connection establishment

- `src/stanzafilter.rs` - Stanza size limiting
  - **Key constraint:** No full XML parser
  - Byte-stream analysis to detect stanza boundaries
  - Configurable size limits
  - Minimal overhead

- `src/verify.rs` - S2S certificate validation
  - Domain verification for server-to-server
  - Certificate chain validation
  - Integration with CA roots

**Utility modules:**
- `src/slicesubsequence.rs` - Byte slice utilities
- `src/systemd.rs` - Systemd socket activation
- `src/common/` - Shared types and helpers

### 2.5 Common Development Tasks

**Adding new protocol support:**
1. Create new module in `src/` (e.g., `src/newproto/`)
2. Add feature flag to `Cargo.toml` `[features]`
3. Implement protocol-specific connection handling
4. Integrate into `in_out.rs` dispatch logic (feature-gated)
5. Add tests (unit + integration)
6. Update `check-all-features.sh` if new feature combinations

**Modifying stanza filtering:**
- Edit `src/stanzafilter.rs`
- **Critical:** Cannot use full XML parser (performance requirement)
- Work with byte streams, detect element boundaries
- Test with various stanza sizes and nesting levels
- Verify no performance regression

**Updating dependencies:**
1. Modify `Cargo.toml`
2. Run `cargo update`
3. Check security policy: `cargo deny check`
4. Review `deny.toml` for any new violations
5. Run full test suite
6. Test feature flag combinations

**Debugging tips:**
- Enable `logging` feature for detailed logs
- Use `RUST_LOG=debug` environment variable
- Enable `console` feature + tokio-console for async debugging
- Check for feature flag mismatches if code doesn't compile

## 3. Component: xmpp-proxy-stack (Docker)

### 3.1 What's Bundled

The `xmpp-proxy-stack` container includes:

1. **xmpp-proxy** - The Rust proxy binary
   - Built from source (dev) or downloaded as static binary (production)
   - Listens on public ports: 5222, 5223, 5269, 443/udp
   - Forwards to Prosody via PROXY protocol

2. **nginx** - HTTP/HTTPS server
   - Listens on port 80 (HTTP)
   - Serves ACME HTTP-01 challenges at `/.well-known/acme-challenge/`
   - Dynamic reverse proxy capability via nginx-proxy-ctl
   - Redirects HTTP to HTTPS for non-ACME paths

3. **fail2ban-rs** - Rust-based fail2ban implementation
   - Monitors xmpp-proxy logs for abuse patterns
   - Configurable ban thresholds and durations
   - Persists ban state to `/var/lib/fail2ban-rs`

4. **acme.sh** - ACME client for Let's Encrypt
   - Runs as cron job (daily certificate renewal check)
   - Uses HTTP-01 challenge via nginx
   - Automatically renews certificates within 30 days of expiration
   - Falls back to self-signed cert if ACME fails

5. **horust** - Process supervisor
   - Manages all services above
   - Handles dependencies (e.g., xmpp-proxy waits for certs)
   - Proper signal forwarding for graceful shutdown
   - Service definitions in `/etc/horust/services/`

6. **busybox** - Minimal POSIX utilities
   - Workaround for distroless limitations
   - Provides: sh, ls, cat, grep, etc.
   - Access via: `docker exec xmpp-proxy-stack /bin/busybox sh`

### 3.2 Build Variants

**Production (`docker-compose.yaml`):**
```yaml
services:
  xmpp-proxy-stack:
    image: ghcr.io/nikescar/xmpp-proxy-stack:${XMPP_PROXY_STACK_TAG:-latest}
```
- Pulls pre-built image from GitHub Container Registry
- No build step required
- Fast deployment
- Use for: Production, stable deployments

**Development (`docker-compose.dev.yaml`):**
```yaml
services:
  xmpp-proxy-stack:
    build:
      context: ./xmpp-proxy-stack
      dockerfile: Dockerfile
```
- Builds from source using local Dockerfile
- Build arguments: XMPP_PROXY_VERSION, FAIL2BAN_RS_VERSION, HORUST_VERSION
- Slower first build (Rust compilation)
- Use for: Testing Dockerfile changes, custom builds, local development

**When to use dev variant:**
- Modifying `xmpp-proxy-stack/Dockerfile`
- Changing `docker-entrypoint.sh` startup logic
- Updating `nginx-proxy-ctl` script
- Modifying horust service definitions
- Testing new template configurations
- Debugging container build issues

### 3.3 Key Files in xmpp-proxy-stack/

**Dockerfile** - Multi-stage build
- Stage 1: Builder (Rust toolchain)
  - Downloads or builds xmpp-proxy binary
  - Downloads fail2ban-rs and horust binaries
  - Compiles any additional tools
- Stage 2: Runtime (distroless base)
  - Copies binaries from builder
  - Adds nginx, acme.sh, busybox
  - Sets up directory structure
  - Final image ~50-100MB

**docker-entrypoint.sh** - Container initialization
- Runs on container start
- Responsibilities:
  1. Check for TLS certificates in `/certs/`
  2. Generate self-signed cert if missing (bootstrap)
  3. Set up environment variables for services
  4. Launch horust supervisor
  5. Handle signals for graceful shutdown

**nginx-proxy-ctl** - Dynamic proxy configuration tool
- Shell script for runtime nginx management
- No container rebuild required
- Commands:
  - `add <path> <upstream> [--websocket]` - Add reverse proxy
  - `remove <path>` - Remove proxy
  - `list` - Show configured proxies
  - `validate` - Check nginx config syntax
- Implementation: Modifies `/etc/nginx/conf.d/proxy.conf`, runs `nginx -s reload`

**horust-services/** - Service supervisor configs
- `xmpp-proxy.toml` - xmpp-proxy service definition
  - Command, environment, restart policy
  - Start delay (waits for certs)
- `nginx.toml` - nginx service
- `fail2ban-rs.toml` - fail2ban service
- `acme-cron.toml` - Certificate renewal cron
- Each file defines: command, working_dir, restart strategy, start_delay

**templates/** - Configuration file templates
- `nginx.conf.template` - Main nginx config
  - Port 80 listener for ACME
  - Include directory for dynamic proxies
- `xmpp-proxy.toml.template` - xmpp-proxy runtime config
  - Listen addresses, TLS cert paths
  - Prosody backend addresses
  - PROXY protocol settings
- `prosody-proxy.cfg.lua` - Prosody configuration snippet
  - Mounts into Prosody container
  - Configures PROXY protocol ports
  - Sets proxy_secure flag

### 3.4 Development Workflow

**Typical iteration cycle:**

1. **Make changes**
   - Edit Dockerfile, scripts, templates, or horust configs
   - Example: Modify nginx template to add new default route

2. **Build the image**
   ```bash
   docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack
   ```
   - Only rebuilds changed layers (Docker cache)
   - Rust compilation can take 5-15 minutes on first build
   - Subsequent builds faster if only scripts/templates changed

3. **Test locally**
   ```bash
   docker compose -f docker-compose.dev.yaml up -d
   ```
   - Starts both containers (prosody + xmpp-proxy-stack)
   - Check logs: `docker logs -f xmpp-proxy-stack`

4. **Validate functionality**
   - XMPP connection test: Use XMPP client to connect
   - Certificate check: `docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/`
   - nginx test: `curl -I http://localhost/`
   - Service status: Check logs for all horust services

5. **Iterate or commit**
   - If issues: Fix, rebuild, retest
   - If working: Commit changes, optionally push image to registry

**Quick validation checklist:**
- [ ] Both containers running: `docker ps`
- [ ] Ports listening: `ss -tlnp | grep -E ':(5222|5223|5269|80)'`
- [ ] Prosody healthy: `docker logs prosody` (no errors)
- [ ] xmpp-proxy started: `docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log`
- [ ] nginx responding: `curl http://localhost/`
- [ ] Certs exist: `docker exec xmpp-proxy-stack /bin/busybox ls /certs/`

### 3.5 nginx-proxy-ctl Usage

**Purpose:** Add reverse proxy routes without rebuilding container.

**Examples:**

Add API proxy:
```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://localhost:8000/
```

Add WebSocket proxy:
```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket
```

List current proxies:
```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl list
```

Remove a proxy:
```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /api/
```

Validate nginx config:
```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl validate
```

**Use cases:**
- Expose Prosody admin API externally
- Add WebSocket endpoint for custom services
- Proxy to monitoring dashboards
- Temporary debugging endpoints

**How it works:**
1. Script writes to `/etc/nginx/conf.d/proxy-<hash>.conf`
2. Runs `nginx -t` to validate syntax
3. Runs `nginx -s reload` to apply changes
4. No container restart needed

### 3.6 Environment Variables

**Required (.env file):**
```bash
XMPP_DOMAIN=chat.example.com          # Your XMPP domain
ACME_EMAIL=admin@example.com          # Let's Encrypt notifications
```

**Optional runtime configuration:**
```bash
XMPP_ADMIN=admin@chat.example.com     # Admin JID (default: admin@${XMPP_DOMAIN})
PROSODY_LOGLEVEL=info                 # debug|info|warn|error
PROSODY_RETENTION_DAYS=90             # Message archive retention
FAIL2BAN_MAX_RETRY=5                  # Attempts before ban
FAIL2BAN_BAN_TIME=1h                  # Ban duration
FAIL2BAN_FIND_TIME=10m                # Detection window
```

**Build-time (docker-compose.dev.yaml only):**
```bash
XMPP_PROXY_VERSION=latest             # Git tag or 'latest'
FAIL2BAN_RS_VERSION=latest            # fail2ban-rs version
HORUST_VERSION=0.1.13                 # horust version
```

**Production image tag (docker-compose.yaml only):**
```bash
XMPP_PROXY_STACK_TAG=latest           # 'latest' or specific version (e.g., v1.0.0)
```

### 3.7 Common Development Tasks

**Modify horust service definitions:**
1. Edit files in `xmpp-proxy-stack/horust-services/`
2. Example: Change xmpp-proxy log level, add environment variable
3. Rebuild: `docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack`
4. Test: `docker compose -f docker-compose.dev.yaml up -d`
5. Verify: Check service logs for expected behavior

**Update nginx configuration:**
1. Edit `xmpp-proxy-stack/templates/nginx.conf.template`
2. Example: Add new location block, change SSL settings
3. Rebuild and test as above
4. Validate: `docker exec xmpp-proxy-stack nginx -t`

**Debug distroless container:**
- **Limited shell access:**
  ```bash
  docker exec -it xmpp-proxy-stack /bin/busybox sh
  ```
  - Only busybox commands available
  - No package manager, no apt/yum

- **View logs:**
  ```bash
  docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log
  docker exec xmpp-proxy-stack /bin/busybox cat /logs/nginx-stderr.log
  ```

- **Check processes:**
  ```bash
  docker exec xmpp-proxy-stack /bin/busybox ps aux
  ```

- **Inspect files:**
  ```bash
  docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/
  docker exec xmpp-proxy-stack /bin/busybox cat /etc/nginx/nginx.conf
  ```

**Change binary versions:**
1. Edit `.env` file (dev build only):
   ```bash
   XMPP_PROXY_VERSION=v1.2.0
   FAIL2BAN_RS_VERSION=v0.5.0
   ```
2. Force rebuild (no cache):
   ```bash
   docker compose -f docker-compose.dev.yaml build --no-cache xmpp-proxy-stack
   ```

**Add new supervised service:**
1. Create `xmpp-proxy-stack/horust-services/newservice.toml`:
   ```toml
   command = "/usr/local/bin/newservice"
   start-delay = "5s"
   restart-strategy = "always"
   ```
2. Ensure binary is copied in Dockerfile
3. Rebuild and test
