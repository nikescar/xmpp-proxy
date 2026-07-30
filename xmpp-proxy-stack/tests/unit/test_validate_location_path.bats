#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    export NGINX_PROXY_CTL_SOURCED=1
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
