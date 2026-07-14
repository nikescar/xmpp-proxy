-- Prosody PROXY protocol configuration
-- This file is mounted at /etc/prosody/conf.d/proxy.cfg.lua
-- IMPORTANT: Settings in this file are loaded AFTER VirtualHost, so some settings
-- need to be applied at the global level via the main config

---------- GLOBAL SETTINGS (apply before VirtualHost) ----------

-- Add pidfile for health checks
pidfile = "/var/run/prosody/prosody.pid"

-- PROXY protocol support via mod_net_proxy from prosody-modules
-- Community modules mounted at: /usr/lib/prosody/community
plugin_paths = { "/usr/lib/prosody/community" }

---------- PROXY PROTOCOL CONFIGURATION (MUST BE GLOBAL) ----------

-- Trust connections from xmpp-proxy-stack (Docker bridge network)
-- The xmpp-proxy-stack container connects via the bridge network gateway
-- This MUST be set before proxy_port_mappings
proxy_trusted_proxies = {
    "127.0.0.1",      -- localhost
    "::1",            -- localhost IPv6
    "172.30.0.0/16"   -- Docker bridge network (xmpp-internal)
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

---------- MODULE CONFIGURATION ----------

-- Enable additional modules (these will be added to the global modules_enabled)
modules_enabled = {
    -- Core modules (must be explicitly enabled)
    "roster";        -- User contact list
    "saslauth";      -- SASL authentication
    "tls";           -- TLS support
    "disco";         -- Service discovery
    "dialback";      -- S2S authentication

    -- OMEMO/Encryption support (requires PEP)
    "pep";           -- Personal Eventing Protocol (required for OMEMO)
    "blocklist";     -- Block list support
    "carbons";       -- Message carbons
    "smacks";        -- Stream management
    "csi_simple";    -- Client state indication
    "mam";           -- Message Archive Management

    -- Proxy-specific modules
    "net_proxy";     -- Parse PROXY protocol v1/v2 headers to extract real client IP

    -- HTTP/Admin modules
    "http";          -- HTTP server for web admin
    "admin_web2";    -- Web admin interface (Prosody 13.0 compatible)
    "admin_shell";   -- Enable prosodyctl shell access
    "admin_adhoc";   -- Admin ad-hoc commands
    "bosh";          -- BOSH (Bidirectional-streams Over Synchronous HTTP)

    -- User management
    "register";      -- User registration
    "ping";          -- XMPP ping
    "time";          -- Time queries
    "version";       -- Version queries
    "uptime";        -- Uptime queries
    "vcard4";        -- vCard support
    "vcard_legacy";  -- Legacy vCard
    "bookmarks";     -- Bookmarks (for chat rooms)
    "private";       -- Private XML storage
}

---------- HTTP/BOSH CONFIGURATION ----------

-- HTTP configuration for web admin
http_ports = { 5280 }
http_interfaces = { "*", "::" }

-- BOSH configuration
consider_bosh_secure = true  -- Trust BOSH connections as secure (TLS handled by xmpp-proxy)
bosh_max_inactivity = 60     -- Keep BOSH sessions alive for 60 seconds of inactivity
bosh_max_wait = 120          -- Maximum time (in seconds) a client can wait for a response

-- Force SASL mechanisms on insecure connections (BOSH over HTTP)
sasl_mech_override = {
    ["PLAIN"] = function() return true; end;
}

-- HTTP CORS headers for web admin
http_default_host = "chat.dure.one"
http_external_url = "http://chat.dure.one:5280/"

---------- PEP/OMEMO CONFIGURATION ----------

-- PEP (Personal Eventing Protocol) configuration for OMEMO support
pep_max_items = 1000  -- Maximum items per PEP node (OMEMO needs this for device lists)

---------- ADMIN CONFIGURATION ----------

-- Admin shell socket path (for prosodyctl shell command)
admin_socket = "/var/run/prosody/prosody.sock"

-- Force SASL mechanisms to be offered (for BOSH over HTTP from localhost)
c2s_direct_tls_ports = {}
authentication = "internal_hashed"
