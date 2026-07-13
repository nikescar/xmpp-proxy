FROM debian:12-slim

# Build arguments for binary versions
ARG XMPP_PROXY_VERSION=latest
ARG FAIL2BAN_RS_VERSION=latest

# Install dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gettext-base \
        acmetool \
        nginx-light \
        supervisor \
        cron \
        nftables \
        iptables \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p \
    /etc/xmpp-proxy \
    /etc/fail2ban-rs/jail.d \
    /certs \
    /logs \
    /var/lib/fail2ban-rs \
    /var/run/acme/acme-challenge

# Download xmpp-proxy binary
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then ARCH="aarch64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    if [ "$XMPP_PROXY_VERSION" = "latest" ]; then \
        DOWNLOAD_URL="https://github.com/nikescar/xmpp-proxy/releases/latest/download/xmpp-proxy-${ARCH}-unknown-linux-musl"; \
    else \
        DOWNLOAD_URL="https://github.com/nikescar/xmpp-proxy/releases/download/${XMPP_PROXY_VERSION}/xmpp-proxy-${ARCH}-unknown-linux-musl"; \
    fi && \
    curl -L "$DOWNLOAD_URL" -o /usr/local/bin/xmpp-proxy && \
    chmod +x /usr/local/bin/xmpp-proxy

# Download fail2ban-rs binary
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then ARCH="aarch64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    if [ "$FAIL2BAN_RS_VERSION" = "latest" ]; then \
        DOWNLOAD_URL="https://github.com/aejimmi/fail2ban-rs/releases/latest/download/fail2ban-rs-${ARCH}-unknown-linux-musl"; \
    else \
        DOWNLOAD_URL="https://github.com/aejimmi/fail2ban-rs/releases/download/${FAIL2BAN_RS_VERSION}/fail2ban-rs-${ARCH}-unknown-linux-musl"; \
    fi && \
    curl -L "$DOWNLOAD_URL" -o /usr/local/bin/fail2ban-rs && \
    chmod +x /usr/local/bin/fail2ban-rs

# Create xmpp-proxy user (fail2ban-rs runs as root)
RUN useradd -r -s /bin/false xmpp-proxy

# Copy configuration files
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY templates/ /etc/templates/

# Copy entrypoint script (will be created in next task)
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Expose ports (informational only, host networking ignores this)
EXPOSE 80 443 5222 5223 5269 5443

ENTRYPOINT ["/docker-entrypoint.sh"]
