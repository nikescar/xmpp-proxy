# Managing nginx-proxy-ctl from outside Docker

`nginx-proxy-ctl` (`xmpp-proxy-stack/nginx-proxy-ctl`) is a `busybox sh` script
baked into the `xmpp-proxy-stack` image at `/usr/local/bin/nginx-proxy-ctl`.
It lets you add/remove dynamic nginx reverse-proxy locations at runtime
without rebuilding or restarting the container. Run it via `docker exec` from
the host — no separate shell needed, it's directly executable.

## Commands

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl add <location> <upstream> [--websocket] [--timeout <seconds>]
docker exec xmpp-proxy-stack nginx-proxy-ctl remove <location>
docker exec xmpp-proxy-stack nginx-proxy-ctl list
docker exec xmpp-proxy-stack nginx-proxy-ctl validate
docker exec xmpp-proxy-stack nginx-proxy-ctl help
```

### `add`

```bash
# Plain HTTP reverse proxy
docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://localhost:8000/

# WebSocket-upgrading proxy (adds Upgrade/Connection headers)
docker exec xmpp-proxy-stack nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket

# Custom proxy_read/send timeout (default 60s)
docker exec xmpp-proxy-stack nginx-proxy-ctl add /slow/ http://localhost:9000/ --timeout 300
```

Validation rules (enforced before writing any config):
- `<location>` must start with `/`
- `<upstream>` must start with `http://` or `https://`
- Duplicate locations are rejected — `remove` the existing one first if you
  need to change its upstream

Internally: the location path is hashed (md5) to name
`/etc/nginx/conf.d/proxy-<hash>.conf`, the config is rendered from
`templates/location-proxy.conf.template`, validated with `nginx -t`, then
applied with `nginx -s reload`. If `nginx -t` fails, nothing is written and
the command exits non-zero.

### `remove`

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /api/
```

Deletes the matching `proxy-<hash>.conf` (same hash-of-path lookup as `add`)
and reloads nginx.

### `list`

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl list
```

Prints `<location> -> <upstream>` for every file under
`/etc/nginx/conf.d/proxy-*.conf`, or `No proxies configured` if none exist.

### `validate`

```bash
docker exec xmpp-proxy-stack nginx-proxy-ctl validate
```

Runs `nginx -t` and reports success/failure without touching any files.

## Persistence caveat

`/etc/nginx/conf.d/` is **not** a mounted volume. Proxies added with
`nginx-proxy-ctl add` are lost if the container is recreated (image upgrade,
`docker compose up --force-recreate`) — they survive a plain
`docker compose restart` / `docker restart`, but not recreation. To make a
proxy route durable across recreation, add it to
`docker-entrypoint.sh`'s `ENABLE_WEB_ADMIN` block (or a similar
always-re-applied block) instead of relying on a one-time manual `add`.

The bundled `ENABLE_WEB_ADMIN=true` reverse proxies (`/prosody/`,
`/http-bind/`, `/xmpp-websocket`) use the exact same hashing scheme, so
they'll show up in `nginx-proxy-ctl list` and can be `remove`d or overridden
with this same tool — just remember the entrypoint will re-add them on the
next container start as long as `ENABLE_WEB_ADMIN=true`.

## Use cases

- Expose Prosody's HTTP API or admin console externally without editing
  templates
- Add a WebSocket endpoint for a custom service sharing the same public
  ports/TLS termination
- Temporary debugging endpoints (remove when done — see persistence caveat)

## Troubleshooting

- **"Proxy for location X already exists"** — run `remove` first, or check
  `list` for the current upstream.
- **"nginx configuration test failed"** — the generated config didn't pass
  `nginx -t`; check `docker exec xmpp-proxy-stack /usr/sbin/nginx -t` for the
  actual error (see [nginx.md](./nginx.md)).
- Changes not surviving a redeploy — see the persistence caveat above.
