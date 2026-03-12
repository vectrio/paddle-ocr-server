# Production Deployment (Docker Compose + Caddy)

This stack keeps your PaddleX API on port `8100` private and exposes only HTTPS to the internet.

## Architecture

- `paddlex --serve` runs on the host at `127.0.0.1:8100` or `0.0.0.0:8100`
- Caddy runs in Docker and listens on ports `80` and `443`
- Caddy terminates TLS and reverse proxies traffic to `host.docker.internal:8100`

## Why this pattern

- Only `80/443` are public, reducing attack surface.
- TLS certs are automatic (Let's Encrypt) and auto-renewed.
- Reverse proxy centralizes security headers and request limits.
- Your app process remains independent from edge networking.

## 1. Prerequisites on server

- Docker and Docker Compose plugin installed
- Your API already running on port `8100`
- A domain name mapped to server public IP

## 2. Configure env file

Copy `.env.example` to `.env` and set real values:

```bash
cp .env.example .env
```

Required values:

- `DOMAIN`: your final API domain (for example `ocr-api.yourdomain.com`)
- `ACME_EMAIL`: email for cert registration/recovery notices

## 3. DNS setup

Create DNS records for your chosen domain:

- `A` record -> server IPv4
- `AAAA` record -> server IPv6 (if available)

Wait for propagation before first Caddy boot.

## 4. Firewall (UFW)

Keep only SSH + web ports open:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

If SSH should be IP-restricted, replace `allow OpenSSH` with a specific source CIDR.

## 5. Start Caddy

```bash
docker compose up -d
```

Check logs:

```bash
docker compose logs -f caddy
```

## 6. Verify

- `https://<DOMAIN>` should present a valid certificate
- API requests should be served through Caddy

## Operations

Restart:

```bash
docker compose restart caddy
```

Stop:

```bash
docker compose down
```

Update Caddy image:

```bash
docker compose pull caddy
docker compose up -d
```

## Notes

- Do **not** expose port `8100` publicly in cloud firewall/security groups.
- Keep SSH open, but prefer source-IP restriction for production.
- If you later containerize the API itself, Caddy can proxy directly to that service name instead of host gateway.
