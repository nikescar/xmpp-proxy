# CLAUDE.md Design Specification

**Date:** 2026-07-31  
**Purpose:** Create comprehensive CLAUDE.md for xmpp-proxy project to guide Claude Code in assisting with both Rust development and Docker infrastructure work.

## Overview

This specification defines the structure and content of CLAUDE.md for the xmpp-proxy project. The document will serve dual audiences:
1. Contributors developing xmpp-proxy Rust features
2. Developers working on the Docker infrastructure and deployment stack

The design follows an **architecture-first approach**, emphasizing understanding of how components interact (containers, networking, PROXY protocol) before diving into implementation details.

## Design Rationale

### Why Architecture-First?

The xmpp-proxy project has a complex multi-service Docker architecture with specific networking requirements (host networking for PROXY protocol, distroless containers with horust supervision). Understanding this architecture is critical before making changes. By presenting the mental model first, developers can:

- Understand why certain design decisions were made (e.g., host networking, bundled services)
- Know which component to modify for a given task
- Avoid common mistakes (e.g., changing to bridge networking, incorrect volume permissions)

### Scope and Boundaries

**In scope:**
- Project architecture and component interaction
- Rust development workflows (feature flags, building, testing)
- Docker development workflows (building images, modifying stack)
- Integration testing with podman
- Debugging and troubleshooting guidance
- Quick reference for common lookups

**Out of scope:**
- Detailed XMPP protocol specifications (reference external docs)
- Production deployment guides beyond local testing
- User-facing documentation (that belongs in README.md)

## Document Structure

### 1. Project Overview & Architecture

**Purpose:** Build the complete mental model of how xmpp-proxy works and how its components interact.

**Content:**

**1.1 What xmpp-proxy Does**
- Reverse proxy mode: TLS termination for incoming connections → plain TCP to Prosody
- Outgoing proxy mode: Plain TCP from Prosody → TLS to remote servers
- Supported protocols: STARTTLS, Direct TLS, QUIC, WebSocket, WebTransport
- Key feature: Stanza size limiting without full XML parsing

**1.2 Two-Container Architecture**
- `prosody` container:
  - Runs official Prosody 13.0 image
  - Listens on localhost only: 15222 (C2S), 15269 (S2S), 15280 (HTTP)
  - Configured to accept PROXY protocol headers
  - Uses internal bridge network for container-to-container communication
  
- `xmpp-proxy-stack` container:
  - Bundles: xmpp-proxy + nginx + fail2ban-rs + acme.sh + horust
  - Uses host networking (critical for PROXY protocol)
  - Distroless base image for security
  - Single container supervision via horust

**1.3 Critical Networking Concepts**

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

**1.4 Data Persistence & Volumes**

All data stored in `/srv/xmpp/`:

- `/srv/xmpp/prosody` → Container `/var/lib/prosody`
  - Prosody database, user data, offline messages
  - **Critical:** Must be owned by UID 100:102 (prosody user in container)
  - Common issue: Docker auto-creates as root, causing crash loop
  
- `/srv/xmpp/certs` → Shared between both containers
  - TLS certificates and private keys
  - Written by acme.sh in xmpp-proxy-stack
  - Read by Prosody (if configured for TLS) and xmpp-proxy
  
- `/srv/xmpp/logs` → Container `/logs` (xmpp-proxy-stack only)
  - xmpp-proxy logs: `/logs/xmpp-proxy-stdout.log`, `/logs/xmpp-proxy-stderr.log`
  - nginx logs: `/logs/nginx-stdout.log`, `/logs/nginx-stderr.log`
  - fail2ban-rs logs: `/logs/fail2ban-rs-stdout.log`
  
- `/srv/xmpp/fail2ban` → Container `/var/lib/fail2ban-rs`
  - Ban state persistence
  - Survives container restarts
  
- `/srv/xmpp/acme` → Container `/etc/acme.sh`
  - acme.sh account info and renewal state
  - Prevents re-registration on container restart

**1.5 The Distroless + Horust Model**

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

### 2. Component: xmpp-proxy (Rust)

**Purpose:** Guide Rust development work on the core proxy binary.

**Content:**

**2.1 Feature Flag System**

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

**2.2 Building Workflows**

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

**2.3 Testing**

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

**2.4 Code Structure**

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

**2.5 Common Development Tasks**

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

### 3. Component: xmpp-proxy-stack (Docker)

**Purpose:** Guide Docker infrastructure development and stack customization.

**Content:**

**3.1 What's Bundled**

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

**3.2 Build Variants**

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

**3.3 Key Files in xmpp-proxy-stack/**

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

**3.4 Development Workflow**

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

**3.5 nginx-proxy-ctl Usage**

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

**3.6 Environment Variables**

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

**3.7 Common Development Tasks**

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

### 4. Component: Integration & Testing

**Purpose:** Guide end-to-end validation and testing workflows.

**Content:**

**4.1 Integration Test Suite**

**Location:** `integration/test.sh`

**Purpose:**
- Validate xmpp-proxy with real XMPP connections
- Test all supported protocols in realistic scenarios
- Prevent regressions before commits

**Technology:**
- Uses **rootless podman** (not Docker)
- Spins up temporary containers for testing
- Simulates client and server XMPP connections
- Cleans up after test run

**What it tests:**
- STARTTLS connection flow
- Direct TLS connections
- QUIC protocol (if feature enabled)
- WebSocket transport (if feature enabled)
- Certificate validation
- PROXY protocol header passing
- Stanza filtering under size limits

**Requirements:**
- Rootless podman configured (see [Arch Wiki: Rootless Podman](https://wiki.archlinux.org/title/Podman#Rootless_Podman))
- xmpp-proxy binary built with appropriate features
- Network connectivity for test containers

**4.2 Running Integration Tests**

**Full test suite:**
```bash
cd integration
./test.sh
```

**Expected output:**
- Test containers created
- XMPP connections established
- Protocol-specific validations
- Cleanup of test resources
- Summary: PASS/FAIL for each test

**When tests fail:**

1. **Check feature flags:**
   - Test requires QUIC but binary built without `quic` feature?
   - Rebuild with correct features: `cargo build --release`

2. **Verify podman setup:**
   - Rootless podman working? `podman run hello-world`
   - Check user namespaces: `cat /proc/sys/user/max_user_namespaces` (should be > 0)

3. **Inspect test logs:**
   - Tests may leave logs in `integration/logs/` (check test.sh for details)
   - Use `podman logs <container-name>` if containers not cleaned up

4. **Network issues:**
   - Firewall blocking ports?
   - SELinux denials? Check `ausearch -m avc -ts recent`

**Debugging specific tests:**
- Edit `integration/test.sh` to run individual test functions
- Add `set -x` for verbose output
- Disable cleanup to inspect container state

**Pre-commit requirement:**
All integration tests must pass before pushing commits. This ensures:
- Feature flags work correctly
- Protocol implementations maintain compatibility
- No regressions in core functionality

**4.3 Testing the Full Docker Stack**

**Quick validation after changes:**

1. **Start the stack:**
   ```bash
   docker compose -f docker-compose.dev.yaml up -d
   ```

2. **Verify containers running:**
   ```bash
   docker ps
   ```
   Expected: Both `prosody` and `xmpp-proxy-stack` in "Up" state

3. **Check port bindings:**
   ```bash
   ss -tlnp | grep -E ':(5222|5223|5269|80|5280)'
   ```
   Expected: Ports 5222, 5223, 5269, 80, 5280 in LISTEN state

4. **Verify logs:**
   ```bash
   docker logs prosody
   docker logs xmpp-proxy-stack
   ```
   Look for: No errors, services started successfully

5. **Test XMPP connection:**
   - Use XMPP client (Gajim, Conversations, etc.)
   - Connect to `user@localhost` (if testing locally with /etc/hosts entry)
   - Verify connection succeeds, check prosody logs for real client IP

6. **Verify certificates:**
   ```bash
   docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/
   ```
   Expected: `fullchain.cer`, `le.key` exist (self-signed on first run, ACME later)

**4.4 Testing Specific Features**

**QUIC protocol:**
1. Verify QUIC feature enabled: `xmpp-proxy --version` or check Cargo.toml
2. Check port 443/udp listening: `ss -unp | grep :443`
3. Test with QUIC-capable XMPP client
4. Monitor logs: `docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log | grep -i quic`

**WebSocket:**
1. Verify port 5280 accessible: `curl http://localhost:5280/`
2. Test WebSocket endpoint: Use browser console or wscat
   ```bash
   wscat -c ws://localhost:5280/xmpp-websocket
   ```
3. Check Prosody logs for WebSocket connections

**PROXY protocol:**
1. Connect XMPP client from external IP
2. Check Prosody logs: `docker logs prosody | grep -i "c2s.*connected"`
3. Verify real client IP shown (not 127.0.0.1)
4. If showing 127.0.0.1: Check host networking enabled, mod_net_proxy loaded

**fail2ban-rs:**
1. Trigger rate limit (multiple failed auth attempts)
2. Check ban state:
   ```bash
   docker exec xmpp-proxy-stack /bin/busybox cat /var/lib/fail2ban-rs/state
   ```
3. Verify IP banned, connections rejected

**Certificate auto-renewal:**
1. Ensure DNS points to server, port 80 accessible externally
2. Trigger renewal manually:
   ```bash
   docker exec xmpp-proxy-stack /root/.acme.sh/acme.sh --renew -d $XMPP_DOMAIN --force
   ```
3. Check logs for ACME challenge success
4. Verify services reloaded with new cert

**4.5 Debugging Workflows**

**Rust panic or crash:**
1. Check stderr log:
   ```bash
   docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stderr.log
   ```
2. Look for stack trace, panic message
3. Enable debug logging: Set `RUST_LOG=debug` in horust service config
4. Reproduce issue, check detailed logs

**Connection refused errors:**
1. Verify Prosody running: `docker exec prosody prosodyctl status`
2. Check port mappings: Prosody listening on 15222, 15269?
   ```bash
   docker exec prosody ss -tln | grep -E ':(15222|15269)'
   ```
3. Verify networking mode: `docker inspect xmpp-proxy-stack | grep NetworkMode`
   - Should be "host" for xmpp-proxy-stack
4. Check firewall: `iptables -L` or `firewall-cmd --list-all`

**TLS/certificate errors:**
1. Verify cert files exist and are readable:
   ```bash
   docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/
   ```
2. Check cert validity:
   ```bash
   openssl x509 -in /srv/xmpp/certs/fullchain.cer -noout -text
   ```
3. Verify domain matches: Certificate CN/SAN should match XMPP_DOMAIN
4. Check acme.sh logs for acquisition errors

**PROXY protocol not working:**
1. Confirm host networking: `docker inspect xmpp-proxy-stack | grep NetworkMode`
2. Verify Prosody config: `docker exec prosody cat /etc/prosody/conf.d/proxy.cfg.lua`
3. Check mod_net_proxy loaded: `docker logs prosody | grep net_proxy`
4. Test manually: Send raw PROXY header to Prosody:
   ```bash
   echo -e "PROXY TCP4 203.0.113.45 127.0.0.1 54321 15222\r\n" | nc localhost 15222
   ```

**Permission errors:**
1. Most common: `/srv/xmpp/prosody` owned by root
2. Fix:
   ```bash
   sudo chown -R 100:102 /srv/xmpp/prosody /srv/xmpp/logs/prosody
   ```
3. Verify:
   ```bash
   ls -la /srv/xmpp/prosody
   ```
   Should show `100:102` or `prosody:prosody`

**Service not starting in horust:**
1. Check horust logs:
   ```bash
   docker logs xmpp-proxy-stack 2>&1 | grep -i horust
   ```
2. Inspect service definitions:
   ```bash
   docker exec xmpp-proxy-stack /bin/busybox cat /etc/horust/services/xmpp-proxy.toml
   ```
3. Common issues:
   - Start delay too short (service dependency not ready)
   - Command path incorrect
   - Missing environment variables

### 5. Reference

**Purpose:** Quick-reference material for common lookups and gotchas.

**Content:**

**5.1 Feature Flag Quick Reference**

**Valid combinations (examples):**

Minimal reverse proxy (TLS only):
```
c2s-incoming,s2s-incoming,tls,tls-ring
```

Full-featured reverse + outgoing:
```
c2s-incoming,c2s-outgoing,s2s-incoming,s2s-outgoing,
tls,quic,websocket,webtransport,logging,
tls-ca-roots-native,tls-ring
```

Outgoing proxy only:
```
c2s-outgoing,s2s-outgoing,tls,quic,
tls-ca-roots-bundled,tls-aws-lc-rs
```

**Invalid combinations (will not compile):**

Both CA root options:
```
❌ tls-ca-roots-native,tls-ca-roots-bundled
```

WebTransport without QUIC:
```
❌ webtransport  (missing quic feature)
```

Outgoing without CA roots:
```
❌ c2s-outgoing,tls  (missing tls-ca-roots-*)
```

Multiple TLS providers:
```
❌ tls-ring,tls-aws-lc-rs
```

**5.2 File Structure Map**

```
xmpp-proxy/
├── src/                              # Rust source code
│   ├── main.rs                       # Entry point, config parsing, runtime
│   ├── context.rs                    # Shared configuration and state
│   ├── in_out.rs                     # Core proxy logic and dispatch
│   ├── srv.rs                        # DNS SRV, host-meta, POSH lookups
│   ├── stanzafilter.rs               # Stanza size limiting (no XML parser)
│   ├── verify.rs                     # S2S certificate validation
│   ├── slicesubsequence.rs           # Byte slice utilities
│   ├── outgoing.rs                   # Outgoing connection logic
│   ├── systemd.rs                    # Systemd socket activation
│   ├── tls/                          # STARTTLS/Direct TLS implementation
│   ├── quic/                         # QUIC protocol implementation
│   ├── websocket/                    # WebSocket transport
│   ├── webtransport/                 # WebTransport implementation
│   └── common/                       # Shared types and helpers
│
├── xmpp-proxy-stack/                 # Docker bundled stack
│   ├── Dockerfile                    # Multi-stage distroless build
│   ├── docker-entrypoint.sh          # Container startup script
│   ├── nginx-proxy-ctl               # Dynamic nginx config tool
│   ├── horust-services/              # Process supervisor configs
│   │   ├── xmpp-proxy.toml           # xmpp-proxy service definition
│   │   ├── nginx.toml                # nginx service definition
│   │   ├── fail2ban-rs.toml          # fail2ban service definition
│   │   └── acme-cron.toml            # Certificate renewal cron
│   ├── templates/                    # Configuration templates
│   │   ├── nginx.conf.template       # nginx base config
│   │   ├── xmpp-proxy.toml.template  # xmpp-proxy runtime config
│   │   └── prosody-proxy.cfg.lua     # Prosody PROXY protocol config
│   └── tests/                        # Stack validation tests
│
├── integration/                      # Podman-based integration tests
│   └── test.sh                       # Test suite entry point
│
├── Cargo.toml                        # Rust dependencies and features
├── xmpp-proxy.toml                   # Example runtime configuration
│
├── docker-compose.yaml               # Production stack (pulls image)
├── docker-compose.dev.yaml           # Development stack (builds from source)
├── .env.example                      # Environment variable template
│
├── docs/                             # Documentation
├── contrib/                          # Contributed configs, logos, etc.
├── scripts/                          # Utility scripts
├── .github/                          # GitHub Actions CI/CD
└── .ci/                              # CI configuration
```

**5.3 Environment Variables Reference**

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `XMPP_DOMAIN` | ✅ Yes | - | Your XMPP domain (e.g., chat.example.com) |
| `ACME_EMAIL` | ✅ Yes | - | Email for Let's Encrypt notifications |
| `XMPP_ADMIN` | No | `admin@${XMPP_DOMAIN}` | Admin JID for Prosody |
| `PROSODY_LOGLEVEL` | No | `info` | Prosody log level (debug, info, warn, error) |
| `PROSODY_RETENTION_DAYS` | No | `90` | Message Archive Management retention |
| `FAIL2BAN_MAX_RETRY` | No | `5` | Failed attempts before ban |
| `FAIL2BAN_BAN_TIME` | No | `1h` | How long to ban (e.g., 1h, 30m) |
| `FAIL2BAN_FIND_TIME` | No | `10m` | Time window for counting failures |
| `XMPP_PROXY_VERSION` | No (dev only) | `latest` | Git tag or 'latest' to build |
| `FAIL2BAN_RS_VERSION` | No (dev only) | `latest` | fail2ban-rs version to download |
| `HORUST_VERSION` | No (dev only) | `0.1.13` | horust version to bundle |
| `XMPP_PROXY_STACK_TAG` | No (prod only) | `latest` | ghcr.io image tag to pull |

**5.4 Common Gotchas**

**1. Prosody crash loop: "UID '0' already exists"**

**Symptom:**
```
docker logs prosody
usermod: UID '0' already exists
```

**Cause:** Docker auto-created `/srv/xmpp/prosody` as root (UID 0). Prosody container expects UID 100:102.

**Fix:**
```bash
docker compose down
sudo chown -R 100:102 /srv/xmpp/prosody /srv/xmpp/logs/prosody
docker compose up -d
```

**Prevention:** Create directories with correct ownership before first `docker compose up`.

---

**2. Host networking is required for PROXY protocol**

**Why:** PROXY protocol v1 passes real client IP addresses to Prosody. Bridge networking would show all connections as coming from Docker bridge IP (usually 172.x.x.x), breaking rate limiting and logging.

**Don't do this:**
```yaml
# ❌ DO NOT CHANGE TO BRIDGE NETWORKING
xmpp-proxy-stack:
  network_mode: bridge
```

**Correct:**
```yaml
xmpp-proxy-stack:
  network_mode: host  # ✅ Required for PROXY protocol
```

**Trade-off:** Only one container can use host networking and bind to standard ports. This is why services are bundled into one container.

---

**3. Port conflicts on host**

**Symptom:**
```
Error starting userland proxy: listen tcp4 0.0.0.0:5222: bind: address already in use
```

**Cause:** Another service (ejabberd, another XMPP server, previous xmpp-proxy) already bound to the port.

**Check:**
```bash
ss -tlnp | grep -E ':(5222|5223|5269|80|443|5280)'
```

**Fix:**
- Stop conflicting service
- Or change xmpp-proxy ports in config (non-standard, may break clients)

---

**4. Certificates not renewing / ACME failures**

**Symptom:**
```
docker logs xmpp-proxy-stack | grep -i acme
acme.sh: verification failed
```

**Common causes:**

a) **DNS not pointing to server:**
```bash
dig +short $XMPP_DOMAIN
# Should return your server's public IP
```

b) **Port 80 not accessible externally:**
- Check firewall: `sudo firewall-cmd --list-all | grep 80`
- Check router NAT/port forwarding

c) **nginx not serving ACME challenges:**
```bash
curl http://$XMPP_DOMAIN/.well-known/acme-challenge/test
# Should get 404 from nginx, not connection refused
```

**Debug:**
```bash
docker exec xmpp-proxy-stack /root/.acme.sh/acme.sh --renew -d $XMPP_DOMAIN --force --debug
```

---

**5. Can't execute commands in xmpp-proxy-stack**

**Symptom:**
```
docker exec xmpp-proxy-stack ls
OCI runtime exec failed: exec failed: unable to start container process: exec: "ls": executable file not found
```

**Cause:** Distroless image has no shell, no coreutils.

**Correct approach:**
```bash
docker exec xmpp-proxy-stack /bin/busybox ls
docker exec xmpp-proxy-stack /bin/busybox sh
```

**Available commands:** Only busybox built-ins (sh, cat, ls, grep, ps, etc.)

---

**6. Integration tests fail with "podman: command not found"**

**Cause:** Integration tests require rootless podman, not Docker.

**Fix:**
1. Install podman: `sudo pacman -S podman` (Arch) or equivalent
2. Configure rootless: `podman system migrate`
3. Verify: `podman run hello-world`

**Note:** Docker will not work for integration tests. They specifically use podman features.

---

**7. WebSocket connections fail**

**Symptom:** Client can't connect to `ws://domain:5280/xmpp-websocket`

**Check:**
1. Prosody websocket module loaded:
   ```bash
   docker logs prosody | grep websocket
   ```
2. Port 5280 accessible:
   ```bash
   curl http://localhost:5280/
   ```
3. nginx routing (if proxying WebSocket):
   ```bash
   docker exec xmpp-proxy-stack /bin/busybox cat /etc/nginx/nginx.conf | grep -A5 websocket
   ```

**Common fix:** Ensure Prosody `modules_enabled` includes `websocket`.

---

**8. PROXY protocol shows 127.0.0.1 instead of real IPs**

**Symptom:** Prosody logs show all connections from 127.0.0.1.

**Causes:**

a) **mod_net_proxy not loaded:**
```bash
docker logs prosody | grep net_proxy
# Should see: "mod_net_proxy loaded"
```

b) **PROXY protocol port mapping incorrect:**
Check `proxy_port_mappings` in Prosody config:
```lua
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}
```

c) **xmpp-proxy not sending PROXY header:**
Check xmpp-proxy config (`send_proxy_v1 = true`)

---

**9. Feature flag compilation errors**

**Symptom:**
```
error: Package `xmpp-proxy` does not have feature `webtransport`
```

**Cause:** Typo in feature name, or dependency on another feature.

**Fix:**
- Check `Cargo.toml` `[features]` section for exact names
- Verify feature dependencies (e.g., `webtransport` requires `quic`)
- Use `./check-all-features.sh` to validate all combinations

---

**10. Docker cache issues after Dockerfile changes**

**Symptom:** Changes to scripts/templates not reflected in built image.

**Cause:** Docker layer cache reused old version.

**Fix:**
```bash
docker compose -f docker-compose.dev.yaml build --no-cache xmpp-proxy-stack
```

**Prevention:** Organize Dockerfile so frequently-changed files (scripts, templates) are COPYed late, less-frequent dependencies (Rust build) early.

**5.5 Port Reference**

**Public (exposed to internet):**

| Port | Protocol | Purpose |
|------|----------|---------|
| 5222/tcp | XMPP C2S | Client-to-Server (STARTTLS) |
| 5223/tcp | XMPP C2S | Client-to-Server (Direct TLS) |
| 5269/tcp | XMPP S2S | Server-to-Server |
| 443/udp | XMPP over QUIC | QUIC transport (XEP-0467) |
| 5280/tcp | HTTP/WS | WebSocket, BOSH, HTTP API |
| 80/tcp | HTTP | ACME challenges, redirects |

**Internal (localhost only):**

| Port | Purpose |
|------|---------|
| 15222/tcp | Prosody C2S (receives from xmpp-proxy) |
| 15269/tcp | Prosody S2S (receives from xmpp-proxy) |
| 15280/tcp | Prosody HTTP (internal only) |

**Data flow example (C2S):**
```
Client (203.0.113.45:54321)
  ↓ TLS connection
xmpp-proxy-stack (host network, port 5222)
  ↓ TLS termination
  ↓ PROXY protocol: "PROXY TCP4 203.0.113.45 127.0.0.1 54321 15222\r\n"
  ↓ Plain TCP
prosody (bridge network, 127.0.0.1:15222)
  ↓ mod_net_proxy parses header
  ↓ Logs: "Client 203.0.113.45 connected"
```

## Implementation Notes

**Writing style:**
- Direct and concise (per CLAUDE.md best practices)
- Architecture section more detailed (builds mental model)
- Task sections action-oriented (quick reference)
- Reference section: tables, code blocks, minimal prose

**Tone:**
- Assumes Claude is already familiar with Docker, Rust, XMPP basics
- Focus on project-specific details, not general tutorials
- Point to external docs for standard concepts (e.g., "see Arch Wiki for rootless podman")

**Maintenance:**
- Update when major architectural changes occur
- Keep feature flag reference in sync with Cargo.toml
- Add new gotchas as discovered
- Prune outdated information

## Success Criteria

The CLAUDE.md is successful if:
1. Claude can navigate the codebase confidently (knows which component to modify)
2. Claude understands why design decisions were made (e.g., host networking rationale)
3. Claude can build, test, and debug both Rust and Docker components
4. Claude avoids common pitfalls (documented gotchas)
5. Claude provides contextually accurate suggestions (based on architecture understanding)

## Out of Scope

This design document does NOT cover:
- User-facing deployment documentation (belongs in README)
- Detailed XMPP protocol explanations (reference XEPs)
- Production hardening guides (firewall, SELinux, etc.)
- Performance tuning recommendations
- Monitoring and observability setup
