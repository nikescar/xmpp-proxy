#!/bin/busybox sh
# Entrypoint for distroless xmpp-proxy-stack container

set -e

echo "=== xmpp-proxy-stack initialization ==="

# Check required environment variables
if [ -z "${XMPP_DOMAIN:-}" ]; then
    echo "ERROR: XMPP_DOMAIN not set" >&2
    exit 1
fi

if [ -z "${ACME_EMAIL:-}" ]; then
    echo "ERROR: ACME_EMAIL not set" >&2
    exit 1
fi

# Set defaults
export ACME_SERVER="${ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"

# Check if certificates exist
if [ ! -f /certs/fullchain.pem ] || [ ! -f /certs/privkey.pem ]; then
    echo "No certificates found. Acquiring via ACME..."

    # Ensure directories exist
    mkdir -p /var/run/acme/acme-challenge
    mkdir -p /etc/acme.sh/default

    # Generate temporary self-signed certificate for nginx to start
    # (nginx requires certs to exist even for HTTP-only operation due to HTTPS server block)
    echo "Generating temporary self-signed certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /certs/privkey.pem \
        -out /certs/fullchain.pem \
        -days 1 -subj "/CN=${XMPP_DOMAIN}" 2>/dev/null

    # Start nginx for HTTP-01 challenge
    echo "Starting nginx for ACME challenge..."
    /usr/sbin/nginx

    # Give nginx time to start
    sleep 2

    # Register ACME account
    echo "Registering ACME account..."
    /bin/busybox sh /app/acme.sh --register-account \
        --home /app \
        --config-home /etc/acme.sh/default \
        --email "${ACME_EMAIL}" \
        --server "${ACME_SERVER}" || true

    # Issue certificate
    echo "Issuing certificate for ${XMPP_DOMAIN}..."
    if /bin/busybox sh /app/acme.sh --issue \
        --home /app \
        --config-home /etc/acme.sh/default \
        --domain "${XMPP_DOMAIN}" \
        --webroot /var/run/acme \
        --keylength 4096 \
        --server "${ACME_SERVER}"; then

        # Replace temporary certs with real ones
        rm -f /certs/fullchain.pem /certs/privkey.pem
        ln -s "/etc/acme.sh/default/${XMPP_DOMAIN}/fullchain.cer" /certs/fullchain.pem
        ln -s "/etc/acme.sh/default/${XMPP_DOMAIN}/${XMPP_DOMAIN}.key" /certs/privkey.pem
        echo "✓ Certificate acquired successfully!"
    else
        echo "ACME acquisition failed. Using self-signed certificate..."
        echo ""
        echo "Possible causes:"
        echo "  1. DNS A/AAAA record for ${XMPP_DOMAIN} not pointing to this server"
        echo "  2. Port 80 blocked by firewall"
        echo "  3. Let's Encrypt rate limit"
        echo ""

        # Replace temporary cert with a longer-lived self-signed certificate
        rm -f /certs/fullchain.pem /certs/privkey.pem
        openssl req -x509 -newkey rsa:4096 -nodes \
            -keyout /certs/privkey.pem \
            -out /certs/fullchain.pem \
            -days 365 -subj "/CN=${XMPP_DOMAIN}" 2>/dev/null

        echo "⚠ WARNING: Using self-signed certificate."
    fi

    # Stop nginx (Horust will restart it)
    /usr/sbin/nginx -s stop 2>/dev/null || true
    sleep 1
else
    echo "✓ Certificates found in /certs/"
fi

# Check volume permissions
echo "Checking volume permissions..."
for dir in /certs /logs /var/lib/fail2ban-rs; do
    if ! touch "${dir}/.write-test" 2>/dev/null; then
        echo "ERROR: No write permission to ${dir}" >&2
        echo "Fix: chown -R 65532:65532 /srv/xmpp/{certs,logs,fail2ban}" >&2
        exit 1
    fi
    rm -f "${dir}/.write-test"
done
echo "✓ Volume permissions OK"

# Generate runtime configs from templates
echo "Generating runtime configurations..."

if [ -f /etc/templates/xmpp-proxy.toml.template ]; then
    envsubst < /etc/templates/xmpp-proxy.toml.template > /etc/xmpp-proxy/xmpp-proxy.toml
    echo "✓ Generated xmpp-proxy.toml"
fi

if [ -f /etc/templates/fail2ban-rs-config.toml.template ]; then
    envsubst < /etc/templates/fail2ban-rs-config.toml.template > /etc/fail2ban-rs/config.toml
    echo "✓ Generated fail2ban-rs config.toml"
fi

# Ensure conf.d directory exists for dynamic proxies
mkdir -p /etc/nginx/conf.d

# Optionally auto-configure a reverse proxy to Prosody's web admin
# (admin_web2), BOSH, and native XMPP WebSocket (XEP-0468) endpoints.
# conf.d isn't a volume, so anything added here or via nginx-proxy-ctl is
# lost on container recreation - recreate these fresh on every start
# instead of relying on a one-time manual `nginx-proxy-ctl add`. Written
# directly from the template (rather than via `nginx-proxy-ctl add`)
# because that command's final `nginx -s reload` requires an
# already-running nginx, and nginx hasn't been started yet at this point -
# Horust starts it fresh right after and picks these up without needing a
# reload.
if [ "${ENABLE_WEB_ADMIN:-false}" = "true" ]; then
    echo "Configuring Prosody web admin reverse proxy (ENABLE_WEB_ADMIN=true)..."
    for entry in \
        "/prosody/ http://127.0.0.1:15280 no 60s" \
        "/http-bind/ http://127.0.0.1:15280/http-bind/ no 150s" \
        "/xmpp-websocket http://127.0.0.1:15280/xmpp-websocket yes 60s" \
    ; do
        location_path=$(echo "$entry" | awk '{print $1}')
        upstream_url=$(echo "$entry" | awk '{print $2}')
        websocket=$(echo "$entry" | awk '{print $3}')
        # /http-bind/ gets a longer timeout than the others: Prosody's
        # bosh_max_wait (prosody-proxy.cfg.lua.template) is 120s - the
        # longest a BOSH long-poll hold request may legitimately stay open
        # with no data before Prosody itself responds empty. A 60s nginx
        # proxy_read_timeout fires well before that, killing the connection
        # with a 504 on every hold that outlasts 60s (confirmed live: BOSH
        # requests 504ing every ~60-90s in nginx-access.log). 150s clears
        # bosh_max_wait with margin for scheduling/network jitter.
        route_timeout=$(echo "$entry" | awk '{print $4}')
        websocket_headers=""
        if [ "$websocket" = "yes" ]; then
            websocket_headers='proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";'
        fi
        # Same md5-of-path naming nginx-proxy-ctl uses, so these show up in
        # `nginx-proxy-ctl list` and can be overridden/removed with it too.
        hash=$(echo -n "$location_path" | md5sum | awk '{print $1}')
        LOCATION_PATH="$location_path" UPSTREAM_URL="$upstream_url" WEBSOCKET_HEADERS="$websocket_headers" CUSTOM_HEADERS="" PROXY_TIMEOUT="$route_timeout" \
            envsubst '${LOCATION_PATH} ${UPSTREAM_URL} ${WEBSOCKET_HEADERS} ${CUSTOM_HEADERS} ${PROXY_TIMEOUT}' \
            < /etc/templates/location-proxy.conf.template > "/etc/nginx/conf.d/proxy-${hash}.conf"
    done
    echo "✓ Configured /prosody/ (admin), /http-bind/ (BOSH), and /xmpp-websocket reverse proxy locations"
fi

echo "=== Initialization complete, starting Horust ==="
echo ""

# Start Horust process supervisor
exec /usr/local/bin/horust
