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
