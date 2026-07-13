# XMPP Deployment Troubleshooting

Common issues and solutions for XMPP Docker Compose deployment.

## ACME Certificate Issues

### Problem: "ACME certificate acquisition failed"

**Causes:**
- DNS not configured correctly
- Port 80 blocked
- Let's Encrypt rate limit

**Solutions:**

1. **Check DNS:**
   \`\`\`bash
   dig +short chat.example.com A
   \`\`\`
   Should return your server's IP.

2. **Check port 80:**
   \`\`\`bash
   nc -zv chat.example.com 80
   \`\`\`
   If this fails, open port 80 in your firewall:
   \`\`\`bash
   sudo ufw allow 80/tcp
   # or
   sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
   \`\`\`

3. **Check rate limits:**
   Let's Encrypt allows 5 failed attempts per hour.
   Wait 1 hour and retry:
   \`\`\`bash
   docker compose restart xmpp-proxy-stack
   \`\`\`

4. **Use self-signed cert temporarily:**
   The container automatically generates a self-signed certificate on failure.
   Fix DNS/firewall, then restart to get real certificate.

### Problem: "Verify return code: 20 (unable to get local issuer certificate)"

**Cause:** Self-signed certificate is in use.

**Solution:** Check logs for ACME failure reason:
\`\`\`bash
docker compose logs xmpp-proxy-stack | grep -i acme
\`\`\`

Fix the underlying issue and restart.

## Container Issues

### Problem: "xmpp-proxy-stack container exits immediately"

**Causes:**
- Missing required environment variables
- Binary download failed

**Solutions:**

1. **Check environment:**
   \`\`\`bash
   cat .env | grep -E "^(XMPP_DOMAIN|ACME_EMAIL)"
   \`\`\`
   Both should be set.

2. **Check logs:**
   \`\`\`bash
   docker compose logs xmpp-proxy-stack
   \`\`\`

3. **Rebuild image:**
   \`\`\`bash
   docker compose build --no-cache xmpp-proxy-stack
   docker compose up -d
   \`\`\`

### Problem: "Prosody container unhealthy"

**Cause:** Prosody failed to start or is misconfigured.

**Solutions:**

1. **Check Prosody logs:**
   \`\`\`bash
   docker compose logs prosody
   \`\`\`

2. **Check configuration:**
   \`\`\`bash
   docker compose exec prosody prosodyctl check
   \`\`\`

3. **Restart Prosody:**
   \`\`\`bash
   docker compose restart prosody
   \`\`\`

## Connection Issues

### Problem: "Cannot connect from XMPP client"

**Causes:**
- Port blocked
- Certificate invalid
- xmpp-proxy not forwarding to Prosody

**Solutions:**

1. **Test port connectivity:**
   \`\`\`bash
   nc -zv chat.example.com 5222
   \`\`\`

2. **Test TLS:**
   \`\`\`bash
   echo | openssl s_client -connect chat.example.com:5222 -starttls xmpp
   \`\`\`
   Look for "Verify return code: 0 (ok)"

3. **Check xmpp-proxy logs:**
   \`\`\`bash
   docker compose logs xmpp-proxy-stack | grep -i error
   \`\`\`

4. **Check Prosody logs:**
   \`\`\`bash
   tail -f /srv/xmpp/logs/prosody.log
   \`\`\`

### Problem: "Federation not working (can't send to jabber.org)"

**Causes:**
- Port 5269 blocked
- DNS SRV records incorrect
- Certificate issue

**Solutions:**

1. **Test S2S port:**
   \`\`\`bash
   nc -zv chat.example.com 5269
   \`\`\`

2. **Check S2S logs:**
   \`\`\`bash
   docker compose logs prosody | grep s2s
   \`\`\`

3. **Test outgoing S2S:**
   Send message to \`echo@conference.conversations.im\`
   Should receive echo reply.

## fail2ban-rs Issues

### Problem: "fail2ban-rs not starting"

**Cause:** nftables/iptables not available or NET_ADMIN capability missing.

**Solutions:**

1. **Check capability:**
   \`\`\`bash
   docker inspect xmpp-proxy-stack | grep NET_ADMIN
   \`\`\`
   Should show \`NET_ADMIN\` in CapAdd.

2. **Install nftables:**
   \`\`\`bash
   sudo apt install nftables
   \`\`\`

3. **Check fail2ban-rs logs:**
   \`\`\`bash
   docker compose logs xmpp-proxy-stack | grep fail2ban
   \`\`\`

### Problem: "IPs not getting banned"

**Cause:** Logs not being monitored or patterns not matching.

**Solutions:**

1. **Check fail2ban-rs status:**
   \`\`\`bash
   docker compose exec xmpp-proxy-stack fail2ban-rs status
   \`\`\`

2. **Check log files exist:**
   \`\`\`bash
   ls -lh /srv/xmpp/logs/
   \`\`\`
   Should see \`prosody.log\` and \`xmpp-proxy.log\`.

3. **Test ban manually:**
   Trigger 6 failed logins from test machine, then:
   \`\`\`bash
   docker compose exec xmpp-proxy-stack fail2ban-rs stats
   \`\`\`

## Performance Issues

### Problem: "High CPU usage"

**Cause:** Possible attack or misconfiguration.

**Solutions:**

1. **Check for attacks:**
   \`\`\`bash
   docker compose exec xmpp-proxy-stack fail2ban-rs stats
   \`\`\`

2. **Check connections:**
   \`\`\`bash
   docker compose exec prosody prosodyctl shell
   \`\`\`
   In shell:
   \`\`\`lua
   > for jid, session in pairs(prosody.full_sessions) do print(jid) end
   \`\`\`

3. **Adjust fail2ban thresholds:**
   Edit \`.env\`:
   \`\`\`bash
   FAIL2BAN_MAX_RETRY=3
   FAIL2BAN_FIND_TIME=5m
   \`\`\`
   Restart:
   \`\`\`bash
   docker compose restart xmpp-proxy-stack
   \`\`\`

## Data Recovery

### Problem: "Lost Prosody data after container restart"

**Cause:** Volumes not properly mounted.

**Solutions:**

1. **Check volume mounts:**
   \`\`\`bash
   docker inspect prosody | grep -A 10 Mounts
   \`\`\`
   Should show \`/srv/xmpp/prosody\` mounted.

2. **Restore from backup:**
   \`\`\`bash
   ./scripts/restore.sh /srv/xmpp/backups/xmpp-backup-*.tar.gz
   \`\`\`

## Getting Help

If you still have issues:

1. **Collect logs:**
   \`\`\`bash
   docker compose logs > xmpp-logs.txt
   \`\`\`

2. **Check system:**
   \`\`\`bash
   docker compose ps
   docker version
   docker compose version
   uname -a
   \`\`\`

3. **Report issue:**
   - GitHub: https://github.com/nikescar/xmpp-proxy/issues
   - Include logs and system info
   - Describe exact steps to reproduce
