# xmpp-proxy-stack Docker Cleanup Design

**Date:** 2026-07-30  
**Status:** Approved  
**Author:** Claude Sonnet 4.5

## Overview

Clean up the xmpp-proxy-stack Docker configuration by removing legacy debian-slim artifacts, promoting the distroless build to primary, streamlining the README, and adding nginx port 80/443 handling.

## Motivation

The project has transitioned from debian-slim (supervisord-based) to distroless (Horust-based) deployment. Recent commits show the distroless build is stable and published to ghcr.io. Keeping both builds creates confusion and maintenance overhead. The legacy files serve no purpose beyond emergency rollback, which can be handled via git history.

## Goals

1. Remove all unused debian-slim files
2. Make Dockerfile.distroless the primary Dockerfile
3. Shorten and restructure README.md (~462 lines → ~300 lines)
4. Add prominent nginx-proxy-ctl documentation
5. Configure nginx port 80 to redirect to HTTPS
6. Configure nginx port 443 to show connection success message
7. Test all changes to ensure no regressions

## Non-Goals

- Changing the distroless implementation itself
- Modifying Horust service configurations
- Altering xmpp-proxy or fail2ban-rs behavior

## Design

### 1. File Removal & Reorganization

**Files to delete:**
- `xmpp-proxy-stack/Dockerfile` (legacy debian-slim build)
- `xmpp-proxy-stack/nginx.conf` (replaced by templates/nginx.conf)
- `xmpp-proxy-stack/supervisord.conf` (replaced by Horust)

**Files to rename:**
- `xmpp-proxy-stack/Dockerfile.distroless` → `xmpp-proxy-stack/Dockerfile`

**References to update:**
- `docker-compose.dev.yaml`: Change `dockerfile: Dockerfile.distroless` to `dockerfile: Dockerfile`
- `.github/workflows/*`: Update any workflow files that reference Dockerfile.distroless
- `README.md`: Remove all mentions of Dockerfile.distroless and rollback procedures

### 2. README.md Restructuring

**Current structure issues:**
- 462 lines total, very long
- "Distroless Deployment" is a separate section despite being the recommended approach
- Rollback documentation (lines 440-462) for deprecated build
- nginx-proxy-ctl usage buried in examples
- Repetitive architecture explanations

**New structure:**

```
1. Introduction & Features (existing, keep concise)
2. Installation
   - Binary installation
   - Configuration
   - Prosody integration examples (condensed)
3. Docker Deployment (merge distroless section here)
   - Quick Start (environment setup, directory creation, startup)
   - Architecture (single consolidated explanation)
   - nginx-proxy-ctl Usage (NEW, prominent placement)
   - Customization
4. License & References
```

**Sections to remove:**
- "Distroless Deployment (Recommended)" header (merge into main Docker section)
- Rollback documentation (lines 440-462)
- Redundant architecture explanations

**Sections to add/expand:**
- nginx-proxy-ctl usage with clear examples:
  ```bash
  # Add a reverse proxy
  docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://localhost:8000/
  
  # Add websocket proxy
  docker exec xmpp-proxy-stack nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket
  
  # List configured proxies
  docker exec xmpp-proxy-stack nginx-proxy-ctl list
  
  # Remove a proxy
  docker exec xmpp-proxy-stack nginx-proxy-ctl remove /api/
  ```

**Target length:** ~300 lines (35% reduction)

### 3. Nginx Configuration Changes

**File:** `xmpp-proxy-stack/templates/nginx.conf`

**Port 80 server block changes:**

Current behavior:
```nginx
location / {
    return 404;
}
```

New behavior:
```nginx
location / {
    return 301 https://$host$request_uri;
}
```

**Port 443 server block changes:**

Current state: Commented out (lines 73-83)

New state: Uncommented and enhanced:
```nginx
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate /certs/fullchain.pem;
    ssl_certificate_key /certs/privkey.pem;

    # Connection success message
    location = / {
        return 200 'Connection succeed\n';
        add_header Content-Type text/plain;
    }

    # Include dynamic proxy configurations
    include /etc/nginx/conf.d/*.conf;
}
```

**Certificate management:** acme.sh populates `/certs/` on container startup. No changes needed to certificate paths.

### 4. Testing Strategy

**Build tests:**
1. Verify `xmpp-proxy-stack/Dockerfile` builds successfully
2. Ensure all Horust services start (nginx, xmpp-proxy, fail2ban-rs, acme.sh)
3. Check nginx configuration validity (`nginx -t`)

**Nginx behavior tests:**
1. Port 80 `/` → HTTP 301 redirect to `https://$host$request_uri`
2. Port 80 `/.well-known/acme-challenge/` → serves files (ACME challenge)
3. Port 443 `/` → HTTP 200 with `Connection succeed\n` (text/plain)
4. Port 443 dynamic proxies work via nginx-proxy-ctl

**Integration tests:**
1. Run existing bats test suite: `xmpp-proxy-stack/tests/`
2. Verify `docker-compose.dev.yaml` builds with renamed Dockerfile
3. Test docker-compose startup and service health

**Manual verification:**
1. Start stack: `docker compose -f docker-compose.dev.yaml up -d`
2. Test nginx port 80: `curl -I http://localhost/`
3. Test nginx port 443: `curl -k https://localhost/`
4. Test nginx-proxy-ctl: `docker exec xmpp-proxy-stack nginx-proxy-ctl list`

## Implementation Plan

1. **File operations:**
   - Delete legacy files (Dockerfile, nginx.conf, supervisord.conf)
   - Rename Dockerfile.distroless → Dockerfile
   - Update docker-compose.dev.yaml dockerfile reference
   - Check and update any GitHub workflow files

2. **Nginx configuration:**
   - Update templates/nginx.conf port 80 redirect
   - Uncomment and enhance port 443 server block

3. **README.md rewrite:**
   - Remove distroless section header
   - Remove rollback section
   - Add nginx-proxy-ctl usage section
   - Consolidate architecture explanations
   - Trim to ~300 lines

4. **Testing:**
   - Build and start services
   - Test nginx port 80/443 behavior
   - Run bats integration tests
   - Verify nginx-proxy-ctl functionality

5. **Commit and document:**
   - Commit all changes with clear message
   - Update any related documentation

## Risks & Mitigation

**Risk:** Users with existing docker-compose.override.yaml referencing Dockerfile.distroless  
**Mitigation:** This is in docker-compose.dev.yaml (development), not production docker-compose.yaml. Production uses published images, unaffected.

**Risk:** Breaking existing nginx proxy configurations  
**Mitigation:** The `/etc/nginx/conf.d/*.conf` include remains unchanged. Dynamic proxies continue to work.

**Risk:** SSL certificate errors on port 443  
**Mitigation:** acme.sh manages certificates in /certs/. Template uses existing paths. No change to certificate logic.

## Success Criteria

- [ ] All legacy debian-slim files deleted
- [ ] Dockerfile.distroless renamed to Dockerfile
- [ ] All references updated in docker-compose.dev.yaml and workflows
- [ ] README.md reduced to ~300 lines with clear nginx-proxy-ctl section
- [ ] nginx port 80 redirects to HTTPS
- [ ] nginx port 443 returns "Connection succeed\n" at root
- [ ] All existing bats tests pass
- [ ] docker-compose builds and starts successfully
- [ ] nginx-proxy-ctl functionality verified
