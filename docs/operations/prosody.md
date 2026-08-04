# Managing Prosody from outside Docker

The `prosody` container runs the official `prosodyim/prosody:13.0` image. Unlike
`xmpp-proxy-stack`, it is **not** distroless — it has a real shell (`bash`) and
the full `prosodyctl` toolset, so it can be managed directly with `docker exec`
from the host, no `busybox` workaround needed.

## `prosodyctl` basics

Run any `prosodyctl` subcommand by prefixing it with `docker exec prosody`:

```bash
docker exec prosody prosodyctl status
docker exec prosody prosodyctl reload
docker exec prosody prosodyctl check
docker exec prosody prosodyctl about
docker exec prosody prosodyctl version -v
```

| Command | Purpose |
|---|---|
| `status` | Reports whether Prosody is running |
| `reload` | Reload config and re-open log files (no restart, no dropped connections) |
| `check` | Run built-in config/DNS/certs sanity checks |
| `about` | Show version, install paths, loaded config file |
| `shell` | Interactive admin console (see below) |

## Listing enabled modules

```bash
docker exec prosody prosodyctl modules <your-xmpp-domain>
```

This resolves the final merged list per virtual host: the baked-in
`PROSODY_ENABLE_MODULES` env var (set in `docker-compose.yaml`) plus anything
added via `modules_enabled` in `xmpp-proxy-stack/generated/proxy.cfg.lua`
(rendered from `xmpp-proxy-stack/templates/prosody-proxy.cfg.lua.template` —
edit the template, not the generated file).

## User management

```bash
docker exec -it prosody prosodyctl adduser user@example.com
docker exec -it prosody prosodyctl passwd user@example.com
docker exec prosody prosodyctl deluser user@example.com
```

Use `-it` for `adduser`/`passwd` since they prompt interactively for a
password.

## Interactive admin shell

`admin_shell` is enabled in the module list, so you can attach to a live
console for ad-hoc inspection (module info, user sessions, `os.time()`-style
Lua expressions):

```bash
docker exec -it prosody prosodyctl shell
```

Inside the shell:

```
prosody> module:list("your-xmpp-domain")
prosody> c2s:show()
prosody> server.stats()
```

Exit with `Ctrl+D` or `quit`.

## Restarting vs reloading

Prefer `prosodyctl reload` over a full restart — it re-reads config and
re-opens logs without dropping active client/server connections. Only restart
the container when a change can't take effect via reload (e.g. after editing
`PROSODY_ENABLE_MODULES` in `.env`, which is baked into the container's
environment at creation time, not re-read on `reload`):

```bash
docker compose restart prosody
```

## Logs

Prosody writes to two places: `docker logs prosody` (its `*console` sink,
always on), and a file at `/var/log/prosody/prosody.log` — persisted on the
host at `/srv/xmpp/logs/prosody/prosody.log`, and readable by `fail2ban-rs`
(from the `xmpp-proxy-stack` container) at `/logs/prosody/prosody.log`. Both
sinks are configured together in `log = {...}` in
`prosody-proxy.cfg.lua.template` — see [fail2ban-rs.md](./fail2ban-rs.md) for
why the file sink exists (the `xmpp-auth`/`xmpp-s2s-abuse` jails need it).

```bash
docker logs -f prosody
docker exec prosody tail -f /var/log/prosody/prosody.log
```

## Certificates

Prosody reads TLS certs from `/certs` (mounted read-only from
`/srv/xmpp/certs`, shared with `xmpp-proxy-stack`'s acme.sh). Prosody itself
doesn't terminate public TLS in this stack (xmpp-proxy does that), but
`prosodyctl cert` subcommands are still available for inspection:

```bash
docker exec prosody prosodyctl cert --help
```

## Getting a raw shell

Since this image isn't distroless, a plain shell works if `prosodyctl` isn't
enough:

```bash
docker exec -it prosody bash
```
