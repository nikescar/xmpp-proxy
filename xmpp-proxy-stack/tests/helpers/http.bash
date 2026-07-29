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
