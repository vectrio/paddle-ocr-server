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
  - waits by default when queue is full (`QUEUE_WAIT_TIMEOUT_SECONDS=0`)
  - returns `429` only when `QUEUE_WAIT_TIMEOUT_SECONDS` is set to a positive value and that wait timeout is exceeded
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
- `QUEUE_WAIT_TIMEOUT_SECONDS` (default: `0`, where `0` means wait indefinitely)
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
- To avoid `429 Too Many Requests`, keep `QUEUE_WAIT_TIMEOUT_SECONDS=0`.
- Set `QUEUE_WAIT_TIMEOUT_SECONDS` to a positive value only if you prefer bounded wait and overload rejections.

## Quantize PPStructureV3 Sub-Modules

You can generate quantized inference models for PPStructureV3 sub-modules that have local `model_dir` paths.

Run:

```bash
chmod +x quantize.sh
./quantize.sh
```

Defaults:

- `CONFIG_PATH=./PP-StructureV3.yaml`
- `OUTPUT_ROOT=./quantized-models`
- `WEIGHT_BITS=8`
- `QUANT_OPS=conv2d,depthwise_conv2d,mul,matmul`

Optional examples:

```bash
export OUTPUT_ROOT=./quantized-models-int8
export WEIGHT_BITS=8
./quantize.sh
```

Quantize extra local model directories not listed in YAML:

```bash
export EXTRA_MODEL_DIRS=/path/modelA,/path/modelB
./quantize.sh
```

Result summary is written to:

- `quantized-models/quantization_summary.json` (or your custom `OUTPUT_ROOT`)

Notes:

- Modules with `model_dir: null` are skipped because they do not point to local inference model files.
- This script performs dynamic post-training quantization and outputs separate quantized model folders.
