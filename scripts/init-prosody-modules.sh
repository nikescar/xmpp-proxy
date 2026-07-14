#!/bin/bash
# scripts/init-prosody-modules.sh
# Clones prosody-modules repository for community module support

set -euo pipefail

MODULES_DIR="./prosody-modules"
MODULES_REPO="https://hg.prosody.im/prosody-modules"

echo "=== Prosody Community Modules Setup ==="

# Check if already exists
if [ -d "$MODULES_DIR" ]; then
    echo "✓ prosody-modules already exists at $MODULES_DIR"

    # Optionally update
    if [ "${UPDATE:-false}" = "true" ]; then
        echo "Updating modules..."
        cd "$MODULES_DIR"
        hg pull -u
        cd ..
        echo "✓ Modules updated"
    fi
else
    echo "Cloning prosody-modules repository..."

    # Check if mercurial is installed
    if ! command -v hg &> /dev/null; then
        echo "ERROR: Mercurial (hg) is not installed"
        echo "Install with: apt install mercurial  (or brew install mercurial)"
        exit 1
    fi

    # Clone repository
    hg clone "$MODULES_REPO" "$MODULES_DIR"
    echo "✓ Modules cloned successfully"
fi

# Verify mod_net_proxy exists
if [ -f "$MODULES_DIR/mod_net_proxy/mod_net_proxy.lua" ]; then
    echo "✓ mod_net_proxy found"
else
    echo "ERROR: mod_net_proxy not found in cloned repository"
    exit 1
fi

echo "=== Setup complete ==="
