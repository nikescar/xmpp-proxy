#!/usr/bin/env bats

load '../helpers/docker'

setup_file() {
    export TEST_DIR="$BATS_TEST_DIRNAME"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # Build the distroless image
    echo "Building distroless image..." >&2
    cd "$PROJECT_ROOT"
    docker build -t xmpp-proxy-stack:test -f Dockerfile.distroless .
}

teardown_file() {
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
