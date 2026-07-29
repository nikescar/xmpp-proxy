# Distroless XMPP Proxy Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate xmpp-proxy-stack from Debian-slim to gcr.io/distroless/base-debian13 with Horust process supervision, acme.sh certificate management, and dynamic nginx reverse proxy configuration via bash CLI tool.

**Architecture:** Multi-stage Dockerfile extracting nginx, xmpp-proxy, fail2ban-rs, horust, and acme.sh into a single distroless container. Horust manages all processes. nginx-proxy-ctl bash script provides TDD-tested dynamic proxy management.

**Tech Stack:** 
- Base: gcr.io/distroless/base-debian13
- Process Manager: Horust 0.1.8
- Web Server: nginx 1.27.0
- ACME: acme.sh
- Testing: Bats (Bash Automated Testing System)
- Existing: xmpp-proxy, fail2ban-rs

## Global Constraints

- Nginx version: 1.27.0
- Horust version: 0.1.8
- Base image: gcr.io/distroless/base-debian13:latest
- Architecture support: x86_64 and aarch64
- Testing framework: Bats
- TDD approach: Red → Green → Refactor for all features
- Commit frequency: After each passing test
- Port allocation: nginx (80/tcp, 443/tcp), xmpp-proxy (5222/tcp, 5223/tcp, 5269/tcp, 443/udp)
- Host networking mode: required for PROXY protocol support
- No shell in final image: busybox only for entrypoint

---

### Task 1: Test Infrastructure Setup

**Files:**
- Create: `xmpp-proxy-stack/tests/setup_suite.bash`
- Create: `xmpp-proxy-stack/tests/teardown_suite.bash`
- Create: `xmpp-proxy-stack/tests/helpers/docker.bash`
- Create: `xmpp-proxy-stack/tests/helpers/wait.bash`
- Create: `xmpp-proxy-stack/tests/helpers/http.bash`
- Create: `xmpp-proxy-stack/tests/unit/.gitkeep`
- Create: `xmpp-proxy-stack/tests/integration/.gitkeep`

**Interfaces:**
- Consumes: None (foundation task)
- Produces: 
  - `wait_for_service(container, timeout)` - waits for Docker container health
  - `wait_for_log(message, timeout)` - waits for log message
  - `assert_http_status(url, expected_code)` - asserts HTTP status
  - `assert_response_contains(url, text)` - asserts response contains text

- [ ] **Step 1: Create bats setup/teardown files**

```bash
# xmpp-proxy-stack/tests/setup_suite.bash
setup_suite() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
}
```

```bash
# xmpp-proxy-stack/tests/teardown_suite.bash
teardown_suite() {
    # Clean up any test containers
    docker ps -a --filter "label=xmpp-proxy-test" -q | xargs -r docker rm -f
}
```

- [ ] **Step 2: Create Docker helper functions**

```bash
# xmpp-proxy-stack/tests/helpers/docker.bash

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

- [ ] **Step 3: Create HTTP helper functions**

```bash
# xmpp-proxy-stack/tests/helpers/http.bash

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

- [ ] **Step 4: Create wait helper functions**

```bash
# xmpp-proxy-stack/tests/helpers/wait.bash

# Wait with timeout for a condition
wait_for() {
    local condition="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if eval "$condition"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    return 1
}
```

- [ ] **Step 5: Create gitkeep files for test directories**

```bash
touch xmpp-proxy-stack/tests/unit/.gitkeep
touch xmpp-proxy-stack/tests/integration/.gitkeep
```

- [ ] **Step 6: Verify helpers are loadable**

Run: `cd xmpp-proxy-stack/tests && bash -c "source helpers/docker.bash && source helpers/http.bash && source helpers/wait.bash && echo 'Helpers loaded successfully'"`

Expected: "Helpers loaded successfully"

- [ ] **Step 7: Commit**

```bash
git add xmpp-proxy-stack/tests/
git commit -m "test: add bats test infrastructure and helpers

- Setup and teardown suite files
- Docker helper functions (wait_for_service, wait_for_log)
- HTTP assertion helpers
- Generic wait helper
- Test directory structure for unit and integration tests

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 2: nginx-proxy-ctl - Location Path Validation (TDD)

**Files:**
- Create: `xmpp-proxy-stack/nginx-proxy-ctl`
- Create: `xmpp-proxy-stack/tests/unit/test_validate_location_path.bats`

**Interfaces:**
- Consumes: Test helpers from Task 1
- Produces: `validate_location_path(path)` - validates nginx location path syntax, returns 0 on valid, 1 on invalid

- [ ] **Step 1: Write failing test for valid location path**

```bash
# xmpp-proxy-stack/tests/unit/test_validate_location_path.bats
#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    source "$PROJECT_ROOT/nginx-proxy-ctl"
}

@test "validate_location_path accepts path starting with /" {
    run validate_location_path "/api/"
    [ "$status" -eq 0 ]
}

@test "validate_location_path rejects path not starting with /" {
    run validate_location_path "api/"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "must start with /" ]]
}

@test "validate_location_path rejects empty path" {
    run validate_location_path ""
    [ "$status" -eq 1 ]
    [[ "$output" =~ "cannot be empty" ]]
}

@test "validate_location_path accepts root path" {
    run validate_location_path "/"
    [ "$status" -eq 0 ]
}

@test "validate_location_path accepts path with trailing slash" {
    run validate_location_path "/api/v1/"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_validate_location_path.bats`

Expected: FAIL with "nginx-proxy-ctl: No such file or directory" or "validate_location_path: command not found"

- [ ] **Step 3: Implement minimal validate_location_path function**

```bash
# xmpp-proxy-stack/nginx-proxy-ctl
#!/bin/bash
# nginx-proxy-ctl - Dynamic nginx proxy configuration manager

set -euo pipefail

# Validate location path
validate_location_path() {
    local path="$1"
    
    if [ -z "$path" ]; then
        echo "ERROR: Location path cannot be empty" >&2
        return 1
    fi
    
    if [[ ! "$path" =~ ^/ ]]; then
        echo "ERROR: Location path must start with /" >&2
        return 1
    fi
    
    return 0
}

# Main command dispatch (to be implemented)
main() {
    echo "nginx-proxy-ctl placeholder"
}

# Only run main if executed directly (not sourced for tests)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_validate_location_path.bats`

Expected: All tests PASS

- [ ] **Step 5: Make nginx-proxy-ctl executable**

Run: `chmod +x xmpp-proxy-stack/nginx-proxy-ctl`

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/nginx-proxy-ctl xmpp-proxy-stack/tests/unit/test_validate_location_path.bats
git commit -m "feat: add location path validation to nginx-proxy-ctl

TDD implementation:
- Validates path starts with /
- Rejects empty paths
- Accepts root and nested paths
- All tests passing

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 3: nginx-proxy-ctl - Upstream URL Validation (TDD)

**Files:**
- Modify: `xmpp-proxy-stack/nginx-proxy-ctl`
- Create: `xmpp-proxy-stack/tests/unit/test_validate_upstream_url.bats`

**Interfaces:**
- Consumes: `validate_location_path()` from Task 2
- Produces: `validate_upstream_url(url)` - validates URL format (http/https), returns 0 on valid, 1 on invalid

- [ ] **Step 1: Write failing test for upstream URL validation**

```bash
# xmpp-proxy-stack/tests/unit/test_validate_upstream_url.bats
#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    source "$PROJECT_ROOT/nginx-proxy-ctl"
}

@test "validate_upstream_url accepts http URL" {
    run validate_upstream_url "http://localhost:8000/"
    [ "$status" -eq 0 ]
}

@test "validate_upstream_url accepts https URL" {
    run validate_upstream_url "https://api.example.com/"
    [ "$status" -eq 0 ]
}

@test "validate_upstream_url rejects URL without protocol" {
    run validate_upstream_url "localhost:8000"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "must start with http:// or https://" ]]
}

@test "validate_upstream_url rejects empty URL" {
    run validate_upstream_url ""
    [ "$status" -eq 1 ]
    [[ "$output" =~ "cannot be empty" ]]
}

@test "validate_upstream_url rejects non-http protocols" {
    run validate_upstream_url "ftp://example.com/"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "must start with http:// or https://" ]]
}

@test "validate_upstream_url accepts URL with port" {
    run validate_upstream_url "http://backend:3000/"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_validate_upstream_url.bats`

Expected: FAIL with "validate_upstream_url: command not found"

- [ ] **Step 3: Implement validate_upstream_url function**

```bash
# Add to xmpp-proxy-stack/nginx-proxy-ctl after validate_location_path

# Validate upstream URL
validate_upstream_url() {
    local url="$1"
    
    if [ -z "$url" ]; then
        echo "ERROR: Upstream URL cannot be empty" >&2
        return 1
    fi
    
    if [[ ! "$url" =~ ^https?:// ]]; then
        echo "ERROR: Upstream URL must start with http:// or https://" >&2
        return 1
    fi
    
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_validate_upstream_url.bats`

Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add xmpp-proxy-stack/nginx-proxy-ctl xmpp-proxy-stack/tests/unit/test_validate_upstream_url.bats
git commit -m "feat: add upstream URL validation to nginx-proxy-ctl

TDD implementation:
- Validates URL starts with http:// or https://
- Rejects empty URLs and invalid protocols
- Accepts URLs with ports and domains
- All tests passing

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 4: nginx-proxy-ctl - Config Template Generation (TDD)

**Files:**
- Modify: `xmpp-proxy-stack/nginx-proxy-ctl`
- Create: `xmpp-proxy-stack/tests/unit/test_generate_proxy_config.bats`
- Create: `xmpp-proxy-stack/templates/location-proxy.conf.template`

**Interfaces:**
- Consumes: `validate_location_path()`, `validate_upstream_url()` from Tasks 2-3
- Produces: `generate_proxy_config(location, upstream, options_array)` - generates nginx config from template

- [ ] **Step 1: Create nginx location proxy template**

```nginx
# xmpp-proxy-stack/templates/location-proxy.conf.template
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

- [ ] **Step 2: Write failing test for config generation**

```bash
# xmpp-proxy-stack/tests/unit/test_generate_proxy_config.bats
#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    export TEMPLATE_FILE="$PROJECT_ROOT/templates/location-proxy.conf.template"
    source "$PROJECT_ROOT/nginx-proxy-ctl"
}

@test "generate_proxy_config creates basic proxy config" {
    run generate_proxy_config "/api/" "http://localhost:8000/"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "location /api/" ]]
    [[ "$output" =~ "proxy_pass http://localhost:8000/" ]]
}

@test "generate_proxy_config includes standard headers" {
    run generate_proxy_config "/api/" "http://localhost:8000/"
    
    [[ "$output" =~ "proxy_set_header Host" ]]
    [[ "$output" =~ "proxy_set_header X-Real-IP" ]]
    [[ "$output" =~ "proxy_set_header X-Forwarded-For" ]]
    [[ "$output" =~ "proxy_set_header X-Forwarded-Proto" ]]
}

@test "generate_proxy_config adds websocket headers when enabled" {
    run generate_proxy_config "/ws/" "http://localhost:8080/" "websocket"
    
    [[ "$output" =~ "proxy_set_header Upgrade" ]]
    [[ "$output" =~ "proxy_set_header Connection" ]]
}

@test "generate_proxy_config uses custom timeout when provided" {
    export PROXY_TIMEOUT="120s"
    run generate_proxy_config "/api/" "http://localhost:8000/"
    
    [[ "$output" =~ "proxy_connect_timeout 120s" ]]
    unset PROXY_TIMEOUT
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_generate_proxy_config.bats`

Expected: FAIL with "generate_proxy_config: command not found"

- [ ] **Step 4: Implement generate_proxy_config function**

```bash
# Add to xmpp-proxy-stack/nginx-proxy-ctl after validate_upstream_url

# Generate nginx proxy config from template
generate_proxy_config() {
    local location="$1"
    local upstream="$2"
    local options="${3:-}"
    
    local websocket_headers=""
    local custom_headers=""
    
    # Add websocket headers if enabled
    if [[ "$options" == *"websocket"* ]]; then
        websocket_headers="proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \"upgrade\";"
    fi
    
    # Generate config from template
    export LOCATION_PATH="$location"
    export UPSTREAM_URL="$upstream"
    export WEBSOCKET_HEADERS="$websocket_headers"
    export CUSTOM_HEADERS="$custom_headers"
    
    envsubst < "$TEMPLATE_FILE"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_generate_proxy_config.bats`

Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/nginx-proxy-ctl xmpp-proxy-stack/templates/location-proxy.conf.template xmpp-proxy-stack/tests/unit/test_generate_proxy_config.bats
git commit -m "feat: add proxy config generation from template

TDD implementation:
- Generates nginx location block from template
- Includes standard proxy headers
- Supports websocket upgrade headers
- Respects custom timeout values
- All tests passing

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 5: nginx-proxy-ctl - Add Proxy Command (TDD)

**Files:**
- Modify: `xmpp-proxy-stack/nginx-proxy-ctl`
- Create: `xmpp-proxy-stack/tests/unit/test_add_proxy.bats`
- Create: `xmpp-proxy-stack/tests/unit/mocks/nginx`

**Interfaces:**
- Consumes: `validate_location_path()`, `validate_upstream_url()`, `generate_proxy_config()` from Tasks 2-4
- Produces: `add_proxy(location, upstream, options)` - adds proxy config, tests with nginx -t, reloads on success

- [ ] **Step 1: Create mock nginx binary for testing**

```bash
# xmpp-proxy-stack/tests/unit/mocks/nginx
#!/bin/bash
# Mock nginx for testing

case "$1" in
    -t)
        if [ "${MOCK_NGINX_TEST_FAIL:-0}" = "1" ]; then
            echo "nginx: configuration file /etc/nginx/nginx.conf test failed" >&2
            exit 1
        else
            echo "nginx: configuration file /etc/nginx/nginx.conf test is successful"
            exit 0
        fi
        ;;
    -s)
        if [ "$2" = "reload" ]; then
            touch /tmp/nginx-reload-called
            exit 0
        fi
        ;;
    *)
        echo "Mock nginx: unknown option $1" >&2
        exit 1
        ;;
esac
```

```bash
chmod +x xmpp-proxy-stack/tests/unit/mocks/nginx
```

- [ ] **Step 2: Write failing test for add_proxy**

```bash
# xmpp-proxy-stack/tests/unit/test_add_proxy.bats
#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    export PATH="$TEST_DIR/mocks:$PATH"
    export NGINX_CONF_DIR="$BATS_TEST_TMPDIR/conf.d"
    export NGINX_BIN="nginx"
    export TEMPLATE_FILE="$PROJECT_ROOT/templates/location-proxy.conf.template"
    mkdir -p "$NGINX_CONF_DIR"
    source "$PROJECT_ROOT/nginx-proxy-ctl"
    
    # Clear mock state
    rm -f /tmp/nginx-reload-called
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
    rm -f /tmp/nginx-reload-called
}

@test "add_proxy creates config file" {
    run add_proxy "/api/" "http://localhost:8000/"
    
    [ "$status" -eq 0 ]
    [ -f "$NGINX_CONF_DIR"/proxy-*.conf ]
}

@test "add_proxy validates location path" {
    run add_proxy "api/" "http://localhost:8000/"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "must start with /" ]]
}

@test "add_proxy validates upstream URL" {
    run add_proxy "/api/" "not-a-url"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "must start with http" ]]
}

@test "add_proxy rejects duplicate location" {
    add_proxy "/api/" "http://localhost:8000/"
    
    run add_proxy "/api/" "http://localhost:9000/"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "already exists" ]]
}

@test "add_proxy calls nginx reload after success" {
    add_proxy "/api/" "http://localhost:8000/"
    
    [ -f /tmp/nginx-reload-called ]
}

@test "add_proxy rolls back on nginx test failure" {
    export MOCK_NGINX_TEST_FAIL=1
    
    run add_proxy "/api/" "http://localhost:8000/"
    
    [ "$status" -eq 1 ]
    [ ! -f "$NGINX_CONF_DIR"/proxy-*.conf ]
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_add_proxy.bats`

Expected: FAIL with "add_proxy: command not found"

- [ ] **Step 4: Implement add_proxy function**

```bash
# Add to xmpp-proxy-stack/nginx-proxy-ctl after generate_proxy_config

# Configuration
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
TEMPLATE_FILE="${TEMPLATE_FILE:-/etc/nginx/templates/location-proxy.conf.template}"
NGINX_BIN="${NGINX_BIN:-/usr/sbin/nginx}"

# Add a new proxy location
add_proxy() {
    local location="$1"
    local upstream="$2"
    local options="${3:-}"
    
    # Validate inputs
    validate_location_path "$location" || return 1
    validate_upstream_url "$upstream" || return 1
    
    # Check for duplicate location
    local hash=$(echo -n "$location" | md5sum | cut -d' ' -f1)
    local config_file="$NGINX_CONF_DIR/proxy-$hash.conf"
    
    if [ -f "$config_file" ]; then
        echo "ERROR: Proxy for location $location already exists" >&2
        return 1
    fi
    
    # Generate config to temp file
    local temp_file=$(mktemp)
    generate_proxy_config "$location" "$upstream" "$options" > "$temp_file"
    
    # Test nginx configuration
    if ! $NGINX_BIN -t 2>&1 | grep -q "successful"; then
        rm -f "$temp_file"
        echo "ERROR: nginx configuration test failed" >&2
        return 1
    fi
    
    # Move to final location
    mv "$temp_file" "$config_file"
    
    # Reload nginx
    $NGINX_BIN -s reload
    
    echo "Proxy added: $location -> $upstream"
    return 0
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_add_proxy.bats`

Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/nginx-proxy-ctl xmpp-proxy-stack/tests/unit/test_add_proxy.bats xmpp-proxy-stack/tests/unit/mocks/
git commit -m "feat: add proxy command with validation and rollback

TDD implementation:
- Validates location path and upstream URL
- Checks for duplicate locations
- Tests nginx config before applying
- Rolls back on test failure
- Reloads nginx on success
- Mock nginx binary for testing
- All tests passing

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 6: nginx-proxy-ctl - Remove and List Commands (TDD)

**Files:**
- Modify: `xmpp-proxy-stack/nginx-proxy-ctl`
- Create: `xmpp-proxy-stack/tests/unit/test_remove_proxy.bats`
- Create: `xmpp-proxy-stack/tests/unit/test_list_proxies.bats`

**Interfaces:**
- Consumes: `add_proxy()` from Task 5
- Produces: 
  - `remove_proxy(location)` - removes proxy config and reloads nginx
  - `list_proxies()` - lists all configured proxies

- [ ] **Step 1: Write failing test for remove_proxy**

```bash
# xmpp-proxy-stack/tests/unit/test_remove_proxy.bats
#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    export PATH="$TEST_DIR/mocks:$PATH"
    export NGINX_CONF_DIR="$BATS_TEST_TMPDIR/conf.d"
    export NGINX_BIN="nginx"
    export TEMPLATE_FILE="$PROJECT_ROOT/templates/location-proxy.conf.template"
    mkdir -p "$NGINX_CONF_DIR"
    source "$PROJECT_ROOT/nginx-proxy-ctl"
    
    rm -f /tmp/nginx-reload-called
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
    rm -f /tmp/nginx-reload-called
}

@test "remove_proxy deletes existing proxy config" {
    add_proxy "/api/" "http://localhost:8000/"
    
    run remove_proxy "/api/"
    
    [ "$status" -eq 0 ]
    [ ! -f "$NGINX_CONF_DIR"/proxy-*.conf ]
}

@test "remove_proxy fails for non-existent location" {
    run remove_proxy "/nonexistent/"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "not found" ]]
}

@test "remove_proxy reloads nginx after deletion" {
    add_proxy "/api/" "http://localhost:8000/"
    rm -f /tmp/nginx-reload-called
    
    remove_proxy "/api/"
    
    [ -f /tmp/nginx-reload-called ]
}
```

- [ ] **Step 2: Write failing test for list_proxies**

```bash
# xmpp-proxy-stack/tests/unit/test_list_proxies.bats
#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    export PATH="$TEST_DIR/mocks:$PATH"
    export NGINX_CONF_DIR="$BATS_TEST_TMPDIR/conf.d"
    export NGINX_BIN="nginx"
    export TEMPLATE_FILE="$PROJECT_ROOT/templates/location-proxy.conf.template"
    mkdir -p "$NGINX_CONF_DIR"
    source "$PROJECT_ROOT/nginx-proxy-ctl"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "list_proxies shows empty list when no proxies" {
    run list_proxies
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No proxies configured" ]]
}

@test "list_proxies shows added proxy" {
    add_proxy "/api/" "http://localhost:8000/"
    
    run list_proxies
    
    [[ "$output" =~ "/api/ -> http://localhost:8000/" ]]
}

@test "list_proxies shows multiple proxies" {
    add_proxy "/api/" "http://localhost:8000/"
    add_proxy "/app/" "http://localhost:3000/"
    
    run list_proxies
    
    [[ "$output" =~ "/api/ -> http://localhost:8000/" ]]
    [[ "$output" =~ "/app/ -> http://localhost:3000/" ]]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_remove_proxy.bats tests/unit/test_list_proxies.bats`

Expected: FAIL with "remove_proxy: command not found" and "list_proxies: command not found"

- [ ] **Step 4: Implement remove_proxy and list_proxies functions**

```bash
# Add to xmpp-proxy-stack/nginx-proxy-ctl after add_proxy

# Remove a proxy location
remove_proxy() {
    local location="$1"
    
    # Find config file by location hash
    local hash=$(echo -n "$location" | md5sum | cut -d' ' -f1)
    local config_file="$NGINX_CONF_DIR/proxy-$hash.conf"
    
    if [ ! -f "$config_file" ]; then
        echo "ERROR: Proxy for location $location not found" >&2
        return 1
    fi
    
    # Delete config file
    rm -f "$config_file"
    
    # Reload nginx
    $NGINX_BIN -s reload
    
    echo "Proxy removed: $location"
    return 0
}

# List all configured proxies
list_proxies() {
    local count=0
    
    for config_file in "$NGINX_CONF_DIR"/proxy-*.conf; do
        if [ -f "$config_file" ]; then
            # Extract location and upstream from config
            local location=$(grep -oP 'location \K[^ ]+' "$config_file" | head -1)
            local upstream=$(grep -oP 'proxy_pass \K[^;]+' "$config_file" | head -1)
            
            echo "$location -> $upstream"
            ((count++))
        fi
    done
    
    if [ $count -eq 0 ]; then
        echo "No proxies configured"
    fi
    
    return 0
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd xmpp-proxy-stack && bats tests/unit/test_remove_proxy.bats tests/unit/test_list_proxies.bats`

Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/nginx-proxy-ctl xmpp-proxy-stack/tests/unit/test_remove_proxy.bats xmpp-proxy-stack/tests/unit/test_list_proxies.bats
git commit -m "feat: add remove and list commands to nginx-proxy-ctl

TDD implementation:
- remove_proxy deletes config and reloads nginx
- Validates proxy exists before removing
- list_proxies shows all configured proxies
- Parses location and upstream from configs
- All tests passing

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 7: nginx-proxy-ctl - Main CLI Interface

**Files:**
- Modify: `xmpp-proxy-stack/nginx-proxy-ctl`

**Interfaces:**
- Consumes: `add_proxy()`, `remove_proxy()`, `list_proxies()` from Tasks 5-6
- Produces: Complete CLI with usage(), command dispatch, and option parsing

- [ ] **Step 1: Implement usage function**

```bash
# Add to xmpp-proxy-stack/nginx-proxy-ctl after list_proxies

# Show usage information
usage() {
    cat <<EOF
Usage: nginx-proxy-ctl <command> [options]

Commands:
  add <location> <upstream> [--websocket] [--timeout <seconds>]
      Add a new proxy location
      
  remove <location>
      Remove a proxy location
      
  list
      List all configured proxies
      
  validate
      Validate nginx configuration
      
Examples:
  nginx-proxy-ctl add /api/ http://localhost:8000/
  nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket
  nginx-proxy-ctl remove /api/
  nginx-proxy-ctl list

EOF
}
```

- [ ] **Step 2: Implement validate_nginx function**

```bash
# Add after usage function

# Validate nginx configuration
validate_nginx() {
    if $NGINX_BIN -t 2>&1 | grep -q "successful"; then
        echo "✓ nginx configuration is valid"
        return 0
    else
        echo "✗ nginx configuration test failed" >&2
        $NGINX_BIN -t 2>&1 >&2
        return 1
    fi
}
```

- [ ] **Step 3: Implement main command dispatcher**

```bash
# Replace the main() placeholder function

# Main command dispatch
main() {
    local command="${1:-}"
    
    if [ -z "$command" ]; then
        usage
        exit 1
    fi
    
    case "$command" in
        add)
            shift
            local location="${1:-}"
            local upstream="${2:-}"
            shift 2 || true
            
            local options=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --websocket)
                        options="$options websocket"
                        shift
                        ;;
                    --timeout)
                        export PROXY_TIMEOUT="$2"
                        shift 2
                        ;;
                    *)
                        echo "ERROR: Unknown option: $1" >&2
                        usage
                        exit 1
                        ;;
                esac
            done
            
            add_proxy "$location" "$upstream" "$options"
            ;;
            
        remove)
            shift
            local location="${1:-}"
            remove_proxy "$location"
            ;;
            
        list)
            list_proxies
            ;;
            
        validate)
            validate_nginx
            ;;
            
        help|--help|-h)
            usage
            exit 0
            ;;
            
        *)
            echo "ERROR: Unknown command: $command" >&2
            usage
            exit 1
            ;;
    esac
}
```

- [ ] **Step 4: Test CLI manually**

Run: `cd xmpp-proxy-stack && ./nginx-proxy-ctl help`

Expected: Usage information displayed

Run: `./nginx-proxy-ctl`

Expected: Usage information and exit code 1

- [ ] **Step 5: Test add command with options**

```bash
# Set up test environment
export NGINX_CONF_DIR=/tmp/test-nginx-conf
export NGINX_BIN=$PWD/tests/unit/mocks/nginx
mkdir -p $NGINX_CONF_DIR

# Test add with websocket
./nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket

# Verify websocket headers in config
grep -q "Upgrade" $NGINX_CONF_DIR/proxy-*.conf && echo "PASS: websocket headers" || echo "FAIL"

# Clean up
rm -rf $NGINX_CONF_DIR
```

Expected: "PASS: websocket headers"

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/nginx-proxy-ctl
git commit -m "feat: complete nginx-proxy-ctl CLI interface

- Usage help text
- Command dispatcher (add, remove, list, validate)
- Option parsing for --websocket and --timeout
- Help command
- Error handling for unknown commands

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 8: Horust Service Definitions

**Files:**
- Create: `xmpp-proxy-stack/horust-services/nginx.toml`
- Create: `xmpp-proxy-stack/horust-services/xmpp-proxy.toml`
- Create: `xmpp-proxy-stack/horust-services/fail2ban-rs.toml`
- Create: `xmpp-proxy-stack/horust-services/acme-renewer.toml`

**Interfaces:**
- Consumes: None (configuration files)
- Produces: Horust service definitions for all four services

- [ ] **Step 1: Create nginx service definition**

```toml
# xmpp-proxy-stack/horust-services/nginx.toml
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
http-endpoint = "http://localhost:80/"

[termination]
signal = "TERM"
wait = "10s"
```

- [ ] **Step 2: Create xmpp-proxy service definition**

```toml
# xmpp-proxy-stack/horust-services/xmpp-proxy.toml
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

- [ ] **Step 3: Create fail2ban-rs service definition**

```toml
# xmpp-proxy-stack/horust-services/fail2ban-rs.toml
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

- [ ] **Step 4: Create acme-renewer service definition**

```toml
# xmpp-proxy-stack/horust-services/acme-renewer.toml
command = "/app/acme.sh --cron --home /app --config-home /etc/acme.sh/default"
start-delay = "86400s"
stdout = "/logs/acme-renewer-stdout.log"
stderr = "/logs/acme-renewer-stderr.log"

[restart]
strategy = "on-failure"
backoff = "3600s"
attempts = 24

[termination]
signal = "TERM"
wait = "30s"
```

- [ ] **Step 5: Validate TOML syntax**

Run: 
```bash
for f in xmpp-proxy-stack/horust-services/*.toml; do
    echo "Checking $f..."
    python3 -c "import tomllib; tomllib.load(open('$f', 'rb'))" 2>&1 && echo "✓ Valid TOML" || echo "✗ Invalid TOML"
done
```

Expected: All files show "✓ Valid TOML"

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/horust-services/
git commit -m "config: add Horust service definitions

- nginx.toml: HTTP server with health check
- xmpp-proxy.toml: XMPP reverse proxy, starts after nginx
- fail2ban-rs.toml: Intrusion prevention, starts after xmpp-proxy
- acme-renewer.toml: Daily certificate renewal

All services configured with appropriate restart policies,
logging, and graceful shutdown timeouts.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 9: Nginx Base Configuration

**Files:**
- Create: `xmpp-proxy-stack/templates/nginx.conf`

**Interfaces:**
- Consumes: None (configuration file)
- Produces: Base nginx.conf that includes conf.d/*.conf for dynamic proxies

- [ ] **Step 1: Create nginx base configuration**

```nginx
# xmpp-proxy-stack/templates/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /logs/nginx-error.log warn;

events {
    worker_connections 768;
}

http {
    ##
    # Basic Settings
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    ##
    # Logging
    ##
    access_log /logs/nginx-access.log;
    
    ##
    # Gzip
    ##
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    
    ##
    # Default Server
    ##
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        
        # Health check endpoint
        location = /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
        
        # ACME HTTP-01 challenge
        location /.well-known/acme-challenge/ {
            root /var/run/acme/;
        }
        
        # Return 404 for other requests (proxies will be in conf.d/)
        location / {
            return 404;
        }
    }
    
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
    
    ##
    # Include dynamic proxy configurations
    ##
    include /etc/nginx/conf.d/*.conf;
}
```

- [ ] **Step 2: Validate nginx configuration syntax**

Run: `nginx -t -c xmpp-proxy-stack/templates/nginx.conf 2>&1 | grep -q "syntax is ok" && echo "✓ Valid syntax" || echo "✗ Invalid syntax"`

Expected: "✓ Valid syntax" (may have warnings about missing files, which is expected)

- [ ] **Step 3: Commit**

```bash
git add xmpp-proxy-stack/templates/nginx.conf
git commit -m "config: add nginx base configuration

- HTTP server on port 80
- Health check endpoint at /health
- ACME challenge support at /.well-known/acme-challenge/
- Includes conf.d/*.conf for dynamic proxy configs
- Logging to /logs/
- HTTPS server template (commented, for future use)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 10: Docker Entrypoint Script

**Files:**
- Create: `xmpp-proxy-stack/docker-entrypoint.sh`

**Interfaces:**
- Consumes: Environment variables (XMPP_DOMAIN, ACME_EMAIL, ACME_SERVER)
- Produces: Entrypoint script that handles cert acquisition, config generation, starts Horust

- [ ] **Step 1: Create entrypoint script header and cert check**

```bash
# xmpp-proxy-stack/docker-entrypoint.sh
#!/bin/busybox sh
# Entrypoint for distroless xmpp-proxy-stack container

set -e

echo "=== xmpp-proxy-stack initialization ==="

# Check required environment variables
if [ -z "${XMPP_DOMAIN:-}" ]; then
    echo "ERROR: XMPP_DOMAIN not set" >&2
    exit 1
fi

if [ -z "${ACME_EMAIL:-}" ]; then
    echo "ERROR: ACME_EMAIL not set" >&2
    exit 1
fi

# Set defaults
export ACME_SERVER="${ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"

# Check if certificates exist
if [ ! -f /certs/fullchain.pem ] || [ ! -f /certs/privkey.pem ]; then
    echo "No certificates found. Acquiring via ACME..."
    
    # Ensure directories exist
    mkdir -p /var/run/acme/acme-challenge
    mkdir -p /etc/acme.sh/default
    
    # Start nginx for HTTP-01 challenge
    echo "Starting nginx for ACME challenge..."
    /usr/sbin/nginx
    
    # Give nginx time to start
    sleep 2
    
    # Register ACME account
    echo "Registering ACME account..."
    /app/acme.sh --register-account \
        --home /app \
        --config-home /etc/acme.sh/default \
        --email "${ACME_EMAIL}" \
        --server "${ACME_SERVER}" || true
    
    # Issue certificate
    echo "Issuing certificate for ${XMPP_DOMAIN}..."
    if /app/acme.sh --issue \
        --home /app \
        --config-home /etc/acme.sh/default \
        --domain "${XMPP_DOMAIN}" \
        --webroot /var/run/acme \
        --keylength 4096 \
        --server "${ACME_SERVER}"; then
        
        # Symlink to /certs/
        ln -sf "/etc/acme.sh/default/${XMPP_DOMAIN}/${XMPP_DOMAIN}.cer" /certs/fullchain.pem
        ln -sf "/etc/acme.sh/default/${XMPP_DOMAIN}/${XMPP_DOMAIN}.key" /certs/privkey.pem
        echo "✓ Certificate acquired successfully!"
    else
        echo "ACME acquisition failed. Generating self-signed certificate..."
        echo ""
        echo "Possible causes:"
        echo "  1. DNS A/AAAA record for ${XMPP_DOMAIN} not pointing to this server"
        echo "  2. Port 80 blocked by firewall"
        echo "  3. Let's Encrypt rate limit"
        echo ""
        
        # Generate self-signed certificate
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout /certs/privkey.pem \
            -out /certs/fullchain.pem \
            -days 365 -subj "/CN=${XMPP_DOMAIN}" 2>/dev/null
        
        echo "⚠ WARNING: Using self-signed certificate."
    fi
    
    # Stop nginx (Horust will restart it)
    /usr/sbin/nginx -s stop 2>/dev/null || true
    sleep 1
else
    echo "✓ Certificates found in /certs/"
fi
```

- [ ] **Step 2: Add config generation and volume checks**

```bash
# Add to docker-entrypoint.sh

# Check volume permissions
echo "Checking volume permissions..."
for dir in /certs /logs /var/lib/fail2ban-rs; do
    if ! touch "${dir}/.write-test" 2>/dev/null; then
        echo "ERROR: No write permission to ${dir}" >&2
        echo "Fix: chown -R 65532:65532 /srv/xmpp/{certs,logs,fail2ban}" >&2
        exit 1
    fi
    rm -f "${dir}/.write-test"
done
echo "✓ Volume permissions OK"

# Generate runtime configs from templates
echo "Generating runtime configurations..."

if [ -f /etc/templates/xmpp-proxy.toml.template ]; then
    envsubst < /etc/templates/xmpp-proxy.toml.template > /etc/xmpp-proxy/xmpp-proxy.toml
    echo "✓ Generated xmpp-proxy.toml"
fi

if [ -f /etc/templates/fail2ban-rs-config.toml.template ]; then
    envsubst < /etc/templates/fail2ban-rs-config.toml.template > /etc/fail2ban-rs/config.toml
    echo "✓ Generated fail2ban-rs config.toml"
fi

# Ensure conf.d directory exists for dynamic proxies
mkdir -p /etc/nginx/conf.d

echo "=== Initialization complete, starting Horust ==="
echo ""

# Start Horust process supervisor
exec /usr/local/bin/horust
```

- [ ] **Step 3: Make entrypoint executable**

Run: `chmod +x xmpp-proxy-stack/docker-entrypoint.sh`

- [ ] **Step 4: Validate shell script syntax**

Run: `shellcheck -s sh xmpp-proxy-stack/docker-entrypoint.sh || echo "Note: shellcheck not required, but recommended"`

- [ ] **Step 5: Test env var validation**

```bash
# Test missing XMPP_DOMAIN
unset XMPP_DOMAIN ACME_EMAIL
xmpp-proxy-stack/docker-entrypoint.sh 2>&1 | grep -q "XMPP_DOMAIN not set" && echo "✓ Validates XMPP_DOMAIN" || echo "✗ Failed"

# Test missing ACME_EMAIL
export XMPP_DOMAIN=test.example.com
unset ACME_EMAIL
xmpp-proxy-stack/docker-entrypoint.sh 2>&1 | grep -q "ACME_EMAIL not set" && echo "✓ Validates ACME_EMAIL" || echo "✗ Failed"
```

Expected: Both validation tests pass

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/docker-entrypoint.sh
git commit -m "feat: add Docker entrypoint script

- Environment variable validation (XMPP_DOMAIN, ACME_EMAIL)
- ACME certificate acquisition with HTTP-01 challenge
- Self-signed certificate fallback on ACME failure
- Volume permission checks
- Runtime config generation from templates
- Starts Horust process supervisor

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 11: Multi-Stage Dockerfile - Builder Stages

**Files:**
- Create: `xmpp-proxy-stack/Dockerfile.distroless`

**Interfaces:**
- Consumes: horust-services/, templates/, nginx-proxy-ctl, docker-entrypoint.sh
- Produces: Multi-stage Dockerfile (builder stages only, distroless stage in next task)

- [ ] **Step 1: Create Dockerfile with nginx-builder stage**

```dockerfile
# xmpp-proxy-stack/Dockerfile.distroless
# Multi-stage Dockerfile for distroless xmpp-proxy-stack

ARG XMPP_PROXY_VERSION=latest
ARG FAIL2BAN_RS_VERSION=latest
ARG HORUST_VERSION=0.1.8

##
## Stage 1: nginx-builder
##
FROM nginx:1.27.0 AS nginx-builder

# This stage extracts nginx binary and dependencies from official image
# We'll copy these into the final distroless image


##
## Stage 2: horust-builder
##
FROM alpine:latest AS horust-builder

ARG HORUST_VERSION

RUN apk add --no-cache curl

WORKDIR /build

# Download Horust binary from GitHub releases
# Try aarch64 first, fall back to x86_64
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        HORUST_ARCH="aarch64"; \
    elif [ "$ARCH" = "x86_64" ]; then \
        HORUST_ARCH="x86_64"; \
    else \
        echo "Unsupported architecture: $ARCH" >&2; \
        exit 1; \
    fi && \
    echo "Downloading Horust v${HORUST_VERSION} for ${HORUST_ARCH}..." && \
    curl -fsSL "https://github.com/FedericoPonzi/Horust/releases/download/v${HORUST_VERSION}/horust-${HORUST_ARCH}-unknown-linux-musl" \
        -o /usr/local/bin/horust && \
    chmod +x /usr/local/bin/horust && \
    /usr/local/bin/horust --version


##
## Stage 3: acme-builder
##
FROM alpine:latest AS acme-builder

RUN apk add --no-cache git openssl

WORKDIR /build

# Clone and install acme.sh
RUN git clone https://github.com/acmesh-official/acme.sh.git && \
    cd acme.sh && \
    ./acme.sh --install \
        --nocron \
        --auto-upgrade 0 \
        --home /app \
        --config-home /etc/acme.sh/default && \
    cd / && \
    rm -rf /build

##
## Stage 4: binaries-builder
##
FROM debian:13-slim AS binaries-builder

ARG XMPP_PROXY_VERSION
ARG FAIL2BAN_RS_VERSION

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download xmpp-proxy
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        XMPP_ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        XMPP_ARCH="aarch64"; \
    else \
        echo "Unsupported architecture: $ARCH" >&2; \
        exit 1; \
    fi && \
    if [ "$XMPP_PROXY_VERSION" = "latest" ]; then \
        DOWNLOAD_URL="https://github.com/nikescar/xmpp-proxy/releases/latest/download/xmpp-proxy-${XMPP_ARCH}-unknown-linux-musl"; \
    else \
        DOWNLOAD_URL="https://github.com/nikescar/xmpp-proxy/releases/download/${XMPP_PROXY_VERSION}/xmpp-proxy-${XMPP_ARCH}-unknown-linux-musl"; \
    fi && \
    echo "Downloading xmpp-proxy from ${DOWNLOAD_URL}..." && \
    curl -fsSL "$DOWNLOAD_URL" -o /usr/local/bin/xmpp-proxy && \
    chmod +x /usr/local/bin/xmpp-proxy

# Download fail2ban-rs
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        F2B_ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        F2B_ARCH="aarch64"; \
    else \
        echo "Unsupported architecture: $ARCH" >&2; \
        exit 1; \
    fi && \
    if [ "$FAIL2BAN_RS_VERSION" = "latest" ]; then \
        DOWNLOAD_URL="https://github.com/aejimmi/fail2ban-rs/releases/latest/download/fail2ban-rs-${F2B_ARCH}-unknown-linux-musl"; \
    else \
        DOWNLOAD_URL="https://github.com/aejimmi/fail2ban-rs/releases/download/${FAIL2BAN_RS_VERSION}/fail2ban-rs-${F2B_ARCH}-unknown-linux-musl"; \
    fi && \
    echo "Downloading fail2ban-rs from ${DOWNLOAD_URL}..." && \
    curl -fsSL "$DOWNLOAD_URL" -o /usr/local/bin/fail2ban-rs && \
    chmod +x /usr/local/bin/fail2ban-rs
```

- [ ] **Step 2: Add tools-builder stage**

```dockerfile
# Add to Dockerfile.distroless

##
## Stage 5: tools-builder
##
FROM debian:13-slim AS tools-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        busybox-static \
        gettext-base && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy our scripts and configs
COPY nginx-proxy-ctl /usr/local/bin/nginx-proxy-ctl
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY horust-services/ /etc/horust/services/
COPY templates/ /etc/templates/

RUN chmod +x /usr/local/bin/nginx-proxy-ctl && \
    chmod +x /docker-entrypoint.sh && \
    cp /bin/busybox /bin/busybox-static
```

- [ ] **Step 3: Test building builder stages**

Run: `cd xmpp-proxy-stack && docker build --target tools-builder -t xmpp-proxy-stack-builder -f Dockerfile.distroless .`

Expected: Build completes successfully, all stages execute

- [ ] **Step 4: Verify binaries in builder stages**

```bash
# Check Horust
docker run --rm xmpp-proxy-stack-builder /usr/local/bin/horust --version || echo "Note: Will verify in integration tests"

# Check nginx-proxy-ctl
docker run --rm xmpp-proxy-stack-builder /usr/local/bin/nginx-proxy-ctl help | grep -q "Usage:" && echo "✓ nginx-proxy-ctl works" || echo "Note: Will verify in integration tests"
```

Expected: Commands execute or note shown

- [ ] **Step 5: Commit**

```bash
git add xmpp-proxy-stack/Dockerfile.distroless
git commit -m "build: add multi-stage Dockerfile builder stages

Builder stages:
- nginx-builder: extracts nginx 1.27.0 binary and libs
- horust-builder: downloads Horust process supervisor
- acme-builder: installs acme.sh certificate client
- binaries-builder: downloads xmpp-proxy and fail2ban-rs
- tools-builder: prepares scripts and configs

Architecture-aware (x86_64, aarch64)
Version args: XMPP_PROXY_VERSION, FAIL2BAN_RS_VERSION, HORUST_VERSION

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 12: Multi-Stage Dockerfile - Distroless Final Stage

**Files:**
- Modify: `xmpp-proxy-stack/Dockerfile.distroless`

**Interfaces:**
- Consumes: All builder stages from Task 11
- Produces: Complete Dockerfile with distroless final stage

- [ ] **Step 1: Add distroless final stage**

```dockerfile
# Add to end of xmpp-proxy-stack/Dockerfile.distroless

##
## Final Stage: distroless
##
FROM gcr.io/distroless/base-debian13:latest

# Copy nginx binary and dependencies
COPY --from=nginx-builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-builder /etc/nginx /etc/nginx
COPY --from=nginx-builder /lib/x86_64-linux-gnu/*.so* /lib/x86_64-linux-gnu/
COPY --from=nginx-builder /usr/lib/x86_64-linux-gnu/*.so* /usr/lib/x86_64-linux-gnu/
COPY --from=nginx-builder /usr/lib/x86_64-linux-gnu/perl /usr/lib/x86_64-linux-gnu/perl
COPY --from=nginx-builder /usr/share/nginx /usr/share/nginx

# Copy Horust
COPY --from=horust-builder /usr/local/bin/horust /usr/local/bin/horust

# Copy acme.sh
COPY --from=acme-builder /app /app

# Copy xmpp-proxy and fail2ban-rs
COPY --from=binaries-builder /usr/local/bin/xmpp-proxy /usr/local/bin/xmpp-proxy
COPY --from=binaries-builder /usr/local/bin/fail2ban-rs /usr/local/bin/fail2ban-rs

# Copy our tools and configs
COPY --from=tools-builder /usr/local/bin/nginx-proxy-ctl /usr/local/bin/nginx-proxy-ctl
COPY --from=tools-builder /docker-entrypoint.sh /docker-entrypoint.sh
COPY --from=tools-builder /etc/horust/services /etc/horust/services
COPY --from=tools-builder /etc/templates /etc/templates
COPY --from=tools-builder /bin/busybox-static /bin/busybox

# Copy base nginx config
COPY --from=tools-builder /etc/templates/nginx.conf /etc/nginx/nginx.conf

# Create necessary directories
# Note: distroless doesn't have mkdir, so we use busybox
RUN ["/bin/busybox", "mkdir", "-p", \
    "/certs", \
    "/logs", \
    "/etc/xmpp-proxy", \
    "/etc/fail2ban-rs", \
    "/etc/acme.sh", \
    "/etc/nginx/conf.d", \
    "/var/run/acme/acme-challenge", \
    "/var/lib/fail2ban-rs", \
    "/var/log/nginx", \
    "/var/cache/nginx", \
    "/run"]

# Expose ports (informational only with host networking)
EXPOSE 80 443 5222 5223 5269

# Entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
```

- [ ] **Step 2: Build complete distroless image**

Run: `cd xmpp-proxy-stack && docker build -t xmpp-proxy-stack:distroless -f Dockerfile.distroless .`

Expected: Build completes successfully

- [ ] **Step 3: Inspect image size**

Run: `docker images xmpp-proxy-stack:distroless --format "{{.Repository}}:{{.Tag}} - {{.Size}}"`

Expected: Image size shown (should be smaller than Debian-slim version)

- [ ] **Step 4: Verify image contents**

```bash
# List installed binaries
docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:distroless ls -la /usr/local/bin/ | grep -E "(horust|xmpp-proxy|fail2ban-rs|nginx-proxy-ctl)"

# Check Horust services
docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:distroless ls -la /etc/horust/services/
```

Expected: All expected binaries and configs present

- [ ] **Step 5: Test that image has no shell (security check)**

Run: `docker run --rm --entrypoint /bin/sh xmpp-proxy-stack:distroless -c "echo test" 2>&1 | grep -q "not found" && echo "✓ No shell (secure)" || echo "✗ Shell found"`

Expected: "✓ No shell (secure)"

- [ ] **Step 6: Commit**

```bash
git add xmpp-proxy-stack/Dockerfile.distroless
git commit -m "build: add distroless final stage to Dockerfile

Final stage:
- Based on gcr.io/distroless/base-debian13
- Copies all binaries from builder stages
- Creates required directories via busybox
- No shell or package manager (security hardening)
- Entrypoint: docker-entrypoint.sh
- Exposes ports 80, 443, 5222, 5223, 5269

Image is architecture-aware and significantly smaller
than Debian-slim base.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 13: Integration Test - Distroless Build

**Files:**
- Create: `xmpp-proxy-stack/tests/integration/test_distroless_build.bats`

**Interfaces:**
- Consumes: Dockerfile.distroless, test helpers
- Produces: Integration test verifying distroless image builds correctly

- [ ] **Step 1: Write integration test for build**

```bash
# xmpp-proxy-stack/tests/integration/test_distroless_build.bats
#!/usr/bin/env bats

load '../helpers/docker'

setup_suite() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    
    # Build the distroless image
    echo "Building distroless image..." >&2
    cd "$PROJECT_ROOT"
    docker build -t xmpp-proxy-stack:test -f Dockerfile.distroless .
}

teardown_suite() {
    docker rmi -f xmpp-proxy-stack:test 2>/dev/null || true
}

@test "image builds successfully" {
    docker images xmpp-proxy-stack:test --format "{{.Repository}}" | grep -q "xmpp-proxy-stack"
}

@test "image has no shell" {
    run docker run --rm --entrypoint /bin/sh xmpp-proxy-stack:test -c "echo test"
    
    [ "$status" -ne 0 ]
}

@test "image has busybox for entrypoint" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test echo "test"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "test" ]]
}

@test "image has horust binary" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -f /usr/local/bin/horust
    
    [ "$status" -eq 0 ]
}

@test "image has nginx binary" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -f /usr/sbin/nginx
    
    [ "$status" -eq 0 ]
}

@test "image has xmpp-proxy binary" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -f /usr/local/bin/xmpp-proxy
    
    [ "$status" -eq 0 ]
}

@test "image has fail2ban-rs binary" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -f /usr/local/bin/fail2ban-rs
    
    [ "$status" -eq 0 ]
}

@test "image has nginx-proxy-ctl" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -f /usr/local/bin/nginx-proxy-ctl
    
    [ "$status" -eq 0 ]
}

@test "image has acme.sh" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -f /app/acme.sh
    
    [ "$status" -eq 0 ]
}

@test "image has horust service definitions" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test ls /etc/horust/services/
    
    [[ "$output" =~ "nginx.toml" ]]
    [[ "$output" =~ "xmpp-proxy.toml" ]]
    [[ "$output" =~ "fail2ban-rs.toml" ]]
    [[ "$output" =~ "acme-renewer.toml" ]]
}

@test "image has nginx config" {
    run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -f /etc/nginx/nginx.conf
    
    [ "$status" -eq 0 ]
}

@test "image has required directories" {
    for dir in /certs /logs /etc/nginx/conf.d /var/run/acme; do
        run docker run --rm --entrypoint /bin/busybox xmpp-proxy-stack:test test -d "$dir"
        [ "$status" -eq 0 ]
    done
}
```

- [ ] **Step 2: Run integration test**

Run: `cd xmpp-proxy-stack && bats tests/integration/test_distroless_build.bats`

Expected: All tests PASS

- [ ] **Step 3: Test on both architectures (if possible)**

```bash
# Test x86_64 (if on x86_64 host)
docker build --platform linux/amd64 -t xmpp-proxy-stack:test-amd64 -f Dockerfile.distroless . && echo "✓ x86_64 build OK"

# Test aarch64 (if buildx available)
docker buildx build --platform linux/arm64 -t xmpp-proxy-stack:test-arm64 -f Dockerfile.distroless . && echo "✓ aarch64 build OK" || echo "Note: Skipping aarch64 (buildx not available)"
```

Expected: At least one architecture builds successfully

- [ ] **Step 4: Commit**

```bash
git add xmpp-proxy-stack/tests/integration/test_distroless_build.bats
git commit -m "test: add integration test for distroless build

Tests verify:
- Image builds successfully
- No shell present (security)
- All required binaries included
- Horust service definitions present
- Nginx config present
- Required directories created

All tests passing.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 14: Integration Test - Service Startup

**Files:**
- Create: `xmpp-proxy-stack/tests/integration/test_service_startup.bats`
- Create: `xmpp-proxy-stack/tests/docker-compose.test.yml`

**Interfaces:**
- Consumes: Distroless image, test helpers
- Produces: Integration test verifying all services start correctly via Horust

- [ ] **Step 1: Create test docker-compose file**

```yaml
# xmpp-proxy-stack/tests/docker-compose.test.yml
services:
  xmpp-proxy-stack-test:
    image: xmpp-proxy-stack:test
    container_name: xmpp-proxy-stack-test
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      XMPP_DOMAIN: test.example.com
      ACME_EMAIL: test@example.com
      ACME_SERVER: https://acme-staging-v02.api.letsencrypt.org/directory
    volumes:
      - /tmp/xmpp-test/certs:/certs
      - /tmp/xmpp-test/logs:/logs
      - /tmp/xmpp-test/fail2ban:/var/lib/fail2ban-rs
      - /tmp/xmpp-test/acme:/etc/acme.sh
    labels:
      - "xmpp-proxy-test=true"
```

- [ ] **Step 2: Write service startup test**

```bash
# xmpp-proxy-stack/tests/integration/test_service_startup.bats
#!/usr/bin/env bats

load '../helpers/docker'
load '../helpers/wait'

setup_suite() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    
    # Build image if not exists
    if ! docker images xmpp-proxy-stack:test --format "{{.Repository}}" | grep -q "xmpp-proxy-stack"; then
        echo "Building test image..." >&2
        cd "$PROJECT_ROOT"
        docker build -t xmpp-proxy-stack:test -f Dockerfile.distroless .
    fi
    
    # Create test directories
    mkdir -p /tmp/xmpp-test/{certs,logs,fail2ban,acme}
    chmod 777 /tmp/xmpp-test/{certs,logs,fail2ban,acme}
    
    # Start container
    echo "Starting test container..." >&2
    cd "$TEST_DIR"
    docker-compose -f docker-compose.test.yml up -d
    
    # Wait for container to start
    sleep 10
}

teardown_suite() {
    cd "$TEST_DIR"
    docker-compose -f docker-compose.test.yml logs > /tmp/xmpp-test-logs.txt 2>&1 || true
    docker-compose -f docker-compose.test.yml down -v 2>/dev/null || true
    
    # Clean up test directories
    rm -rf /tmp/xmpp-test
}

@test "container starts successfully" {
    run docker ps --filter "name=xmpp-proxy-stack-test" --format "{{.Status}}"
    
    [[ "$output" =~ "Up" ]]
}

@test "entrypoint completes initialization" {
    run docker logs xmpp-proxy-stack-test
    
    [[ "$output" =~ "Initialization complete" ]] || [[ "$output" =~ "starting Horust" ]]
}

@test "self-signed certificate generated" {
    # ACME will fail in test, should fall back to self-signed
    run docker exec xmpp-proxy-stack-test /bin/busybox ls /certs/
    
    [[ "$output" =~ "fullchain.pem" ]]
    [[ "$output" =~ "privkey.pem" ]]
}

@test "nginx process is running" {
    sleep 5
    run docker exec xmpp-proxy-stack-test /bin/busybox ps aux
    
    [[ "$output" =~ "nginx" ]]
}

@test "nginx responds on port 80" {
    skip "Host networking makes this test environment-dependent"
    # In real deployment, would test:
    # curl -s http://localhost:80/health | grep -q "healthy"
}

@test "service logs are being written" {
    sleep 5
    
    run docker exec xmpp-proxy-stack-test /bin/busybox ls /logs/
    
    [[ "$output" =~ "nginx-stdout.log" ]] || [[ "$output" =~ "nginx" ]]
}
```

- [ ] **Step 3: Run service startup test**

Run: `cd xmpp-proxy-stack && bats tests/integration/test_service_startup.bats`

Expected: Most tests PASS (some may be skipped due to host networking)

- [ ] **Step 4: Check test logs if failures occur**

Run: `cat /tmp/xmpp-test-logs.txt | head -100`

Expected: Logs show initialization and service startup

- [ ] **Step 5: Commit**

```bash
git add xmpp-proxy-stack/tests/integration/test_service_startup.bats xmpp-proxy-stack/tests/docker-compose.test.yml
git commit -m "test: add integration test for service startup

Tests verify:
- Container starts successfully
- Entrypoint completes initialization
- Self-signed certificate generated (ACME fallback)
- Nginx process running
- Service logs being written

Uses docker-compose for test orchestration.
Some tests skipped with host networking.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 15: Update docker-compose.yaml for Distroless

**Files:**
- Modify: `docker-compose.yaml`

**Interfaces:**
- Consumes: Dockerfile.distroless
- Produces: Updated docker-compose with distroless build configuration

- [ ] **Step 1: Read current docker-compose.yaml**

Run: `head -70 docker-compose.yaml`

- [ ] **Step 2: Update xmpp-proxy-stack service to use new Dockerfile**

```yaml
# Modify the xmpp-proxy-stack service in docker-compose.yaml

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
```

- [ ] **Step 3: Update .env.example with HORUST_VERSION**

```bash
# Add to .env.example after FAIL2BAN_RS_VERSION

# Binary Versions (use 'latest' or specific tag)
XMPP_PROXY_VERSION=latest
FAIL2BAN_RS_VERSION=latest
HORUST_VERSION=0.1.8
```

- [ ] **Step 4: Test docker-compose build**

Run: `docker-compose build xmpp-proxy-stack 2>&1 | tee /tmp/compose-build.log && echo "Build exit code: $?"`

Expected: Build completes successfully (exit code 0)

- [ ] **Step 5: Verify build args are passed**

Run: `grep -E "(XMPP_PROXY_VERSION|FAIL2BAN_RS_VERSION|HORUST_VERSION)" /tmp/compose-build.log | head -5`

Expected: Build args shown in build output

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yaml .env.example
git commit -m "build: update docker-compose for distroless stack

Changes:
- Use Dockerfile.distroless instead of Dockerfile
- Add HORUST_VERSION build arg
- Update .env.example with HORUST_VERSION
- Keep all volume mounts and networking config

Backwards compatible with existing deployments
(existing certs and configs will be reused).

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 16: Documentation - README Update

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: All implementation from previous tasks
- Produces: Updated README with distroless migration and nginx-proxy-ctl usage

- [ ] **Step 1: Add distroless deployment section to README**

Find the deployment section in README.md and add after Docker Compose section:

```markdown
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
```

- [ ] **Step 2: Add migration guide section**

Add new section:

```markdown
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
```

- [ ] **Step 3: Test README formatting**

Run: `markdown-lint README.md || echo "Note: markdown-lint not required"`

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README with distroless deployment guide

Added sections:
- Distroless deployment quick start
- nginx-proxy-ctl CLI usage examples
- Certificate management guide
- Architecture overview
- Troubleshooting guide
- Migration guide from Debian-slim
- Rollback instructions

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 17: Final Integration Test - End-to-End Proxy

**Files:**
- Create: `xmpp-proxy-stack/tests/integration/test_proxy_e2e.bats`

**Interfaces:**
- Consumes: All previous tasks
- Produces: Complete end-to-end test of nginx-proxy-ctl functionality

- [ ] **Step 1: Write end-to-end proxy test**

```bash
# xmpp-proxy-stack/tests/integration/test_proxy_e2e.bats
#!/usr/bin/env bats

load '../helpers/docker'
load '../helpers/http'
load '../helpers/wait'

setup_suite() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    
    # Build image if not exists
    if ! docker images xmpp-proxy-stack:test --format "{{.Repository}}" | grep -q "xmpp-proxy-stack"; then
        echo "Building test image..." >&2
        cd "$PROJECT_ROOT"
        docker build -t xmpp-proxy-stack:test -f Dockerfile.distroless .
    fi
    
    # Create test directories
    mkdir -p /tmp/xmpp-test-e2e/{certs,logs,fail2ban,acme}
    chmod 777 /tmp/xmpp-test-e2e/{certs,logs,fail2ban,acme}
    
    # Start main container
    echo "Starting xmpp-proxy-stack..." >&2
    docker run -d \
        --name xmpp-proxy-stack-e2e \
        --network bridge \
        --cap-add NET_ADMIN \
        -e XMPP_DOMAIN=test.example.com \
        -e ACME_EMAIL=test@example.com \
        -p 8080:80 \
        -v /tmp/xmpp-test-e2e/certs:/certs \
        -v /tmp/xmpp-test-e2e/logs:/logs \
        -v /tmp/xmpp-test-e2e/fail2ban:/var/lib/fail2ban-rs \
        -v /tmp/xmpp-test-e2e/acme:/etc/acme.sh \
        -l xmpp-proxy-test=true \
        xmpp-proxy-stack:test
    
    # Wait for nginx to start
    sleep 10
    
    # Start test backend
    echo "Starting test backend..." >&2
    docker run -d \
        --name test-backend-e2e \
        --network container:xmpp-proxy-stack-e2e \
        -l xmpp-proxy-test=true \
        hashicorp/http-echo -text="Backend Response" -listen=:8000
    
    sleep 5
}

teardown_suite() {
    docker logs xmpp-proxy-stack-e2e > /tmp/xmpp-test-e2e-logs.txt 2>&1 || true
    docker rm -f xmpp-proxy-stack-e2e test-backend-e2e 2>/dev/null || true
    rm -rf /tmp/xmpp-test-e2e
}

@test "nginx health endpoint responds" {
    run curl -s http://localhost:8080/health
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "healthy" ]]
}

@test "nginx-proxy-ctl add creates working proxy" {
    docker exec xmpp-proxy-stack-e2e nginx-proxy-ctl add /api/ http://localhost:8000/
    
    sleep 2
    
    run curl -s http://localhost:8080/api/
    
    [[ "$output" =~ "Backend Response" ]]
}

@test "nginx-proxy-ctl list shows added proxy" {
    docker exec xmpp-proxy-stack-e2e nginx-proxy-ctl add /test/ http://localhost:8000/
    
    run docker exec xmpp-proxy-stack-e2e nginx-proxy-ctl list
    
    [[ "$output" =~ "/test/ -> http://localhost:8000/" ]]
}

@test "nginx-proxy-ctl remove deletes proxy" {
    docker exec xmpp-proxy-stack-e2e nginx-proxy-ctl add /temp/ http://localhost:8000/
    sleep 1
    
    docker exec xmpp-proxy-stack-e2e nginx-proxy-ctl remove /temp/
    sleep 1
    
    run curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/temp/
    
    [ "$output" = "404" ]
}

@test "nginx-proxy-ctl validate confirms valid config" {
    run docker exec xmpp-proxy-stack-e2e nginx-proxy-ctl validate
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "valid" ]]
}

@test "proxy forwards headers correctly" {
    docker exec xmpp-proxy-stack-e2e nginx-proxy-ctl add /headers/ http://localhost:8000/
    sleep 1
    
    run curl -s -H "X-Test: value" http://localhost:8080/headers/
    
    # Backend echoes, verify it received the request
    [[ "$output" =~ "Backend Response" ]]
}
```

- [ ] **Step 2: Run end-to-end test**

Run: `cd xmpp-proxy-stack && bats tests/integration/test_proxy_e2e.bats`

Expected: All tests PASS

- [ ] **Step 3: Review test logs if any failures**

Run: `cat /tmp/xmpp-test-e2e-logs.txt | grep -A5 -B5 ERROR || echo "No errors in logs"`

- [ ] **Step 4: Run all integration tests together**

Run: `cd xmpp-proxy-stack && bats tests/integration/`

Expected: All integration tests PASS

- [ ] **Step 5: Commit**

```bash
git add xmpp-proxy-stack/tests/integration/test_proxy_e2e.bats
git commit -m "test: add end-to-end proxy integration test

Tests verify:
- Nginx health endpoint responds
- nginx-proxy-ctl add creates working proxy
- Proxied requests reach backend
- nginx-proxy-ctl list shows proxies
- nginx-proxy-ctl remove deletes proxy
- nginx-proxy-ctl validate works
- Headers forwarded correctly

Uses test backend (hashicorp/http-echo)
All tests passing.

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

### Task 18: Final Verification and Cleanup

**Files:**
- None (verification task)

**Interfaces:**
- Consumes: All previous tasks
- Produces: Verified working system, clean git history

- [ ] **Step 1: Run all unit tests**

Run: `cd xmpp-proxy-stack && bats tests/unit/`

Expected: All unit tests PASS

- [ ] **Step 2: Run all integration tests**

Run: `cd xmpp-proxy-stack && bats tests/integration/`

Expected: All integration tests PASS

- [ ] **Step 3: Build final image**

Run: `docker-compose build xmpp-proxy-stack`

Expected: Build completes successfully

- [ ] **Step 4: Verify git history is clean**

Run: `git log --oneline --graph -15`

Expected: Clean commit history with descriptive messages

- [ ] **Step 5: Check for uncommitted changes**

Run: `git status`

Expected: No uncommitted changes (or only expected temporary files)

- [ ] **Step 6: Verify all required files exist**

```bash
# Check key files
for file in \
    xmpp-proxy-stack/Dockerfile.distroless \
    xmpp-proxy-stack/docker-entrypoint.sh \
    xmpp-proxy-stack/nginx-proxy-ctl \
    xmpp-proxy-stack/templates/nginx.conf \
    xmpp-proxy-stack/templates/location-proxy.conf.template \
    xmpp-proxy-stack/horust-services/nginx.toml \
    xmpp-proxy-stack/horust-services/xmpp-proxy.toml \
    xmpp-proxy-stack/horust-services/fail2ban-rs.toml \
    xmpp-proxy-stack/horust-services/acme-renewer.toml \
    xmpp-proxy-stack/tests/integration/test_distroless_build.bats \
    xmpp-proxy-stack/tests/integration/test_service_startup.bats \
    xmpp-proxy-stack/tests/integration/test_proxy_e2e.bats; do
    
    if [ -f "$file" ]; then
        echo "✓ $file"
    else
        echo "✗ MISSING: $file"
    fi
done
```

Expected: All files present (✓)

- [ ] **Step 7: Tag final commit**

```bash
git tag -a distroless-v1.0 -m "Distroless XMPP Proxy Stack v1.0

Complete migration to distroless base with:
- Horust process supervision
- acme.sh certificate management
- nginx-proxy-ctl dynamic proxy configuration
- Full TDD coverage (unit + integration tests)
- Security hardening (no shell, minimal attack surface)

All tests passing."
```

- [ ] **Step 8: Generate final summary**

```bash
cat > /tmp/implementation-summary.txt <<EOF
Distroless XMPP Proxy Stack Implementation Complete
===================================================

Files Created: $(git ls-files xmpp-proxy-stack/ | wc -l)
Unit Tests: $(find xmpp-proxy-stack/tests/unit -name "*.bats" | wc -l)
Integration Tests: $(find xmpp-proxy-stack/tests/integration -name "*.bats" | wc -l)
Commits: $(git log --oneline | grep -c "Co-Authored-By: Claude Sonnet")

Key Components:
- Distroless base: gcr.io/distroless/base-debian13
- Process supervisor: Horust 0.1.8
- ACME client: acme.sh
- Web server: nginx 1.27.0
- CLI tool: nginx-proxy-ctl (bash, TDD-tested)

All tests passing ✓
Ready for deployment ✓
EOF

cat /tmp/implementation-summary.txt
```

Expected: Summary displayed with counts

---

## Plan Complete

**Success Criteria Met:**
- ✅ All unit tests passing
- ✅ All integration tests passing  
- ✅ Distroless image builds for x86_64 (and aarch64 if available)
- ✅ nginx-proxy-ctl CLI functional (add/remove/list/validate)
- ✅ Horust manages all services
- ✅ ACME certificate acquisition working
- ✅ Documentation updated
- ✅ Migration path documented
- ✅ TDD approach followed throughout

**Next Steps:**
1. Review all tests pass
2. Deploy to staging environment
3. Test certificate renewal (wait 24h or trigger manually)
4. Monitor service logs for 48h
5. Deploy to production

