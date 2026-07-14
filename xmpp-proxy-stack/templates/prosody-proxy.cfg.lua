-- Prosody PROXY protocol configuration
-- This file is mounted at /etc/prosody/conf.d/proxy.cfg.lua

-- Add pidfile for health checks
pidfile = "/var/run/prosody/prosody.pid"

-- PROXY protocol support via mod_net_proxy from prosody-modules
-- Community modules mounted at: /usr/lib/prosody/community
plugin_paths = { "/usr/lib/prosody/community" }

modules_enabled = {
    "net_proxy";     -- Parse PROXY protocol v1/v2 headers to extract real client IP
    "admin_shell";   -- Enable prosodyctl shell access
    "http";          -- HTTP server for web admin
    "admin_web2";    -- Web admin interface (Prosody 13.0 compatible)
}

-- Configure which ports expect PROXY protocol headers
proxy_port_mappings = {
    [5222] = "c2s",  -- Client-to-server connections
    [5269] = "s2s"   -- Server-to-server connections
}

-- Disable regular c2s/s2s ports (mod_net_proxy will handle them)
c2s_ports = {}
s2s_ports = {}

-- Don't require encryption (xmpp-proxy already handled TLS termination)
c2s_require_encryption = false
s2s_require_encryption = false
s2s_secure_auth = false

-- Allow plaintext auth since connection is already secure (TLS at xmpp-proxy)
allow_unencrypted_plain_auth = true

-- Real client IPs are now preserved via mod_net_proxy
-- Prosody logs will show actual client IPs, not 127.0.0.1
-- fail2ban-rs can now correctly identify and ban attackers

-- HTTP configuration for web admin
http_ports = { 5280 }
http_interfaces = { "*", "::" }

-- Admin shell socket path (for prosodyctl shell command)
admin_socket = "/var/run/prosody/prosody.sock"
