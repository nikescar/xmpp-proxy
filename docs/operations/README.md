# Operations: managing the stack from outside Docker

Guides for controlling each component of the running stack via `docker exec`
/ `docker compose` from the host, without a shell inside the distroless
`xmpp-proxy-stack` image (which only has `busybox`).

- [prosody.md](./prosody.md) — `prosodyctl` (status, reload, modules, users, admin shell)
- [nginx.md](./nginx.md) — nginx binary (config test/reload/stop, logs, health check)
- [nginx-proxy-ctl.md](./nginx-proxy-ctl.md) — dynamic reverse-proxy route management (`add`/`remove`/`list`/`validate`)
- [xmpp-proxy-control.md](./xmpp-proxy-control.md) — signal-based control (cert/key reload via SIGHUP, full restart via horust)
- [fail2ban-rs.md](./fail2ban-rs.md) — `fail2ban-rs` CLI over its control socket (status, ban/unban, reload, filter testing)

## Quick reference

| Component | Container | Has shell? | Primary control |
|---|---|---|---|
| Prosody | `prosody` | Yes (`bash`) | `docker exec prosody prosodyctl <cmd>` |
| nginx | `xmpp-proxy-stack` | No (busybox only) | `docker exec xmpp-proxy-stack /usr/sbin/nginx -s <signal>` |
| Dynamic nginx routes | `xmpp-proxy-stack` | No (busybox only) | `docker exec xmpp-proxy-stack nginx-proxy-ctl <cmd>` |
| xmpp-proxy | `xmpp-proxy-stack` | No (busybox only) | `docker exec xmpp-proxy-stack /bin/busybox kill -HUP\|-TERM <pid>` |
| fail2ban-rs | `xmpp-proxy-stack` | No (busybox only) | `docker exec xmpp-proxy-stack fail2ban-rs <cmd>` (own control socket) |

All four services inside `xmpp-proxy-stack` (nginx, xmpp-proxy, fail2ban-rs,
acme cron) are supervised by a single horust instance, so
`docker compose restart xmpp-proxy-stack` is the "restart everything" hammer
when a component-specific reload/signal isn't enough.
