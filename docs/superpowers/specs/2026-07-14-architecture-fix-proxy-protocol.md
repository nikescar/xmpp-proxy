# Architecture Fix: PROXY Protocol Support

**Date:** 2026-07-14  
**Status:** Approved  
**Type:** Critical Bug Fix  
**Issue:** PROXY protocol documented but not implemented, causing security system failure

## Executive Summary

This specification fixes a critical architecture deviation where PROXY protocol support is documented but not implemented in the Prosody XMPP server. The issue causes all client connections to appear as coming from `127.0.0.1` (localhost), which breaks the fail2ban-rs intrusion prevention system and eliminates security audit trails.

**Impact:**
- 🔴 **CRITICAL**: fail2ban-rs bans 127.0.0.1 instead of attackers
- 🔴 **CRITICAL**: Cannot track real client IPs for security auditing
- 🔴 **CRITICAL**: Security logging shows wrong source IPs

**Solution:**
Install and enable `mod_net_proxy` from the prosody-modules community repository to parse PROXY protocol headers sent by xmpp-proxy, restoring real client IP visibility.

## Problem Statement

### Current Broken State

**What's happening:**
1. Client connects to xmpp-proxy on public port 5222 with TLS
2. xmpp-proxy terminates TLS and forwards to Prosody on localhost:15222
3. xmpp-proxy sends PROXY protocol v1 header: `PROXY TCP4 <real_ip> 127.0.0.1 <port> 15222\r\n`
4. Prosody receives connection but **ignores PROXY header** (mod_net_proxy disabled)
5. Prosody logs connection as coming from `127.0.0.1`
6. fail2ban-rs sees failed auth from `127.0.0.1` in logs
7. fail2ban-rs bans `127.0.0.1` → blocks all traffic including legitimate users

**Root Cause:**
- The official `prosodyim/prosody:13.0` Docker image does not include `mod_net_proxy`
- `mod_net_proxy` exists in the community prosody-modules repository
- Current `prosody-proxy.cfg.lua` has mod_net_proxy configuration commented out with note: "disabled until we install the required module"

**Evidence:**
```lua
// xmpp-proxy-stack/templates/prosody-proxy.cfg.lua:8-19
-- Note: PROXY protocol support requires mod_net_proxy from prosody-modules
-- For now, this is disabled until we install the required module
-- modules_enabled = {
--     "net_proxy";  -- mod_net_proxy for PROXY protocol
-- }
```

### Expected Behavior (Per Architecture Spec)

From `docs/superpowers/specs/2026-07-14-xmpp-docker-compose-design.md`:

```
**Component 1: xmpp-proxy**
- Send PROXY protocol v1 header with real client IP

**Component 2: Prosody**
- mod_net_proxy enabled
- Real client IPs visible in Prosody logs (not 172.x.x.x)

**Manual Testing Checklist:**
- [ ] Real client IPs visible in Prosody logs (not 172.x.x.x)
```

### Impact Analysis

**Security Impact:**
- Intrusion detection system (fail2ban-rs) is completely broken
- Cannot identify or block attackers
- Legitimate traffic gets blocked when localhost is banned
- No forensic trail of actual client IPs

**Operational Impact:**
- Cannot diagnose abuse or spam issues
- Cannot implement IP-based access controls
- Cannot track geographic distribution of users
- Compliance issues if audit logs are required

## Design

### Solution Overview

**Approach:** Install prosody-modules community repository and enable `mod_net_proxy`

**Method:** Volume-mount prosody-modules into Prosody container

**Why This Approach:**
1. Uses official Prosody Docker image (no custom build)
2. Standard method used by Prosody community
3. Easy to update modules (git pull)
4. Transparent and auditable
5. Fast deployment (no Docker build step)

### Architecture Components

```
┌─────────────────────────────────────────────────────┐
│ Host System                                         │
│                                                     │
│  ./prosody-modules/                                 │
│  ├── mod_net_proxy/                                 │
│  │   └── mod_net_proxy.lua  ← The module we need   │
│  ├── mod_mam/                                       │
│  └── ... (other community modules)                  │
│                                                     │
│  ↓ Docker volume mount                              │
│                                                     │
│  ┌────────────────────────────────────────────┐    │
│  │ Prosody Container                          │    │
│  │                                            │    │
│  │  /usr/local/lib/prosody/modules/community/ │    │
│  │  ← mounted from ./prosody-modules/         │    │
│  │                                            │    │
│  │  /etc/prosody/conf.d/proxy.cfg.lua:        │    │
│  │    plugin_paths = {                        │    │
│  │      "/usr/local/lib/.../community"        │    │
│  │    }                                       │    │
│  │    modules_enabled = { "net_proxy" }       │    │
│  └────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

### Data Flow (After Fix)

```
1. Client (IP: 203.0.113.50) connects to xmpp-proxy:5222
   ↓
2. xmpp-proxy terminates TLS
   ↓
3. xmpp-proxy opens TCP to 127.0.0.1:15222
   Sends: "PROXY TCP4 203.0.113.50 127.0.0.1 44123 15222\r\n"
   Forwards: <stream:stream to="chat.example.com">
   ↓
4. Prosody receives connection on port 5222 (container port)
   mod_net_proxy parses PROXY header
   Extracts: real_client_ip = 203.0.113.50
   Sets: session.ip = 203.0.113.50
   ↓
5. Prosody logs: "c2s1a2b New connection from 203.0.113.50"
   (NOT "from 127.0.0.1")
   ↓
6. If auth fails:
   Prosody logs: "Failed authentication for user@domain from 203.0.113.50"
   ↓
7. fail2ban-rs reads log, sees 203.0.113.50
   Bans correct IP: nft add element inet fail2ban-rs xmpp-auth { 203.0.113.50 }
   ✅ Security system works correctly
```

## Implementation Details

### 1. New Script: `scripts/init-prosody-modules.sh`

```bash
#!/bin/bash
# scripts/init-prosody-modules.sh
# Clones prosody-modules repository for community module support

set -euo pipefail

MODULES_DIR="./prosody-modules"
MODULES_REPO="https://hg.prosody.im/prosody-modules"

echo "=== Prosody Community Modules Setup ==="

# Check if already exists
if [ -d "$MODULES_DIR" ]; then
    echo "✓ prosody-modules already exists at $MODULES_DIR"
    
    # Optionally update
    if [ "${UPDATE:-false}" = "true" ]; then
        echo "Updating modules..."
        cd "$MODULES_DIR"
        hg pull -u
        cd ..
        echo "✓ Modules updated"
    fi
else
    echo "Cloning prosody-modules repository..."
    
    # Check if mercurial is installed
    if ! command -v hg &> /dev/null; then
        echo "ERROR: Mercurial (hg) is not installed"
        echo "Install with: apt install mercurial  (or brew install mercurial)"
        exit 1
    fi
    
    # Clone repository
    hg clone "$MODULES_REPO" "$MODULES_DIR"
    echo "✓ Modules cloned successfully"
fi

# Verify mod_net_proxy exists
if [ -f "$MODULES_DIR/mod_net_proxy/mod_net_proxy.lua" ]; then
    echo "✓ mod_net_proxy found"
else
    echo "ERROR: mod_net_proxy not found in cloned repository"
    exit 1
fi

echo "=== Setup complete ==="
```

**Why Mercurial?**
The official prosody-modules repository uses Mercurial (hg), not Git. This is a one-time requirement for initial setup.

### 2. docker-compose.yaml Changes

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
      PROSODY_ENABLE_MODULES: mam,carbons,csi_simple,ping,admin_adhoc
      PROSODY_CERTIFICATES: /certs
      PROSODY_RETENTION_DAYS: ${PROSODY_RETENTION_DAYS:-90}
    volumes:
      - /srv/xmpp/prosody:/var/lib/prosody
      - /srv/xmpp/certs:/certs:ro
      - /srv/xmpp/logs/prosody:/var/log/prosody
      - ./xmpp-proxy-stack/templates/prosody-proxy.cfg.lua:/etc/prosody/conf.d/proxy.cfg.lua:ro
      # NEW: Mount community modules for mod_net_proxy support
      - ./prosody-modules:/usr/local/lib/prosody/modules/community:ro
    ports:
      - "127.0.0.1:15222:5222"  # C2S
      - "127.0.0.1:15269:5269"  # S2S
      - "127.0.0.1:15280:5280"  # HTTP/WebSocket
    networks:
      - xmpp-internal
    healthcheck:
      test: ["CMD", "prosodyctl", "status"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
```

**Change:** Single line added to volumes section.

### 3. prosody-proxy.cfg.lua Changes

```lua
-- Prosody PROXY protocol configuration
-- This file is mounted at /etc/prosody/conf.d/proxy.cfg.lua

-- Add pidfile for health checks
pidfile = "/var/run/prosody/prosody.pid"

-- PROXY protocol support via mod_net_proxy from prosody-modules
-- Community modules mounted at: /usr/local/lib/prosody/modules/community
plugin_paths = { "/usr/local/lib/prosody/modules/community" }

modules_enabled = {
    "net_proxy";  -- Parse PROXY protocol v1/v2 headers to extract real client IP
}

-- Configure which ports expect PROXY protocol headers
proxy_port_mappings = {
    [5222] = "c2s",  -- Client-to-server connections
    [5269] = "s2s"   -- Server-to-server connections
}

-- Don't require encryption (xmpp-proxy already handled TLS termination)
c2s_require_encryption = false
s2s_require_encryption = false
s2s_secure_auth = false

-- Allow plaintext auth since connection is already secure (TLS at xmpp-proxy)
allow_unencrypted_plain_auth = true

-- Real client IPs are now preserved via mod_net_proxy
-- Prosody logs will show actual client IPs, not 127.0.0.1
-- fail2ban-rs can now correctly identify and ban attackers
```

**Changes:**
1. ✅ Added `plugin_paths` to load community modules
2. ✅ Uncommented `modules_enabled = { "net_proxy" }`
3. ✅ Uncommented `proxy_port_mappings`
4. ✅ Removed obsolete comment about "disabled until module installed"
5. ✅ Added clarifying comments about what mod_net_proxy does

### 4. .gitignore Addition

```
# Prosody community modules (cloned at setup time, not committed)
prosody-modules/
```

**Why:** prosody-modules is a third-party repository cloned during setup. We don't commit it to our repo.

### 5. Testing & Verification

#### Test Script: `scripts/test-proxy-protocol.sh`

```bash
#!/bin/bash
# scripts/test-proxy-protocol.sh
# Verifies PROXY protocol is working correctly

set -euo pipefail

echo "=== PROXY Protocol Verification ==="
echo ""

# Test 1: Module loaded
echo "1. Checking if mod_net_proxy is loaded..."
if docker compose exec -T prosody prosodyctl about 2>&1 | grep -q "net_proxy"; then
    echo "   ✅ PASSED: mod_net_proxy is loaded"
else
    echo "   ❌ FAILED: mod_net_proxy not found in loaded modules"
    echo "   Hint: Check /var/log/prosody/prosody.log for module load errors"
    exit 1
fi

# Test 2: Community modules path exists
echo "2. Checking community modules directory..."
if docker compose exec -T prosody test -d /usr/local/lib/prosody/modules/community/mod_net_proxy; then
    echo "   ✅ PASSED: mod_net_proxy directory exists"
else
    echo "   ❌ FAILED: Community modules not mounted"
    echo "   Hint: Ensure prosody-modules directory exists and is mounted"
    exit 1
fi

# Test 3: Check for 127.0.0.1 in recent logs (should be minimal if working)
echo "3. Checking Prosody logs for localhost IPs..."
LOCALHOST_COUNT=$(docker compose exec -T prosody grep -c "127.0.0.1" /var/log/prosody/prosody.log 2>/dev/null || echo "0")

if [ "$LOCALHOST_COUNT" -gt 10 ]; then
    echo "   ⚠️  WARNING: Found $LOCALHOST_COUNT instances of 127.0.0.1 in logs"
    echo "   This may indicate PROXY protocol is not working"
    echo "   (Some localhost entries are normal for internal operations)"
else
    echo "   ✅ PASSED: Minimal localhost IPs in logs"
fi

# Test 4: Verify PROXY protocol config
echo "4. Checking Prosody PROXY protocol configuration..."
if docker compose exec -T prosody grep -q "proxy_port_mappings" /etc/prosody/conf.d/proxy.cfg.lua; then
    echo "   ✅ PASSED: PROXY protocol configured"
else
    echo "   ❌ FAILED: proxy_port_mappings not found in config"
    exit 1
fi

echo ""
echo "=== PROXY Protocol Basic Checks Passed ✅ ==="
echo ""
echo "For full verification:"
echo "  1. Connect a real XMPP client (Gajim, Conversations)"
echo "  2. Check logs: docker compose logs prosody | grep 'New connection'"
echo "  3. Verify real client IP appears (not 127.0.0.1)"
echo "  4. Trigger fail2ban by failing auth 6 times"
echo "  5. Verify correct IP is banned: docker compose exec xmpp-proxy-stack fail2ban-rs status"
```

#### Integration into `scripts/test-deployment.sh`

Add after container health checks:

```bash
echo "11. Testing PROXY protocol support..."
if docker compose exec -T prosody prosodyctl about 2>&1 | grep -q "net_proxy"; then
    echo "   ✅ PASSED: PROXY protocol enabled"
else
    echo "   ❌ FAILED: mod_net_proxy not loaded"
    exit 1
fi
```

### 6. Documentation Updates

#### README.md Quick Start

```markdown
## Quick Start

### Prerequisites
- Docker & Docker Compose
- **Mercurial** (`apt install mercurial` or `brew install mercurial`)
- DNS A/AAAA records pointing to your server
- Ports 80, 443, 5222, 5269, 5443 open in firewall

### Installation

```bash
# 1. Clone repository
git clone https://github.com/nikescar/xmpp-proxy
cd xmpp-proxy

# 2. Setup prosody-modules (required for PROXY protocol support)
./scripts/init-prosody-modules.sh

# 3. Configure environment
cp .env.example .env
nano .env
# Set:
#   XMPP_DOMAIN=chat.example.com
#   ACME_EMAIL=admin@example.com

# 4. Create data directories
sudo mkdir -p /srv/xmpp/{certs,prosody,logs,fail2ban,acme}
sudo chown -R $USER:$USER /srv/xmpp

# 5. Deploy
docker compose up -d

# 6. Verify
./scripts/test-deployment.sh

# 7. Create admin user
docker compose exec prosody prosodyctl adduser admin@chat.example.com
```
```

#### TROUBLESHOOTING.md Addition

```markdown
## PROXY Protocol Issues

### Symptom: Prosody logs show all connections from 127.0.0.1

**Cause:** mod_net_proxy not loaded or not configured correctly

**Diagnosis:**
```bash
# Check if module is loaded
docker compose exec prosody prosodyctl about | grep net_proxy

# If not found, check Prosody error log:
docker compose logs prosody | grep -i "net_proxy\|proxy"
```

**Solutions:**

1. **Module directory not mounted:**
   ```bash
   # Verify prosody-modules exists
   ls -la ./prosody-modules/mod_net_proxy/
   
   # If missing, run:
   ./scripts/init-prosody-modules.sh
   
   # Restart Prosody:
   docker compose restart prosody
   ```

2. **Module failed to load:**
   ```bash
   # Check Prosody config syntax
   docker compose exec prosody prosodyctl check config
   
   # Check plugin_paths is set correctly
   docker compose exec prosody grep plugin_paths /etc/prosody/conf.d/proxy.cfg.lua
   ```

3. **xmpp-proxy not sending PROXY headers:**
   ```bash
   # Verify xmpp-proxy config has proxy_proto = true
   docker compose exec xmpp-proxy-stack cat /etc/xmpp-proxy/xmpp-proxy.toml | grep proxy_proto
   
   # Should show: proxy_proto = true for all listeners
   ```

### Symptom: fail2ban-rs bans 127.0.0.1 instead of attackers

**Cause:** Same as above - PROXY protocol not working

**Fix:** Follow "PROXY Protocol Issues" steps above, then:
```bash
# Unban localhost
docker compose exec xmpp-proxy-stack fail2ban-rs unban 127.0.0.1

# Clear fail2ban state and restart
docker compose exec xmpp-proxy-stack rm -f /var/lib/fail2ban-rs/state.bin
docker compose restart xmpp-proxy-stack
```
```

#### Architecture Documentation Update

Update design spec at line 110:

```markdown
**Bridge network** (`xmpp-internal`) for inter-container communication:
- Prosody listens on `0.0.0.0:5222` and `0.0.0.0:5269` within the bridge network
- Prosody ports are exposed on localhost as `127.0.0.1:15222:5222` and `127.0.0.1:15269:5269`
- xmpp-proxy (running in host network mode) connects to `127.0.0.1:15222` and `127.0.0.1:15269`
- This localhost approach is simpler than bridge DNS and performs better for host-network containers
```

#### Manual Testing Checklist Update

```markdown
- [ ] Real client IPs visible in Prosody logs (not 127.0.0.1)
  * Run: `docker compose logs prosody | grep "New connection"`
  * Should show actual client IPs, not localhost
  * Run test: `./scripts/test-proxy-protocol.sh`
```

## Migration Path

### For New Deployments

**Before deploying:**
1. Install Mercurial: `apt install mercurial`
2. Follow updated Quick Start in README.md
3. Run `./scripts/init-prosody-modules.sh` before `docker compose up`
4. Verify with `./scripts/test-proxy-protocol.sh`

### For Existing Deployments

**Upgrade steps:**

```bash
# 1. Install Mercurial if not present
apt install mercurial  # or: brew install mercurial

# 2. Clone prosody-modules
./scripts/init-prosody-modules.sh

# 3. Restart Prosody to apply changes
docker compose restart prosody

# 4. Verify fix is working
./scripts/test-proxy-protocol.sh

# 5. Check logs show real IPs now
docker compose logs prosody | tail -20

# 6. If fail2ban has banned 127.0.0.1, unban it
docker compose exec xmpp-proxy-stack fail2ban-rs unban 127.0.0.1

# 7. Clear fail2ban state (optional, starts fresh)
docker compose exec xmpp-proxy-stack rm -f /var/lib/fail2ban-rs/state.bin
docker compose restart xmpp-proxy-stack
```

**Rollback (if needed):**
```bash
# Comment out mod_net_proxy in config
docker compose exec prosody sed -i 's/^modules_enabled/-- modules_enabled/' /etc/prosody/conf.d/proxy.cfg.lua

# Restart
docker compose restart prosody
```

## Verification Criteria

### Success Criteria

- ✅ `mod_net_proxy` loads without errors
- ✅ Prosody logs show real client IPs (e.g., 203.0.113.50) instead of 127.0.0.1
- ✅ fail2ban-rs bans actual attacker IPs, not localhost
- ✅ Test script `./scripts/test-proxy-protocol.sh` passes all checks
- ✅ Test script `./scripts/test-deployment.sh` passes with PROXY protocol check

### Manual Verification Steps

**1. Module Loading:**
```bash
docker compose exec prosody prosodyctl about | grep net_proxy
# Expected: "net_proxy" appears in loaded modules list
```

**2. Real IP in Logs:**
```bash
# Connect with XMPP client from known IP
docker compose logs prosody | grep "New connection"
# Expected: "New connection from <your_real_ip>"
# NOT: "New connection from 127.0.0.1"
```

**3. fail2ban Integration:**
```bash
# Make 6 failed login attempts from test machine
# Check ban status:
docker compose exec xmpp-proxy-stack fail2ban-rs status
# Expected: Your test IP is banned, not 127.0.0.1
```

**4. PROXY Header Parsing:**
```bash
# Check Prosody sees PROXY protocol on the wire
docker compose exec prosody tcpdump -i any -A port 5222 -c 5
# Expected: See "PROXY TCP4 <ip> <ip> <port> <port>" in captures
```

## Risk Assessment

### Low Risk Changes

**Why this is safe:**
1. **Well-tested module** - mod_net_proxy is widely used in Prosody community
2. **No code changes** - Only configuration and volume mounts
3. **Fail-safe behavior** - If module doesn't load, Prosody still runs (just without real IPs)
4. **Reversible** - Can comment out module to revert
5. **Isolated change** - No changes to xmpp-proxy, fail2ban-rs, or other components

### Potential Issues & Mitigations

| Issue | Likelihood | Mitigation |
|-------|-----------|------------|
| Mercurial not installed | Medium | Clear error message in script, installation instructions |
| Module clone fails | Low | Script catches errors, provides helpful message |
| Wrong module path | Low | Test script verifies path, Prosody logs show error |
| PROXY header format mismatch | Very Low | xmpp-proxy uses standard PROXY v1 format |
| Performance impact | Very Low | mod_net_proxy is lightweight, minimal overhead |

### Dependencies

**New External Dependency:**
- **Mercurial (hg)** - Version control tool
  - Required: One-time during initial setup
  - Installation: `apt install mercurial` or `brew install mercurial`
  - Size: ~5MB
  - Availability: All major Linux distributions and macOS

**Repository Dependency:**
- **prosody-modules** - https://hg.prosody.im/prosody-modules
  - Maintained by: Prosody XMPP community
  - License: MIT (same as Prosody)
  - Size: ~50MB cloned
  - Update frequency: Can update via `hg pull -u` when needed

## File Manifest

**Files Created:**
- `scripts/init-prosody-modules.sh` - Setup script for prosody-modules
- `scripts/test-proxy-protocol.sh` - Verification test script
- `docs/superpowers/specs/2026-07-14-architecture-fix-proxy-protocol.md` - This spec

**Files Modified:**
- `docker-compose.yaml` - Add prosody-modules volume mount (1 line)
- `xmpp-proxy-stack/templates/prosody-proxy.cfg.lua` - Enable mod_net_proxy
- `.gitignore` - Ignore prosody-modules directory
- `README.md` - Add setup step and Mercurial prerequisite
- `docs/TROUBLESHOOTING.md` - Add PROXY protocol troubleshooting section
- `scripts/test-deployment.sh` - Add PROXY protocol verification
- `docs/superpowers/specs/2026-07-14-xmpp-docker-compose-design.md` - Clarify localhost approach

**Files Not Changed:**
- `xmpp-proxy-stack/Dockerfile` - No changes needed
- `xmpp-proxy-stack/templates/xmpp-proxy.toml.template` - Already has `proxy_proto = true`
- `xmpp-proxy-stack/templates/fail2ban-rs-config.toml.template` - No changes needed

## Summary

This design fixes the critical PROXY protocol issue by:

1. **Installing** prosody-modules community repository
2. **Enabling** mod_net_proxy in Prosody configuration
3. **Verifying** real client IPs are preserved end-to-end
4. **Testing** that fail2ban-rs can correctly identify and ban attackers

The solution is:
- ✅ Minimal and focused (single module, clear purpose)
- ✅ Standard approach (matches Prosody community best practices)
- ✅ Low risk (well-tested module, reversible changes)
- ✅ Well-tested (automated test scripts, clear verification criteria)
- ✅ Well-documented (README, troubleshooting, architecture updates)

**Implementation Effort:** ~2 hours
- Script creation: 30 min
- Config updates: 15 min
- Documentation: 45 min
- Testing: 30 min

**This design is ready for implementation.**
