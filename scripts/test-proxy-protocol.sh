#!/bin/bash
# scripts/test-proxy-protocol.sh
# Verifies PROXY protocol is working correctly
#
# This test script checks:
# 1. mod_net_proxy is loaded in Prosody
# 2. Community modules directory is mounted
# 3. PROXY protocol configuration is present
# 4. Minimal localhost IPs in logs (indicates real IPs are being preserved)

set -euo pipefail

echo "=== PROXY Protocol Verification ==="
echo ""

# Test 1: Module loaded (check logs for 'proxy' service)
echo "1. Checking if mod_net_proxy is loaded..."
if docker compose logs prosody 2>&1 | grep -q "Activated service 'proxy'"; then
    echo "   ✅ PASSED: mod_net_proxy is loaded (proxy service active)"
else
    echo "   ❌ FAILED: mod_net_proxy not loaded or proxy service not started"
    echo "   Hint: Run ./scripts/init-prosody-modules.sh to clone prosody-modules"
    echo "   Hint: Check: docker compose logs prosody | grep error"
    exit 1
fi

# Test 2: Community modules path exists
echo "2. Checking community modules directory..."
if docker compose exec -T prosody test -d /usr/lib/prosody/community/mod_net_proxy; then
    echo "   ✅ PASSED: mod_net_proxy directory exists"
else
    echo "   ❌ FAILED: Community modules not mounted"
    echo "   Hint: Ensure prosody-modules directory exists and is mounted in docker-compose.yaml"
    echo "   Hint: Check: ls -la ./prosody-modules/mod_net_proxy/"
    exit 1
fi

# Test 3: Verify PROXY protocol config exists
echo "3. Checking Prosody PROXY protocol configuration..."
if docker compose exec -T prosody grep -q "proxy_port_mappings" /etc/prosody/conf.d/proxy.cfg.lua; then
    echo "   ✅ PASSED: PROXY protocol configured"
else
    echo "   ❌ FAILED: proxy_port_mappings not found in config"
    echo "   Hint: Check xmpp-proxy-stack/templates/prosody-proxy.cfg.lua"
    exit 1
fi

# Test 4: Verify plugin_paths is set
echo "4. Checking plugin_paths configuration..."
if docker compose exec -T prosody grep -q "plugin_paths" /etc/prosody/conf.d/proxy.cfg.lua; then
    echo "   ✅ PASSED: plugin_paths configured"
else
    echo "   ❌ FAILED: plugin_paths not found in config"
    echo "   Hint: plugin_paths must point to community modules directory"
    exit 1
fi

# Test 5: Check for excessive 127.0.0.1 in logs (heuristic test)
echo "5. Checking Prosody logs for localhost IPs (heuristic)..."
# Note: Some localhost entries are normal for internal operations
# This is a heuristic - excessive localhost IPs suggest PROXY protocol isn't working
LOCALHOST_COUNT=$(docker compose exec -T prosody grep -c "from 127.0.0.1" /var/log/prosody/prosody.log 2>/dev/null || echo "0")

if [ "$LOCALHOST_COUNT" -gt 20 ]; then
    echo "   ⚠️  WARNING: Found $LOCALHOST_COUNT instances of 'from 127.0.0.1' in logs"
    echo "   This may indicate PROXY protocol is not working correctly"
    echo "   Note: Some localhost entries are normal for internal operations"
    echo "   Recommendation: Connect a real XMPP client and verify real IP appears in logs"
else
    echo "   ✅ PASSED: Minimal localhost IPs in logs ($LOCALHOST_COUNT occurrences)"
fi

echo ""
echo "=== PROXY Protocol Basic Checks Passed ✅ ==="
echo ""
echo "For complete end-to-end verification:"
echo "  1. Connect a real XMPP client (Gajim, Conversations) from known IP"
echo "  2. Check logs: docker compose logs prosody | grep 'New connection'"
echo "  3. Verify your real client IP appears (not 127.0.0.1)"
echo "  4. Trigger fail2ban by failing auth 6 times from test IP"
echo "  5. Verify correct IP is banned: docker compose exec xmpp-proxy-stack fail2ban-rs status"
