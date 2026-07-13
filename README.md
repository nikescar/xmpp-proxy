# XMPP Docker Compose Deployment

Production XMPP server deployment with xmpp-proxy, Prosody, fail2ban-rs, and automated ACME certificates.

## Quick Start

See `docs/QUICKSTART.md` for detailed setup instructions.

```bash
cp .env.example .env
# Edit .env with your domain and email
docker compose up -d
```

## Components

- **xmpp-proxy-stack**: TLS termination, intrusion prevention, ACME
- **Prosody**: XMPP server (official image)

## Documentation

- [Quick Start Guide](docs/QUICKSTART.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Design Specification](docs/superpowers/specs/2026-07-14-xmpp-docker-compose-design.md)

## License

See LICENSE file.
