# Paddle OCR Setup

This repository uses a single setup script: `start.sh`.

## What start.sh does

- Installs or verifies system dependencies (`python3`, `pip`, `venv`)
- Creates and activates `venv`
- Installs Paddle + PaddleOCR + PaddleX dependencies
- Downloads your private fine-tuned model from Hugging Face
- Exports inference model artifacts into `ft-paddle-ocr/`
- Starts parallel serving with:
  - multiple PaddleX worker processes (internal)
  - one FastAPI gateway (public endpoint)

The script is safe to run multiple times.

## Serving Architecture

- Public API endpoint: FastAPI gateway on `GATEWAY_PORT` (default `8100`)
- Internal workers: PaddleX instances on `PADDLEX_WORKER_PORTS` (default `8101,8102`)
- Gateway behavior:
  - forwards requests to workers using round-robin selection
  - enforces bounded in-flight request limits (`MAX_IN_FLIGHT`)
  - returns `429` when the queue wait timeout is exceeded
  - returns `503` when no worker can be reached

## Prerequisites

- Linux or WSL environment with `apt`
- `sudo` access

## Run

```bash
chmod +x start.sh
./start.sh
```

## Important Environment Variables

- `GATEWAY_HOST` (default: `0.0.0.0`)
- `GATEWAY_PORT` (default: `8100`)
- `PADDLEX_WORKER_HOST` (default: `127.0.0.1`)
- `PADDLEX_WORKER_PORTS` (default: `8101,8102`)
- `MAX_IN_FLIGHT` (default: `64`)
- `QUEUE_WAIT_TIMEOUT_SECONDS` (default: `2.5`)
- `REQUEST_TIMEOUT_SECONDS` (default: `180`)
- `CLOUDFLARE_ENABLE_TUNNEL` (default: `false`)
- `CLOUDFLARE_SESSION_NAME` (default: `cloudflare-tunnel`)
- `CLOUDFLARE_TUNNEL_URL_TARGET` (default: `http://localhost:${GATEWAY_PORT}`)
- `CLOUDFLARED_BINARY_NAME` (default: `cloudflared`)
- `CLOUDFLARED_DOWNLOAD_URL` (default: latest Linux amd64 release URL)
- `CLOUDFLARE_LOG_FILE` (default: `cloudflared.log`)

Example for higher concurrency:

```bash
export PADDLEX_WORKER_PORTS=8101,8102,8103
export MAX_IN_FLIGHT=96
./start.sh
```

Example with auto Cloudflare tunnel:

```bash
export CLOUDFLARE_ENABLE_TUNNEL=true
./start.sh
```

## Process Management

- If `tmux` is available:
  - workers run in sessions named `paddlex-worker-<port>`
  - gateway runs in session `paddlex-gateway`
  - optional cloudflare tunnel runs in session `cloudflare-tunnel`
- Without `tmux`, `nohup` is used and logs are written to:
  - `paddlex-worker-<port>.log`
  - `paddlex-gateway.log`

## Health Check

Gateway health endpoint:

```bash
curl http://127.0.0.1:8100/health
```

If cloudflare tunnel is enabled, get public URL:

```bash
tmux capture-pane -pt cloudflare-tunnel | grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' | tail -n 1
```

## Notes

- Keep your clients pointed to the gateway port (`8100` by default).
- Scale worker count conservatively on a single GPU to avoid OOM.
