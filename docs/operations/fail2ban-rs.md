# Managing fail2ban-rs from outside Docker

`fail2ban-rs` runs inside the distroless `xmpp-proxy-stack` container,
supervised by horust (`xmpp-proxy-stack/horust-services/fail2ban-rs.toml`,
restart strategy `always`, runs as `root` since it needs `nftables`
privileges — this is also why `xmpp-proxy-stack` carries `cap_add: NET_ADMIN`
in `docker-compose.yaml`). Unlike nginx and xmpp-proxy, it ships a full
control CLI, so runtime management doesn't rely on signals.

All commands below run via `docker exec` directly — no shell required, the
binary is invoked straight from `/usr/local/bin/fail2ban-rs`.

## How CLI commands reach the running daemon

The daemon (`fail2ban-rs run`) listens on a Unix socket at
`/var/run/fail2ban-rs/fail2ban-rs.sock`. Every other subcommand
(`status`, `list-bans`, `stats`, `ban`, `unban`, `reload`) is a thin client
that talks to the already-running daemon over that socket — they act on live
state, not just the config file, and require the daemon to be up.

```bash
docker exec xmpp-proxy-stack /bin/busybox ls /var/run/fail2ban-rs/
```

## Jails configured in this stack

Defined in `xmpp-proxy-stack/templates/fail2ban-rs-config.toml.template`:

| Jail | Log source | Ports protected | Trigger |
|---|---|---|---|
| `xmpp-auth` | `/logs/prosody.log` | 5222, 5223 (C2S) | Failed authentication / SASL |
| `xmpp-s2s-abuse` | `/logs/prosody.log` | 5269 (S2S) | Connection rate limit, invalid XML |
| `xmpp-stanza-flood` | `/logs/xmpp-proxy.log` | (xmpp-proxy's own listeners) | Oversized stanzas, rate limit |
| `nginx-scan` | `/logs/nginx-access.log` | 80, 443 (nginx) | Requests for known exploit paths (`wp-login`, `.env`, `.git`, `phpmyadmin`, etc.) — low threshold (2 hits/10m), since a single hit is never legitimate |
| `nginx-abuse` | `/logs/nginx-access.log` | 80, 443 (nginx) | Repeated 400/401/403/413 responses on any path — higher threshold (15 hits/2m) |

`nginx-scan`/`nginx-abuse` close the gap where nginx's public ports (ACME,
`/health`, redirects, and any `nginx-proxy-ctl`-added or `ENABLE_WEB_ADMIN`
reverse-proxy routes) previously had no fail2ban-rs coverage at all — only
xmpp-proxy's ports did.

`nginx-abuse` deliberately excludes HTTP 404 from its status-code match: on
this stack, Prosody's `admin_web2` serves its static assets
(`bootstrap-1.4.0.min.css`, `jquery`, `strophe.min.js`, `adhoc.js`) under
paths that 404 on every legitimate page load through the nginx reverse proxy
(a pre-existing asset-path issue, unrelated to abuse). Counting 404s in a
generic jail would ban the real admin under normal browser use — verified
against a live 43k-line `nginx-access.log` with `dry-run`, where the actual
admin IP racked up 86 hits under a 404-inclusive pattern and zero under the
403/401/400/413-only one. 404-based exploit-path scanning is still covered,
just narrowly, by `nginx-scan`'s explicit path list instead of a blanket
status-code match.

## Checking status and stats

```bash
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs status
# fail2ban-rs is running

docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs stats
```

`stats` returns JSON with per-jail counters:

```json
{
  "active_bans": 0,
  "jails": {
    "xmpp-auth": { "active_bans": 0, "total_bans": 0, "total_failures": 0 },
    "xmpp-s2s-abuse": { "active_bans": 0, "total_bans": 0, "total_failures": 0 },
    "xmpp-stanza-flood": { "active_bans": 0, "total_bans": 0, "total_failures": 0 },
    "nginx-scan": { "active_bans": 0, "total_bans": 0, "total_failures": 0 },
    "nginx-abuse": { "active_bans": 0, "total_bans": 0, "total_failures": 0 }
  },
  "total_bans": 0,
  "total_failures": 0,
  "total_unbans": 0,
  "uptime_secs": 4583
}
```

## Listing and managing bans

```bash
# Human-readable table
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs list-bans

# Machine-readable (one JSON object per line)
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs list-bans --json
```

Ban or unban an IP by hand (e.g. to pre-emptively block an abusive IP, or
release a false positive) — both require `--jail`:

```bash
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs ban --jail xmpp-auth 203.0.113.99
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs unban --jail xmpp-auth 203.0.113.99
```

Manual bans apply real `nftables` rules immediately (not a dry run) and
respect the jail's configured `ban_time`/escalation settings, exactly like an
automatic ban would.

## Reloading configuration

```bash
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs reload
```

Re-reads `/etc/fail2ban-rs/config.toml` in the running daemon over the
control socket — no restart, no dropped bans/state. This is the fail2ban-rs
equivalent of `nginx -s reload` / `prosodyctl reload`, and is preferable to
killing the process for any config-only change.

Config is regenerated from
`xmpp-proxy-stack/templates/fail2ban-rs-config.toml.template` by
`docker-entrypoint.sh` on every container start, substituting
`FAIL2BAN_MAX_RETRY` / `FAIL2BAN_BAN_TIME` / `FAIL2BAN_FIND_TIME` from `.env`
— edit the template (or `.env`), not the in-container file, for changes to
survive a restart. After editing the template, either restart the container
or edit `/etc/fail2ban-rs/config.toml` directly for a same-session test, then
`reload`.

## Testing filters before relying on them

Two commands let you validate a jail's regex/log format without waiting for
a real attack or touching any ban state:

```bash
# Test one pattern against one line
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs regex \
  --pattern 'Failed authentication for .* from <HOST>' \
  --line 'Failed authentication for user123 from 203.0.113.5'

# Replay a whole log file through a jail's filters, no bans applied
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs dry-run /logs/prosody.log --jail xmpp-auth
```

## Discovering built-in filters and generating new jails

fail2ban-rs bundles filter templates for common non-XMPP services (useful if
you expose anything else through this stack via `nginx-proxy-ctl`):

```bash
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs list-filters
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs gen-config nginx-auth
```

`gen-config <service>` prints a ready-to-paste `[jail.*]` block (supported
services: `sshd`, `nginx-auth`, `nginx-botsearch`, `postfix`, `dovecot`,
`vsftpd`, `asterisk`, `mysqld`) — paste the output into
`fail2ban-rs-config.toml.template` and reload/restart to activate it.

## GeoIP / MaxMind status

```bash
docker exec xmpp-proxy-stack /usr/local/bin/fail2ban-rs list-maxmind
```

Shows whether ASN/Country/City MaxMind databases are configured (not set up
by default in this stack).

## Restarting the daemon

Only needed for changes `reload` can't apply (there are none currently known
— `reload` covers the full config). If ever needed:

```bash
docker exec xmpp-proxy-stack /bin/busybox killall -TERM fail2ban-rs
```

horust (`always` strategy, 10s backoff) relaunches it automatically. Or
restart the whole container (also restarts nginx, xmpp-proxy, acme cron):

```bash
docker compose restart xmpp-proxy-stack
```

## Ban state persistence

Ban state lives in `/var/lib/fail2ban-rs/state` (write-ahead log +
lock file), mounted from the host at `/srv/xmpp/fail2ban` — it survives
container restarts and recreation, unlike nginx's `conf.d`.

```bash
docker exec xmpp-proxy-stack /bin/busybox ls -la /var/lib/fail2ban-rs/state
```

## Logs

```bash
docker exec xmpp-proxy-stack /bin/busybox cat /logs/fail2ban-rs-stdout.log
docker exec xmpp-proxy-stack /bin/busybox cat /logs/fail2ban-rs-stderr.log
```

Also on the host at `/srv/xmpp/logs/fail2ban-rs-*.log`.
