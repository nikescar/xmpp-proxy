# xmpp-proxy-stack Docker Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean up xmpp-proxy-stack by removing legacy debian-slim files, promoting distroless to primary, shortening README, and configuring nginx ports 80/443.

**Architecture:** Remove legacy Dockerfile/nginx.conf/supervisord.conf, rename Dockerfile.distroless to Dockerfile, update all references, rewrite README to ~300 lines with nginx-proxy-ctl docs, configure nginx for HTTPS redirect and success message.

**Tech Stack:** Docker, nginx, Markdown

## Global Constraints

- Maintain compatibility with existing Horust service configurations
- Preserve all nginx dynamic proxy functionality via /etc/nginx/conf.d/*.conf
- Keep certificate paths at /certs/fullchain.pem and /certs/privkey.pem (managed by acme.sh)
- Target README length: ~300 lines (35% reduction from 462 lines)

---

### Task 1: Remove Legacy Files and Rename Dockerfile

**Files:**
- Delete: `xmpp-proxy-stack/Dockerfile`
- Delete: `xmpp-proxy-stack/nginx.conf`
- Delete: `xmpp-proxy-stack/supervisord.conf`
- Rename: `xmpp-proxy-stack/Dockerfile.distroless` → `xmpp-proxy-stack/Dockerfile`

**Interfaces:**
- Consumes: Current file structure
- Produces: Clean file structure with Dockerfile as primary build file

- [ ] **Step 1: Verify current file structure**

Run: `ls -la xmpp-proxy-stack/`

Expected: Should see Dockerfile, Dockerfile.distroless, nginx.conf, supervisord.conf

- [ ] **Step 2: Delete legacy debian-slim files**

```bash
cd /srv/xmpp-proxy
rm xmpp-proxy-stack/Dockerfile
rm xmpp-proxy-stack/nginx.conf
rm xmpp-proxy-stack/supervisord.conf
```

- [ ] **Step 3: Rename Dockerfile.distroless to Dockerfile**

```bash
mv xmpp-proxy-stack/Dockerfile.distroless xmpp-proxy-stack/Dockerfile
```

- [ ] **Step 4: Verify file structure**

Run: `ls -la xmpp-proxy-stack/`

Expected: Dockerfile exists, Dockerfile.distroless gone, nginx.conf/supervisord.conf gone

- [ ] **Step 5: Commit changes**

```bash
git add xmpp-proxy-stack/
git commit -m "$(cat <<'EOF'
refactor: remove legacy debian-slim files, promote distroless to primary

- Delete legacy Dockerfile (debian-slim build)
- Delete nginx.conf and supervisord.conf (replaced by templates/ and Horust)
- Rename Dockerfile.distroless to Dockerfile

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Update docker-compose.dev.yaml References

**Files:**
- Modify: `docker-compose.dev.yaml:52`

**Interfaces:**
- Consumes: Dockerfile at xmpp-proxy-stack/Dockerfile
- Produces: docker-compose.dev.yaml referencing correct Dockerfile

- [ ] **Step 1: Update dockerfile reference in docker-compose.dev.yaml**

Change line 52 from:
```yaml
      dockerfile: Dockerfile.distroless
```

To:
```yaml
      dockerfile: Dockerfile
```

- [ ] **Step 2: Update comment at top of file**

Change line 2 from:
```yaml
# Builds xmpp-proxy-stack from source (xmpp-proxy-stack/Dockerfile.distroless)
```

To:
```yaml
# Builds xmpp-proxy-stack from source (xmpp-proxy-stack/Dockerfile)
```

- [ ] **Step 3: Verify docker-compose.dev.yaml syntax**

Run: `docker compose -f docker-compose.dev.yaml config > /dev/null`

Expected: No errors

- [ ] **Step 4: Commit changes**

```bash
git add docker-compose.dev.yaml
git commit -m "$(cat <<'EOF'
fix: update docker-compose.dev.yaml to reference renamed Dockerfile

Update dockerfile path from Dockerfile.distroless to Dockerfile after
rename in previous commit.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Update GitHub Workflow References

**Files:**
- Modify: `.github/workflows/docker-publish.yml:76-77`

**Interfaces:**
- Consumes: Dockerfile at xmpp-proxy-stack/Dockerfile
- Produces: GitHub workflow referencing correct Dockerfile

- [ ] **Step 1: Update file reference in docker-publish.yml**

Change line 76 from:
```yaml
          file: xmpp-proxy-stack/Dockerfile.distroless
```

To:
```yaml
          file: xmpp-proxy-stack/Dockerfile
```

- [ ] **Step 2: Update comment on line 77**

Change line 77 from:
```yaml
          # Dockerfile.distroless hardcodes x86_64-linux-gnu lib paths (see
```

To:
```yaml
          # Dockerfile hardcodes x86_64-linux-gnu lib paths (see
```

- [ ] **Step 3: Verify workflow syntax**

Run: `yamllint .github/workflows/docker-publish.yml 2>/dev/null || echo "yamllint not installed, skipping"`

Expected: No errors (or yamllint not installed message)

- [ ] **Step 4: Commit changes**

```bash
git add .github/workflows/docker-publish.yml
git commit -m "$(cat <<'EOF'
fix: update docker-publish workflow to reference renamed Dockerfile

Update file path from Dockerfile.distroless to Dockerfile in GitHub
Actions workflow.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Update Nginx Configuration for Port 80/443

**Files:**
- Modify: `xmpp-proxy-stack/templates/nginx.conf:56-83`

**Interfaces:**
- Consumes: None
- Produces: nginx configuration with port 80 HTTPS redirect and port 443 success message

- [ ] **Step 1: Update port 80 location / to redirect to HTTPS**

Change lines 57-59 from:
```nginx
        # Return 404 for other requests (proxies will be in conf.d/)
        location / {
            return 404;
        }
```

To:
```nginx
        # Redirect to HTTPS
        location / {
            return 301 https://$host$request_uri;
        }
```

- [ ] **Step 2: Uncomment and enhance port 443 server block**

Change lines 69-83 from:
```nginx
    ##
    # HTTPS Server (optional - add later)
    ##
    # Uncomment when SSL certificates are available
    # server {
    #     listen 443 ssl http2 default_server;
    #     listen [::]:443 ssl http2 default_server;
    #     server_name _;
    #
    #     ssl_certificate /certs/fullchain.pem;
    #     ssl_certificate_key /certs/privkey.pem;
    #
    #     # Include dynamic proxy configurations
    #     include /etc/nginx/conf.d/*.conf;
    # }
```

To:
```nginx
    ##
    # HTTPS Server
    ##
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

- [ ] **Step 3: Verify nginx configuration syntax is valid (static check)**

Run: `grep -A 5 'listen 443' xmpp-proxy-stack/templates/nginx.conf`

Expected: Should show the uncommented server block with location = / for success message

- [ ] **Step 4: Commit changes**

```bash
git add xmpp-proxy-stack/templates/nginx.conf
git commit -m "$(cat <<'EOF'
feat: add nginx port 80 HTTPS redirect and port 443 success message

- Port 80 / now redirects to https://$host$request_uri (301)
- Port 443 / returns "Connection succeed\n" as plain text (200)
- Uncomment HTTPS server block (certificates managed by acme.sh)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Rewrite README.md - Part 1 (Structure and Cleanup)

**Files:**
- Modify: `README.md` (full rewrite)

**Interfaces:**
- Consumes: Current README.md (462 lines)
- Produces: Restructured README.md with distroless merged into Docker section, rollback section removed

- [ ] **Step 1: Read current README to understand full structure**

Run: `wc -l README.md && head -100 README.md`

Expected: 462 lines total, understand introduction and feature sections

- [ ] **Step 2: Create backup of current README**

```bash
cp README.md README.md.backup
```

- [ ] **Step 3: Rewrite README - Introduction and Installation sections**

Keep lines 1-49 (Introduction, features, binary installation) mostly unchanged, but ensure concise.

Update the Prosody integration examples (lines 50-180) to be more concise - remove redundant explanations.

- [ ] **Step 4: Verify backup exists**

Run: `ls -la README.md*`

Expected: Both README.md.backup and README.md exist

Note: Full README rewrite will continue in next steps. This step establishes the backup and begins the restructure.

---

### Task 6: Rewrite README.md - Part 2 (Docker Section with nginx-proxy-ctl)

**Files:**
- Modify: `README.md` (continue rewrite)

**Interfaces:**
- Consumes: Backup README.md.backup, current Docker deployment content
- Produces: Consolidated Docker deployment section with nginx-proxy-ctl usage

- [ ] **Step 1: Write new Docker Deployment section**

Create consolidated Docker section starting around line 180 with this structure:

```markdown
#### Docker Deployment

The recommended deployment uses Docker Compose with two containers:
  * **prosody** - Prosody XMPP server listening on localhost with PROXY protocol support
  * **xmpp-proxy-stack** - Bundles xmpp-proxy, nginx, fail2ban-rs, and acme.sh in a distroless image, supervised by Horust

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

###### Architecture

Prosody listens on localhost:15222 (C2S) and localhost:15269 (S2S). xmpp-proxy terminates TLS on public ports, sends PROXY protocol headers, and forwards to Prosody. This preserves real client IPs for logging and rate limiting. nginx handles ACME challenges and reverse proxy configurations.

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

###### Customization

Put local overrides in `docker-compose.override.yaml`. Common customizations:
  * Change Prosody modules: set `PROSODY_ENABLE_MODULES` in `.env`
  * Adjust log levels: `PROSODY_LOGLEVEL`, `XMPP_PROXY_LOG_LEVEL`
  * Change data paths: modify volume mounts in override file

###### Development Build

To build from source instead of using the published image:
```bash
docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack
docker compose -f docker-compose.dev.yaml up -d
```
```

- [ ] **Step 2: Remove old "Distroless Deployment" section**

Delete lines 260-439 (entire "Distroless Deployment (Recommended)" section - now merged above)

- [ ] **Step 3: Remove rollback section**

Delete lines 440-462 (rollback documentation for deprecated build)

- [ ] **Step 4: Verify README structure**

Run: `wc -l README.md`

Expected: Approximately 280-320 lines (target ~300 lines)

---

### Task 7: Rewrite README.md - Part 3 (Final Cleanup and Polish)

**Files:**
- Modify: `README.md` (finalize)

**Interfaces:**
- Consumes: Partially rewritten README.md
- Produces: Final README.md at ~300 lines with all content consolidated

- [ ] **Step 1: Review and consolidate any remaining redundant sections**

Check for:
- Duplicate architecture explanations
- Redundant configuration examples
- Excessive detail in Prosody config

- [ ] **Step 2: Ensure License and References section is preserved**

Keep the final section (was lines 238-259) with:
```markdown
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
... (all reference links)
```

- [ ] **Step 3: Final line count check**

Run: `wc -l README.md`

Expected: ~300 lines (280-320 acceptable range)

- [ ] **Step 4: Verify all references to Dockerfile.distroless are removed**

Run: `grep -n "Dockerfile.distroless\|distroless\|rollback" README.md`

Expected: No matches (or only "distroless" in architecture explanation context)

- [ ] **Step 5: Remove backup file**

```bash
rm README.md.backup
```

- [ ] **Step 6: Commit README changes**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: restructure README - merge distroless, add nginx-proxy-ctl docs

- Merge "Distroless Deployment" section into main Docker section
- Remove rollback documentation for deprecated debian-slim build
- Add prominent nginx-proxy-ctl usage examples
- Consolidate redundant architecture explanations
- Reduce from 462 to ~300 lines (35% reduction)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Build and Test Docker Stack

**Files:**
- Test: `xmpp-proxy-stack/Dockerfile` builds successfully
- Test: Services start under docker-compose

**Interfaces:**
- Consumes: All previous changes (renamed Dockerfile, updated nginx config, updated docker-compose)
- Produces: Running docker-compose stack for verification

- [ ] **Step 1: Build xmpp-proxy-stack image**

```bash
cd /srv/xmpp-proxy
docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack
```

Expected: Build succeeds with no errors

- [ ] **Step 2: Check if services are already running**

Run: `docker compose -f docker-compose.dev.yaml ps`

Expected: May show running containers or no containers

- [ ] **Step 3: Stop existing services if running**

```bash
docker compose -f docker-compose.dev.yaml down
```

- [ ] **Step 4: Start services**

```bash
docker compose -f docker-compose.dev.yaml up -d
```

Expected: Both prosody and xmpp-proxy-stack start successfully

- [ ] **Step 5: Verify container status**

Run: `docker compose -f docker-compose.dev.yaml ps`

Expected: Both containers running (Up status)

- [ ] **Step 6: Check xmpp-proxy-stack logs for errors**

Run: `docker compose -f docker-compose.dev.yaml logs xmpp-proxy-stack | tail -30`

Expected: Services started successfully, no fatal errors

---

### Task 9: Test Nginx Port 80/443 Behavior

**Files:**
- Test: nginx port 80 redirects to HTTPS
- Test: nginx port 443 shows success message

**Interfaces:**
- Consumes: Running xmpp-proxy-stack container
- Produces: Verification that nginx ports 80/443 work as designed

- [ ] **Step 1: Verify nginx is running in container**

Run: `docker exec xmpp-proxy-stack ps aux | grep nginx`

Expected: nginx processes running

- [ ] **Step 2: Test port 80 redirect to HTTPS**

```bash
curl -I http://localhost/ 2>&1 | head -10
```

Expected: HTTP 301 response with Location: https://localhost/

- [ ] **Step 3: Test port 80 ACME challenge path still works**

```bash
mkdir -p /srv/xmpp/acme/.well-known/acme-challenge/
echo "test" > /srv/xmpp/acme/.well-known/acme-challenge/test-file
curl http://localhost/.well-known/acme-challenge/test-file
```

Expected: Returns "test"

- [ ] **Step 4: Clean up ACME test file**

```bash
rm /srv/xmpp/acme/.well-known/acme-challenge/test-file
```

- [ ] **Step 5: Test port 443 success message**

```bash
curl -k https://localhost/ 2>&1
```

Expected: Returns "Connection succeed\n" as plain text

Note: `-k` flag ignores SSL certificate validation (certificates may not be set up yet in test environment)

- [ ] **Step 6: Verify nginx configuration inside container**

```bash
docker exec xmpp-proxy-stack nginx -t
```

Expected: "nginx: configuration file /etc/nginx/nginx.conf test is successful"

---

### Task 10: Test nginx-proxy-ctl Functionality

**Files:**
- Test: nginx-proxy-ctl add/list/remove commands work

**Interfaces:**
- Consumes: Running xmpp-proxy-stack container with nginx
- Produces: Verification that dynamic proxy management works

- [ ] **Step 1: List current proxies (should be empty initially)**

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl list
```

Expected: "No proxies configured" or empty list

- [ ] **Step 2: Add a test proxy**

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl add /test/ http://localhost:8000/
```

Expected: "Proxy added: /test/ -> http://localhost:8000/"

- [ ] **Step 3: Verify proxy was added**

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl list
```

Expected: Shows "/test/ -> http://localhost:8000/"

- [ ] **Step 4: Verify proxy config file was created**

```bash
docker exec xmpp-proxy-stack ls -la /etc/nginx/conf.d/
```

Expected: Should see proxy-*.conf file

- [ ] **Step 5: Remove the test proxy**

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /test/
```

Expected: "Proxy removed: /test/"

- [ ] **Step 6: Verify proxy was removed**

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl list
```

Expected: "No proxies configured"

---

### Task 11: Run Integration Tests

**Files:**
- Test: Run existing bats test suite

**Interfaces:**
- Consumes: All changes from previous tasks
- Produces: Verification that existing tests still pass

- [ ] **Step 1: Check if bats tests exist**

Run: `ls -la xmpp-proxy-stack/tests/`

Expected: Should see test files

- [ ] **Step 2: Check if bats is installed**

Run: `which bats || echo "bats not installed"`

Expected: Path to bats binary or "bats not installed"

- [ ] **Step 3: Run bats tests if available**

```bash
if command -v bats >/dev/null 2>&1; then
  cd xmpp-proxy-stack/tests
  bats .
else
  echo "SKIP: bats not installed, cannot run integration tests"
fi
```

Expected: All tests pass (or skip message if bats not installed)

- [ ] **Step 4: Check docker-compose.test.yml if it exists**

Run: `cat xmpp-proxy-stack/tests/docker-compose.test.yml 2>/dev/null | head -20`

Expected: Shows test compose configuration or "No such file"

- [ ] **Step 5: Verify no test failures**

If tests ran, review output for any failures

Expected: All tests passed

---

### Task 12: Final Verification and Cleanup

**Files:**
- Verify: All success criteria met
- Clean: Stop test containers

**Interfaces:**
- Consumes: All completed tasks
- Produces: Verified working implementation

- [ ] **Step 1: Verify all legacy files are deleted**

Run: `ls xmpp-proxy-stack/Dockerfile.distroless xmpp-proxy-stack/nginx.conf xmpp-proxy-stack/supervisord.conf 2>&1`

Expected: "No such file or directory" for all three

- [ ] **Step 2: Verify Dockerfile exists at correct location**

Run: `ls -la xmpp-proxy-stack/Dockerfile`

Expected: File exists

- [ ] **Step 3: Verify docker-compose references updated**

```bash
grep "dockerfile:" docker-compose.dev.yaml
grep "Dockerfile.distroless" docker-compose.dev.yaml
```

Expected: First command shows "dockerfile: Dockerfile", second shows no matches

- [ ] **Step 4: Verify GitHub workflow references updated**

```bash
grep "Dockerfile" .github/workflows/docker-publish.yml
```

Expected: Shows "xmpp-proxy-stack/Dockerfile", no "Dockerfile.distroless"

- [ ] **Step 5: Verify README line count**

Run: `wc -l README.md`

Expected: ~300 lines (280-320 range acceptable)

- [ ] **Step 6: Verify no Dockerfile.distroless references in README**

Run: `grep -i "dockerfile.distroless\|rollback" README.md`

Expected: No matches

- [ ] **Step 7: Stop test containers**

```bash
docker compose -f docker-compose.dev.yaml down
```

- [ ] **Step 8: Review all commits**

Run: `git log --oneline -12`

Expected: Should see all commits from this implementation (Tasks 1-7)

- [ ] **Step 9: Create final summary**

All success criteria met:
- ✅ All legacy debian-slim files deleted
- ✅ Dockerfile.distroless renamed to Dockerfile
- ✅ All references updated in docker-compose.dev.yaml and workflows
- ✅ README.md reduced to ~300 lines with clear nginx-proxy-ctl section
- ✅ nginx port 80 redirects to HTTPS
- ✅ nginx port 443 returns "Connection succeed\n" at root
- ✅ docker-compose builds and starts successfully
- ✅ nginx-proxy-ctl functionality verified
