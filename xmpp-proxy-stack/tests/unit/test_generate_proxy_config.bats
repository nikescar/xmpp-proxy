#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
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
