# XMPP Docker Compose Quick Start

This guide will help you deploy a production XMPP server in under 10 minutes.

## Prerequisites

- Linux server with Docker and Docker Compose installed
- Public IP address
- Domain name (e.g., `chat.example.com`)
- DNS A/AAAA record pointing to your server
- Ports 80, 443, 5222, 5269, 5443 open in firewall

## Step 1: Configure DNS

Add these DNS records for your domain:

\`\`\`
# Required: A/AAAA record
chat.example.com.  3600  IN  A     YOUR_SERVER_IP
chat.example.com.  3600  IN  AAAA  YOUR_SERVER_IPv6  # If you have IPv6

# Optional but recommended: SRV records
_xmpp-client._tcp.chat.example.com.  3600  IN  SRV  0 5 5222 chat.example.com.
_xmpp-server._tcp.chat.example.com.  3600  IN  SRV  0 5 5269 chat.example.com.
\`\`\`

Verify DNS:
\`\`\`bash
dig +short chat.example.com A
\`\`\`

## Step 2: Clone Repository

\`\`\`bash
git clone https://github.com/nikescar/xmpp-proxy
cd xmpp-proxy
\`\`\`

## Step 3: Configure Environment

\`\`\`bash
# Copy environment template
cp .env.example .env

# Edit with your domain and email
nano .env
\`\`\`

Required variables:
\`\`\`bash
XMPP_DOMAIN=chat.example.com
ACME_EMAIL=admin@example.com
\`\`\`

## Step 4: Create Data Directories

\`\`\`bash
sudo mkdir -p /srv/xmpp/{certs,prosody,logs,fail2ban,acme}
sudo chown -R \$USER:\$USER /srv/xmpp
\`\`\`

## Step 5: Deploy

\`\`\`bash
docker compose up -d
\`\`\`

Watch logs:
\`\`\`bash
docker compose logs -f
\`\`\`

Wait for message: \`Certificate successfully obtained!\`

## Step 6: Verify Deployment

Run automated tests:
\`\`\`bash
./scripts/test-deployment.sh
\`\`\`

All tests should pass. If any fail, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Step 7: Create Admin User

\`\`\`bash
docker compose exec prosody prosodyctl adduser admin@chat.example.com
\`\`\`

Enter password when prompted.

## Step 8: Connect with XMPP Client

### Using Gajim (Desktop)

1. Install Gajim:
   \`\`\`bash
   sudo apt install gajim
   \`\`\`

2. Add account:
   - Account > Add Account
   - JID: \`admin@chat.example.com\`
   - Password: (from previous step)
   - Connection: Auto-detect settings

3. Connect and verify:
   - Check lock icon shows valid TLS
   - Send test message to another user

### Using Conversations (Android)

1. Install Conversations from F-Droid or Play Store
2. Add account: \`admin@chat.example.com\`
3. Enter password
4. Accept certificate (first connection only)

## Step 9: Test Federation

Send message to external XMPP server:
\`\`\`
To: friend@jabber.org
\`\`\`

Check S2S logs:
\`\`\`bash
docker compose logs prosody | grep s2s
\`\`\`

You should see outgoing connection to \`jabber.org\`.

## Next Steps

- **Add more users:** \`docker compose exec prosody prosodyctl adduser user@chat.example.com\`
- **Configure web admin** (optional): Set \`ENABLE_WEB_ADMIN=true\` in \`.env\`
- **Set up backups:** Add cron job for \`./scripts/backup.sh\`
- **Monitor logs:** \`tail -f /srv/xmpp/logs/*.log\`

## Common Commands

\`\`\`bash
# View logs
docker compose logs -f
docker compose logs prosody
docker compose logs xmpp-proxy-stack

# Restart services
docker compose restart

# Stop services
docker compose down

# Update images
docker compose pull
docker compose up -d --build

# Backup
./scripts/backup.sh

# Restore
./scripts/restore.sh /srv/xmpp/backups/xmpp-backup-*.tar.gz

# Check fail2ban status
docker compose exec xmpp-proxy-stack fail2ban-rs status

# Unban IP
docker compose exec xmpp-proxy-stack fail2ban-rs unban <IP> xmpp-auth
\`\`\`

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues and solutions.
