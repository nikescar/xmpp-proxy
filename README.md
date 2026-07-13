# XMPP Docker Compose Deployment

Production-ready XMPP server deployment using Docker Compose with xmpp-proxy, Prosody, fail2ban-rs, and automated ACME certificates.

## Features

✅ **Automated TLS** - Let's Encrypt certificates via acmetool  
✅ **Multi-protocol** - STARTTLS, Direct TLS, QUIC, WebSocket support  
✅ **Intrusion prevention** - fail2ban-rs with nftables/iptables  
✅ **Simple setup** - Configure via \`.env\` file  
✅ **Real client IPs** - PROXY protocol forwarding to Prosody  
✅ **Production-ready** - Health checks, auto-restart, backup/restore  

## Quick Start

\`\`\`bash
# 1. Clone repository
git clone https://github.com/nikescar/xmpp-proxy
cd xmpp-proxy

# 2. Configure
cp .env.example .env
nano .env  # Set XMPP_DOMAIN and ACME_EMAIL

# 3. Create data directories
sudo mkdir -p /srv/xmpp/{certs,prosody,logs,fail2ban,acme}
sudo chown -R \$USER:\$USER /srv/xmpp

# 4. Deploy
docker compose up -d

# 5. Create admin user
docker compose exec prosody prosodyctl adduser admin@chat.example.com
\`\`\`

See [QUICKSTART.md](docs/QUICKSTART.md) for detailed instructions.

## Architecture

\`\`\`
┌─────────────────────────────────────┐
│ xmpp-proxy-stack (host network)    │
│  • xmpp-proxy (TLS termination)    │
│  • fail2ban-rs (intrusion prevent) │
│  • acmetool (ACME certificates)    │
│  • nginx (HTTP-01 challenge)       │
│  • supervisor (process manager)    │
└────────────┬────────────────────────┘
             │ PROXY protocol
             ▼
┌─────────────────────────────────────┐
│ prosody (bridge network)            │
│  • Official prosodyim/prosody:13.0  │
│  • SQLite storage                   │
│  • mod_net_proxy enabled            │
└─────────────────────────────────────┘
\`\`\`

## Components

- **xmpp-proxy** - Reverse proxy from [nikescar/xmpp-proxy](https://github.com/nikescar/xmpp-proxy)
- **fail2ban-rs** - Intrusion prevention from [aejimmi/fail2ban-rs](https://github.com/aejimmi/fail2ban-rs)
- **Prosody** - XMPP server (official Docker image)
- **acmetool** - ACME client for Let's Encrypt
- **nginx** - Minimal HTTP server for ACME challenges
- **supervisor** - Process manager for xmpp-proxy and fail2ban-rs

## Requirements

- Docker and Docker Compose
- Linux server with public IP
- Domain name with DNS A/AAAA record
- Ports: 80, 443, 5222, 5269, 5443 open

## Configuration

Edit \`.env\` file:

\`\`\`bash
# Required
XMPP_DOMAIN=chat.example.com
ACME_EMAIL=admin@example.com

# Optional
XMPP_ADMIN=admin@chat.example.com
PROSODY_LOGLEVEL=info
ENABLE_WEB_ADMIN=false
FAIL2BAN_MAX_RETRY=5
FAIL2BAN_BAN_TIME=1h
\`\`\`

## Documentation

- **[Quick Start Guide](docs/QUICKSTART.md)** - Step-by-step deployment
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** - Common issues and solutions
- **[Design Specification](docs/superpowers/specs/2026-07-14-xmpp-docker-compose-design.md)** - Technical design

## Scripts

- **[backup.sh](scripts/backup.sh)** - Backup XMPP data
- **[restore.sh](scripts/restore.sh)** - Restore from backup
- **[test-deployment.sh](scripts/test-deployment.sh)** - Automated deployment tests

## Testing

Run automated test suite:

\`\`\`bash
./scripts/test-deployment.sh
\`\`\`

Tests:
- DNS resolution
- Port connectivity (5222, 5269, 443, 5443, 80)
- Container health (prosody, xmpp-proxy-stack)
- TLS certificate validity
- Service status (Prosody daemon, fail2ban-rs)

## Backup & Restore

**Backup:**
\`\`\`bash
./scripts/backup.sh
\`\`\`

Creates timestamped archive at \`/srv/xmpp/backups/xmpp-backup-YYYYMMDD-HHMMSS.tar.gz\`

**Restore:**
\`\`\`bash
./scripts/restore.sh /srv/xmpp/backups/xmpp-backup-20260714-030000.tar.gz
\`\`\`

## Security

- **TLS encryption** - All client connections encrypted via xmpp-proxy
- **PROXY protocol** - Real client IPs visible to Prosody for logging and bans
- **fail2ban-rs** - Automatic IP banning for failed auth, S2S abuse, stanza flooding
- **Ban escalation** - Exponential backoff for repeat offenders (1h, 2h, 4h, 8h, ...)
- **nftables/iptables** - Kernel-level packet filtering

## Monitoring

**View logs:**
\`\`\`bash
docker compose logs -f
tail -f /srv/xmpp/logs/*.log
\`\`\`

**Check fail2ban status:**
\`\`\`bash
docker compose exec xmpp-proxy-stack fail2ban-rs status
\`\`\`

**Prosody admin shell:**
\`\`\`bash
docker compose exec prosody prosodyctl shell
\`\`\`

## Updating

\`\`\`bash
# Pull latest images
docker compose pull

# Rebuild custom image
docker compose build --no-cache xmpp-proxy-stack

# Restart services
docker compose up -d
\`\`\`

## License

See [LICENSE](LICENSE) file.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Credits

- **xmpp-proxy** - https://github.com/moparisthebest/xmpp-proxy
- **fail2ban-rs** - https://github.com/aejimmi/fail2ban-rs
- **Prosody** - https://prosody.im/
- **acmetool** - https://github.com/hlandau/acme

## Support

- GitHub Issues: https://github.com/nikescar/xmpp-proxy/issues
- XMPP Chat: support@chat.example.com
