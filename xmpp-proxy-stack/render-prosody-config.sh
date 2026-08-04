#!/bin/sh
# Renders templates/prosody-proxy.cfg.lua.template -> generated/proxy.cfg.lua,
# substituting ${XMPP_DOMAIN} from the environment.
#
# This is a standalone script, not inlined into docker-compose.yaml's
# `command:`, because docker compose interpolates ${VAR} syntax found
# anywhere in a compose file's `command:` string - including inside a sed
# pattern meant to match that literal text in the template - regardless of
# backslash-escaping. Keeping the substitution logic in a real file sidesteps
# that entirely, since compose never parses file contents it just mounts.
set -eu

: "${XMPP_DOMAIN:?XMPP_DOMAIN must be set in .env}"

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
template="$repo_root/xmpp-proxy-stack/templates/prosody-proxy.cfg.lua.template"
out_dir="$repo_root/xmpp-proxy-stack/generated"
out_file="$out_dir/proxy.cfg.lua"

mkdir -p "$out_dir"
sed "s|\${XMPP_DOMAIN}|$XMPP_DOMAIN|g" "$template" > "$out_file"

echo "✓ Rendered proxy.cfg.lua for domain: $XMPP_DOMAIN"
