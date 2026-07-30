#!/usr/bin/env bats

load '../helpers/docker'
load '../helpers/http'
load '../helpers/wait'

setup_file() {
    export TEST_DIR="$BATS_TEST_DIRNAME"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # Build image if not exists
    if ! docker images xmpp-proxy-stack:test --format "{{.Repository}}" | grep -q "xmpp-proxy-stack"; then
        echo "Building test image..." >&2
        cd "$PROJECT_ROOT"
        docker build -t xmpp-proxy-stack:test -f Dockerfile .
    fi

    # Create test directories
    mkdir -p /tmp/xmpp-test-e2e/certs /tmp/xmpp-test-e2e/logs /tmp/xmpp-test-e2e/fail2ban /tmp/xmpp-test-e2e/acme
    chmod 777 /tmp/xmpp-test-e2e/certs /tmp/xmpp-test-e2e/logs /tmp/xmpp-test-e2e/fail2ban /tmp/xmpp-test-e2e/acme

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

teardown_file() {
    docker logs xmpp-proxy-stack-e2e > /tmp/xmpp-test-e2e-logs.txt 2>&1 || true
    docker rm -f xmpp-proxy-stack-e2e test-backend-e2e 2>/dev/null || true
    # acme.sh writes root-owned files under the acme volume, so remove via a
    # container (root) rather than the host shell.
    docker run --rm -v /tmp:/host-tmp --entrypoint /bin/busybox xmpp-proxy-stack:test rm -rf /host-tmp/xmpp-test-e2e 2>/dev/null || true
    rm -rf /tmp/xmpp-test-e2e 2>/dev/null || true
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

    # After removal, path reverts to default HTTP→HTTPS redirect (301)
    [ "$output" = "301" ]
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
