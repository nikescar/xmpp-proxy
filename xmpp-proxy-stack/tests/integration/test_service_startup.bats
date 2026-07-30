#!/usr/bin/env bats

load '../helpers/docker'
load '../helpers/wait'

setup_file() {
    export TEST_DIR="$BATS_TEST_DIRNAME"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # Build image if not exists
    if ! docker images xmpp-proxy-stack:test --format "{{.Repository}}" | grep -q "xmpp-proxy-stack"; then
        echo "Building test image..." >&2
        cd "$PROJECT_ROOT"
        docker build -t xmpp-proxy-stack:test -f Dockerfile.distroless .
    fi

    # Create test directories
    mkdir -p /tmp/xmpp-test/certs /tmp/xmpp-test/logs /tmp/xmpp-test/fail2ban /tmp/xmpp-test/acme
    chmod 777 /tmp/xmpp-test/certs /tmp/xmpp-test/logs /tmp/xmpp-test/fail2ban /tmp/xmpp-test/acme

    # Start container
    echo "Starting test container..." >&2
    cd "$TEST_DIR/.."
    docker compose -f docker-compose.test.yml up -d

    # Wait for container to start
    sleep 10
}

teardown_file() {
    cd "$TEST_DIR/.."
    docker compose -f docker-compose.test.yml logs > /tmp/xmpp-test-logs.txt 2>&1 || true
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true

    # Clean up test directories. acme.sh writes root-owned files under the
    # acme volume, so remove via a container (root) rather than the host shell.
    docker run --rm -v /tmp:/host-tmp --entrypoint /bin/busybox xmpp-proxy-stack:test rm -rf /host-tmp/xmpp-test 2>/dev/null || true
    rm -rf /tmp/xmpp-test 2>/dev/null || true
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
    # ACME will fail in test (test.example.com does not resolve here), should fall back to self-signed
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
