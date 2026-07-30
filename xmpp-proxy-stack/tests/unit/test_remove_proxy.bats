#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    export PATH="$TEST_DIR/mocks:$PATH"
    export NGINX_CONF_DIR="$BATS_TEST_TMPDIR/conf.d"
    export NGINX_BIN="nginx"
    export TEMPLATE_FILE="$PROJECT_ROOT/templates/location-proxy.conf.template"
    mkdir -p "$NGINX_CONF_DIR"
    export NGINX_PROXY_CTL_SOURCED=1
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
