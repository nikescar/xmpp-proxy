#!/bin/bash
set -euo pipefail

# Load environment
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

echo "=== XMPP Deployment Test Suite ==="
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

# Test function
test_check() {
    local test_name="$1"
    local test_cmd="$2"

    echo -n "Testing: $test_name... "
    if eval "$test_cmd" >/dev/null 2>&1; then
        echo "✅ PASS"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "❌ FAIL"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# DNS Test
test_check "DNS resolution for $XMPP_DOMAIN" \
    "dig +short $XMPP_DOMAIN A | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'"

# Port Connectivity Tests
test_check "Port 5222 (C2S) connectivity" \
    "nc -zv -w5 $XMPP_DOMAIN 5222"

test_check "Port 5269 (S2S) connectivity" \
    "nc -zv -w5 $XMPP_DOMAIN 5269"

# Container Status Tests
test_check "Prosody container running" \
    "docker compose ps | grep -q 'prosody.*Up'"

test_check "xmpp-proxy-stack container running" \
    "docker compose ps | grep -q 'xmpp-proxy-stack.*Up'"

# Service Health Tests
test_check "Prosody daemon responding" \
    "docker compose exec -T prosody prosodyctl status | grep -q 'Prosody is running'"

test_check "fail2ban-rs responding" \
    "docker compose exec -T xmpp-proxy-stack fail2ban-rs stats"

# PROXY Protocol Test
test_check "PROXY protocol (mod_net_proxy) loaded" \
    "docker compose logs prosody | grep -q \"Activated service 'proxy'\""

# Certificate Tests
test_check "Certificate files exist" \
    "[ -f /srv/xmpp/certs/fullchain.pem ] && [ -f /srv/xmpp/certs/privkey.pem ]"

test_check "TLS certificate valid for $XMPP_DOMAIN" \
    "echo | openssl s_client -connect $XMPP_DOMAIN:5222 -starttls xmpp 2>/dev/null | grep -q 'Verify return code: 0'"

# Data Directory Tests
test_check "Prosody data directory exists" \
    "[ -d /srv/xmpp/prosody ]"

test_check "Logs directory exists" \
    "[ -d /srv/xmpp/logs ]"

# Summary
echo ""
echo "=== Test Results ==="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo "✅ All tests passed!"
    echo ""
    echo "Next steps:"
    echo "  1. Create admin user: docker compose exec prosody prosodyctl adduser admin@$XMPP_DOMAIN"
    echo "  2. Configure XMPP client (Gajim, Conversations, etc.)"
    echo "  3. Test federation with external XMPP server"
    exit 0
else
    echo "❌ Some tests failed. Check the output above."
    exit 1
fi
