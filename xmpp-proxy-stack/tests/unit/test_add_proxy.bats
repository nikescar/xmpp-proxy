#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
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
