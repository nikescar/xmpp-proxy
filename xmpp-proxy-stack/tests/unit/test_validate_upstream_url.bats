#!/usr/bin/env bats

setup() {
    export TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
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
