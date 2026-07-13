#!/bin/bash
set -euo pipefail

echo "=== xmpp-proxy-stack initialization ==="

# Check required environment variables
if [ -z "${XMPP_DOMAIN:-}" ]; then
    echo "ERROR: XMPP_DOMAIN not set in .env"
    exit 1
fi

if [ -z "${ACME_EMAIL:-}" ]; then
    echo "ERROR: ACME_EMAIL not set in .env"
    exit 1
fi

# Set defaults for optional variables
export FAIL2BAN_MAX_RETRY="${FAIL2BAN_MAX_RETRY:-5}"
export FAIL2BAN_BAN_TIME="${FAIL2BAN_BAN_TIME:-1h}"
export FAIL2BAN_FIND_TIME="${FAIL2BAN_FIND_TIME:-10m}"

# Generate xmpp-proxy configuration from template
echo "Generating xmpp-proxy.toml..."
export PROSODY_HOST="prosody"  # DNS name in bridge network
envsubst < /etc/templates/xmpp-proxy.toml.template \
    > /etc/xmpp-proxy/xmpp-proxy.toml

# Generate fail2ban-rs configuration
echo "Generating fail2ban-rs config.toml..."
envsubst < /etc/templates/fail2ban-rs-config.toml.template \
    > /etc/fail2ban-rs/config.toml

# Check if TLS certificates exist
if [ ! -f /certs/fullchain.pem ]; then
    echo "No certificates found. Running ACME setup..."

    # Configure acmetool to auto-accept Terms of Service
    mkdir -p /var/lib/acme/conf
    cat > /var/lib/acme/conf/responses <<ACME_EOF
"acme-enter-email": "$ACME_EMAIL"
"acme-agreement:https://letsencrypt.org/documents/LE-SA-v1.8-July-06-2026.pdf": true
ACME_EOF

    echo "Requesting certificate for $XMPP_DOMAIN..."

    # Start nginx for HTTP-01 challenge
    nginx

    # Request certificate
    if ! acmetool want "$XMPP_DOMAIN"; then
        echo "ERROR: ACME certificate acquisition failed"
        echo ""
        echo "Possible causes:"
        echo "  1. DNS A/AAAA record for $XMPP_DOMAIN not pointing to this server"
        echo "  2. Port 80 blocked by firewall (needed for HTTP-01 challenge)"
        echo "  3. Let's Encrypt rate limit (5 failures per account per hour)"
        echo ""
        echo "Generating self-signed certificate for testing..."

        mkdir -p /certs
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout /certs/privkey.pem \
            -out /certs/fullchain.pem \
            -days 365 -subj "/CN=$XMPP_DOMAIN"

        echo "WARNING: Using self-signed certificate. Clients will show warnings."
    else
        # Symlink acmetool certs to shared location
        ln -sf "/var/lib/acme/live/$XMPP_DOMAIN/fullchain" /certs/fullchain.pem
        ln -sf "/var/lib/acme/live/$XMPP_DOMAIN/privkey" /certs/privkey.pem
        echo "Certificate successfully obtained!"
    fi

    # Stop nginx (will be restarted if needed)
    nginx -s stop 2>/dev/null || true
else
    echo "Certificates found in /certs/"
fi

# Setup cron for certificate renewal
echo "Setting up ACME renewal cron job..."
echo "0 3 * * * /usr/bin/acmetool reconcile >> /logs/acme-renewal.log 2>&1" \
    | crontab -

echo "Starting cron daemon..."
cron

# Initialize fail2ban-rs firewall
echo "Initializing fail2ban-rs firewall..."
if command -v nft &> /dev/null; then
    nft add table inet fail2ban-rs 2>/dev/null || true
    echo "nftables backend ready"
elif command -v iptables &> /dev/null; then
    echo "nftables not available, using iptables backend"
else
    echo "ERROR: Neither nftables nor iptables available"
    exit 1
fi

# Start supervisor (manages xmpp-proxy and fail2ban-rs)
echo "Starting supervisor..."
echo "=== Initialization complete, starting services ==="
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
