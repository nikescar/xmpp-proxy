# Managing xmpp-proxy control from outside Docker

`xmpp-proxy` has no admin API, control socket, or CLI subcommand for runtime
management — it's a single supervised process
(`xmpp-proxy-stack/horust-services/xmpp-proxy.toml`, restart strategy
`always`) controlled entirely through Unix signals and horust supervision.
Everything below runs via `docker exec` from the host against the distroless
`xmpp-proxy-stack` container.

## Checking version and enabled features

```bash
docker exec xmpp-proxy-stack /usr/local/bin/xmpp-proxy -v
```

Prints the version and the exact feature flags the running binary was
compiled with, e.g.:

```
xmpp-proxy 1.1.0-side (x86_64-unknown-linux-musl)
Features: c2s-incoming,c2s-outgoing,s2s-incoming,s2s-outgoing,tls,quic,websocket,tls-ca-roots-native,logging,systemd
```

Useful for confirming a deployed image actually has the feature you expect
(e.g. `websocket`, `quic`) before debugging further.

## Finding the process

```bash
docker exec xmpp-proxy-stack /bin/busybox ps aux
```

Look for the `/usr/local/bin/xmpp-proxy /etc/xmpp-proxy/xmpp-proxy.toml` line
and note its PID (PID 1 is always horust itself, never xmpp-proxy).

## Reloading TLS cert/key only (SIGHUP)

xmpp-proxy watches for `SIGHUP` and reloads **only the TLS certificate and
key** from the config file's `tls_cert`/`tls_key` paths — it does not
re-parse listen addresses, backends, or any other config field
(`src/main.rs`, `spawn_refresh_task`). This is what you want right after
acme.sh renews a certificate, without dropping active connections:

```bash
docker exec xmpp-proxy-stack /bin/busybox kill -HUP <pid>
# or, without looking up the PID:
docker exec xmpp-proxy-stack /bin/busybox killall -HUP xmpp-proxy
```

Check `/logs/xmpp-proxy-stdout.log` for `got SIGHUP` / `reloaded cert/key
successfully!`, or `invalid config/cert/key on SIGHUP` if the cert/key failed
to parse (in which case the old cert/key stays in effect).

This signal handler is only compiled in when built with the `incoming` or
`s2s-outgoing` feature family — true for the stack's default build, but
verify with `xmpp-proxy -v` above if you're running a custom minimal build.

## Applying a full config change (restart required)

Anything beyond cert/key (listen addresses, `c2s_target`/`s2s_target`,
`max_stanza_size_bytes`, feature-affecting settings) requires a process
restart, since `SIGHUP` does not re-read the rest of the config.

1. Edit `/etc/xmpp-proxy/xmpp-proxy.toml` inside the container (regenerated
   from `xmpp-proxy-stack/templates/xmpp-proxy.toml.template` by
   `docker-entrypoint.sh` on every container start — edit the template on the
   host, not the in-container file, if the change should survive a restart)
2. Restart the process. horust's restart strategy for xmpp-proxy is `always`,
   so killing it is enough — horust relaunches it picking up the new config:

```bash
docker exec xmpp-proxy-stack /bin/busybox killall -TERM xmpp-proxy
```

horust sends `TERM` and waits up to 15s before force-killing
(`[termination]` in `horust-services/xmpp-proxy.toml`), then restarts with a
5s backoff.

Alternatively, restart the whole container (heavier — also restarts nginx,
fail2ban-rs, and the acme cron, since they share one supervised container):

```bash
docker compose restart xmpp-proxy-stack
```

## No horust remote-control CLI is bundled

horust does expose a Unix domain socket for its companion `horustctl` tool
(`/var/run/horust/horust-1.sock` — visible via
`docker exec xmpp-proxy-stack /bin/busybox ls /var/run/horust`), which
upstream horust uses for querying/restarting individual supervised services
without sending signals by hand. **`horustctl` is not currently bundled in
this image** (only the `horust` supervisor binary itself is downloaded in the
`Dockerfile`), so today the signal-based approach above is the only way to
control xmpp-proxy from outside the container. Adding `horustctl` to the
Dockerfile would be a natural follow-up if finer-grained control (e.g.
`horustctl restart xmpp-proxy` without knowing the PID) becomes worth the
extra binary.

## Logs

```bash
docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log
docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stderr.log
```

Also on the host at `/srv/xmpp/logs/xmpp-proxy-*.log`. Enable more verbose
logging by adding `log_level = "debug"` to `xmpp-proxy.toml.template` and
restarting (see above — this is a full config change, not SIGHUP-reloadable).
