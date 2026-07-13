-- Prosody PROXY protocol configuration
-- This file is mounted at /etc/prosody/conf.d/proxy.cfg.lua

-- Enable PROXY protocol support
modules_enabled = {
    "net_proxy";  -- mod_net_proxy for PROXY protocol
}

proxy_port_mappings = {
    [5222] = "c2s",  -- Client-to-server connections
    [5269] = "s2s"   -- Server-to-server connections
}

-- Trust connections from xmpp-proxy as already secure
proxy_secure = true

-- Don't require encryption (xmpp-proxy already handled TLS)
c2s_require_encryption = false
s2s_require_encryption = false
s2s_secure_auth = false

-- Allow plaintext auth since connection is already secure
allow_unencrypted_plain_auth = true
