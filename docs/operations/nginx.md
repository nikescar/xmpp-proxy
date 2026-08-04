# Managing nginx from outside Docker

nginx runs inside the distroless `xmpp-proxy-stack` container, supervised by
horust (`xmpp-proxy-stack/horust-services/nginx.toml`, restart strategy
`always`). There is no shell in the image other than `busybox sh`, but the
`nginx` binary itself can be invoked directly with `docker exec` — no shell
required for that part.

## Config test / reload / validate

```bash
# Test syntax without applying
docker exec xmpp-proxy-stack /usr/sbin/nginx -t

# Reload config (graceful — workers finish in-flight requests, no dropped connections)
docker exec xmpp-proxy-stack /usr/sbin/nginx -s reload

# Show version / build info
docker exec xmpp-proxy-stack /usr/sbin/nginx -v
docker exec xmpp-proxy-stack /usr/sbin/nginx -V
```

`nginx-proxy-ctl` (see [nginx-proxy-ctl.md](./nginx-proxy-ctl.md)) wraps the
test+reload sequence automatically whenever you add/remove a proxy location,
so you rarely need to call `nginx -s reload` by hand — it's mainly useful
after manually editing a file under `/etc/nginx/conf.d/`.

## Stopping / restarting

Because horust's restart strategy for nginx is `always`, sending `stop` will
just cause horust to immediately relaunch it — useful for a clean process
restart, but not for taking nginx down permanently without also stopping
horust:

```bash
docker exec xmpp-proxy-stack /usr/sbin/nginx -s stop
# horust notices the exit and restarts nginx within ~5s (see horust-services/nginx.toml backoff)
```

To fully restart the whole stack (nginx + xmpp-proxy + fail2ban-rs + acme
cron, since they're one supervised container):

```bash
docker compose restart xmpp-proxy-stack
```

There's no way to restart *only* nginx at the container level without also
restarting its sibling services — they all live in the same container. Use
`nginx -s reload`/`-s stop` above for nginx-only changes.

## Inspecting config

```bash
# Base config (rendered from templates/nginx.conf.template at build time)
docker exec xmpp-proxy-stack /bin/busybox cat /etc/nginx/nginx.conf

# Dynamic reverse-proxy locations added via nginx-proxy-ctl or ENABLE_WEB_ADMIN
docker exec xmpp-proxy-stack /bin/busybox ls /etc/nginx/conf.d/
docker exec xmpp-proxy-stack /bin/busybox cat /etc/nginx/conf.d/proxy-<hash>.conf
```

**Important:** `/etc/nginx/conf.d/` is not a mounted volume. Anything added
there — whether by `nginx-proxy-ctl add` or by the `ENABLE_WEB_ADMIN=true`
bootstrap logic in `docker-entrypoint.sh` — is regenerated/lost on container
recreation (`docker compose up --force-recreate`, image upgrade, etc.), though
it survives a plain `docker compose restart`. `ENABLE_WEB_ADMIN` locations are
re-added automatically on every entrypoint run; anything added manually via
`nginx-proxy-ctl add` is not persisted and must be re-added after recreation.

## Logs

```bash
docker exec xmpp-proxy-stack /bin/busybox cat /logs/nginx-stdout.log
docker exec xmpp-proxy-stack /bin/busybox cat /logs/nginx-stderr.log
```

These are also on the host at `/srv/xmpp/logs/nginx-*.log` (mounted from
`/srv/xmpp/logs` → `/logs`).

## Health check

horust polls `http://localhost:80/health` for liveness (see
`horust-services/nginx.toml`). You can hit the same endpoint from the host
since `xmpp-proxy-stack` uses host networking:

```bash
curl -I http://localhost/health
```

## Process / shell access

```bash
docker exec xmpp-proxy-stack /bin/busybox ps aux | grep nginx
docker exec -it xmpp-proxy-stack /bin/busybox sh
```
