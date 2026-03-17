#!/usr/bin/env bash

set -euo pipefail

echo "Updating apt package index..."
sudo apt-get update

echo "Upgrading installed apt packages..."
sudo apt-get upgrade -y

missing_packages=()

if ! command -v python3 >/dev/null 2>&1; then
	missing_packages+=(python3)
fi

if ! command -v pip3 >/dev/null 2>&1; then
	missing_packages+=(python3-pip)
fi

if ! python3 -m venv --help >/dev/null 2>&1; then
	missing_packages+=(python3-venv)
fi

if [ ${#missing_packages[@]} -gt 0 ]; then
	echo "Installing missing packages: ${missing_packages[*]}"
	sudo apt-get install -y "${missing_packages[@]}"
else
	echo "Python, pip, and venv are already installed. Skipping install."
fi

if [ -d "venv" ]; then
	echo "Virtual environment 'venv' already exists. Skipping creation."
else
	echo "Creating virtual environment: venv"
	if ! python3 -m venv venv; then
		echo "Initial venv creation failed. Trying version-specific venv package..."
		py_minor="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
		venv_pkg="python${py_minor}-venv"
		echo "Installing ${venv_pkg}"
		sudo apt-get install -y "${venv_pkg}"
		echo "Retrying virtual environment creation..."
		python3 -m venv venv
	fi
fi

echo "Creating project directories..."
if [ -d "model" ]; then
	echo "Directory 'model' already exists."
else
	mkdir -p model
	echo "Created directory: model"
fi

if [ -d "ft-paddle-ocr" ]; then
	echo "Directory 'ft-paddle-ocr' already exists."
else
	mkdir -p ft-paddle-ocr
	echo "Created directory: ft-paddle-ocr"
fi

echo "Preparing Hugging Face private model download..."
if [ -f "venv/bin/activate" ]; then
	echo "Activating virtual environment..."
	# shellcheck disable=SC1091
	source venv/bin/activate
else
	echo "venv activation script not found at venv/bin/activate"
	exit 1
fi

if command -v python >/dev/null 2>&1; then
	PYTHON_CMD="python"
elif command -v python3 >/dev/null 2>&1; then
	PYTHON_CMD="python3"
else
	echo "No python executable found in active virtual environment."
	exit 1
fi

pip_install_with_retry() {
	local max_attempts=3
	local attempt=1
	local pip_timeout_seconds="${PIP_TIMEOUT_SECONDS:-900}"
	local pip_retries="${PIP_RETRIES:-15}"
	local retry_sleep_seconds="${PIP_RETRY_SLEEP_SECONDS:-20}"

	while [ ${attempt} -le ${max_attempts} ]; do
		echo "pip install attempt ${attempt}/${max_attempts} (timeout=${pip_timeout_seconds}s, retries=${pip_retries}): $*"
		if ${PYTHON_CMD} -m pip --default-timeout "${pip_timeout_seconds}" --retries "${pip_retries}" install "$@"; then
			return 0
		fi

		if [ ${attempt} -lt ${max_attempts} ]; then
			echo "pip install failed. Retrying in ${retry_sleep_seconds} seconds..."
			sleep "${retry_sleep_seconds}"
		fi

		attempt=$((attempt + 1))
	done

	echo "pip install failed after ${max_attempts} attempts."
	return 1
}

echo "Installing Paddle dependencies in virtual environment..."

PADDLE_GPU_VERSION_INSTALLED="$(${PYTHON_CMD} -m pip show paddlepaddle-gpu 2>/dev/null | awk '/^Version:/{print $2}' || true)"
if [ "${PADDLE_GPU_VERSION_INSTALLED}" = "3.3.0" ]; then
	echo "paddlepaddle-gpu==3.3.0 already installed. Skipping."
else
	echo "Installing paddlepaddle-gpu==3.3.0"
	pip_install_with_retry paddlepaddle-gpu==3.3.0 -i https://www.paddlepaddle.org.cn/packages/stable/cu126/
fi

if ${PYTHON_CMD} -m pip show paddleocr >/dev/null 2>&1; then
	echo "paddleocr already installed. Skipping paddleocr[all] install."
else
	echo "Installing paddleocr[all]"
	pip_install_with_retry "paddleocr[all]"
fi

if ${PYTHON_CMD} -m pip show fastapi >/dev/null 2>&1 && ${PYTHON_CMD} -m pip show uvicorn >/dev/null 2>&1 && ${PYTHON_CMD} -m pip show httpx >/dev/null 2>&1; then
	echo "fastapi, uvicorn, and httpx already installed. Skipping."
else
	echo "Installing FastAPI gateway dependencies (fastapi, uvicorn, httpx)..."
	pip_install_with_retry fastapi uvicorn httpx
fi

PADDLEX_SERVING_MARKER=".paddlex_serving_installed"
if [ -f "${PADDLEX_SERVING_MARKER}" ]; then
	echo "paddlex serving already installed earlier. Skipping."
else
	if ! command -v paddlex >/dev/null 2>&1; then
		echo "paddlex command not found. Installing paddlex..."
		pip_install_with_retry paddlex
	fi

	echo "Installing paddlex serving components..."
	paddlex --install serving
	touch "${PADDLEX_SERVING_MARKER}"
fi

if [ -d "PaddleOCR" ]; then
	echo "PaddleOCR repository already exists. Skipping clone."
else
	echo "Cloning PaddleOCR repository..."
	git clone https://github.com/PaddlePaddle/PaddleOCR.git
fi

REQ_MARKER="PaddleOCR/.requirements_installed"
if [ -f "${REQ_MARKER}" ]; then
	echo "PaddleOCR requirements already installed earlier. Skipping."
else
	echo "Installing PaddleOCR requirements from PaddleOCR/requirements.txt"
	pip_install_with_retry -r PaddleOCR/requirements.txt
	touch "${REQ_MARKER}"
fi

if [ -f ".env" ]; then
	echo "Loading .env file..."
	set -a
	# shellcheck disable=SC1091
	source .env
	set +a
else
	echo ".env file not found. It will be created if token is provided."
fi

if ! command -v hf >/dev/null 2>&1; then
	echo "hf CLI is not installed. Installing huggingface_hub CLI..."
	pip_install_with_retry --upgrade "huggingface_hub[cli]"

	if ! command -v hf >/dev/null 2>&1; then
		echo "hf CLI install completed but command is still unavailable in PATH."
		echo "Try checking venv/bin is in PATH after activation."
		exit 1
	fi
fi

if [ -z "${HF_TOKEN:-}" ]; then
	echo "HF_TOKEN is not set in environment or .env."
	read -r -s -p "Enter Hugging Face token: " HF_TOKEN_INPUT
	echo

	if [ -z "${HF_TOKEN_INPUT}" ]; then
		echo "No token provided. Exiting."
		exit 1
	fi

	HF_TOKEN="${HF_TOKEN_INPUT}"
	export HF_TOKEN

	if [ -f ".env" ]; then
		if grep -q '^HF_TOKEN=' .env; then
			sed -i "s|^HF_TOKEN=.*|HF_TOKEN=${HF_TOKEN}|" .env
		else
			echo "HF_TOKEN=${HF_TOKEN}" >> .env
		fi
	else
		printf 'HF_TOKEN=%s\n' "${HF_TOKEN}" > .env
	fi

	echo "HF_TOKEN saved to .env"
fi

HF_MODEL_REPO="${HF_MODEL_REPO:-AnuragKatkar/FT-Paddle-OCR}"
echo "Using HF_MODEL_REPO=${HF_MODEL_REPO}"

echo "Logging in to Hugging Face CLI..."
hf auth login --token "${HF_TOKEN}" --add-to-git-credential

echo "Downloading model ${HF_MODEL_REPO} into model/..."
hf download "${HF_MODEL_REPO}" --repo-type model --local-dir model

echo "Exporting inference model to ft-paddle-ocr/..."
PADDLEOCR_DIR="$(pwd)/PaddleOCR"
PRETRAINED_MODEL_PATH="$(pwd)/model/best_model/model.pdparams"
EXPORT_OUTPUT_DIR="$(pwd)/ft-paddle-ocr"
EXPORT_CONFIG_PATH="configs/table/SLANet_plus.yml"

if [ ! -d "${PADDLEOCR_DIR}" ]; then
	echo "PaddleOCR directory not found at ${PADDLEOCR_DIR}"
	exit 1
fi

if [ ! -f "${PRETRAINED_MODEL_PATH}" ]; then
	echo "Pretrained model file not found at ${PRETRAINED_MODEL_PATH}"
	exit 1
fi

pushd "${PADDLEOCR_DIR}" >/dev/null

if [ ! -f "${EXPORT_CONFIG_PATH}" ]; then
	echo "Export config not found at ${PADDLEOCR_DIR}/${EXPORT_CONFIG_PATH}"
	popd >/dev/null
	exit 1
fi

${PYTHON_CMD} tools/export_model.py -c "${EXPORT_CONFIG_PATH}" -o \
	Global.pretrained_model="${PRETRAINED_MODEL_PATH}" \
	Global.save_inference_dir="${EXPORT_OUTPUT_DIR}"

popd >/dev/null

echo "Starting PaddleX workers and FastAPI gateway..."
SERVE_WORKDIR="$(pwd)"
PIPELINE_CONFIG_PATH="${SERVE_WORKDIR}/PP-StructureV3.yaml"
PADDLEX_WORKER_HOST="${PADDLEX_WORKER_HOST:-127.0.0.1}"
PADDLEX_WORKER_PORTS="${PADDLEX_WORKER_PORTS:-8101,8102}"
PADDLEX_WORKER_SESSION_PREFIX="${PADDLEX_WORKER_SESSION_PREFIX:-paddlex-worker}"

GATEWAY_HOST="${GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${GATEWAY_PORT:-8100}"
GATEWAY_SESSION_NAME="${GATEWAY_SESSION_NAME:-paddlex-gateway}"

MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-64}"
QUEUE_WAIT_TIMEOUT_SECONDS="${QUEUE_WAIT_TIMEOUT_SECONDS:-2.5}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-180}"

CLOUDFLARE_ENABLE_TUNNEL="${CLOUDFLARE_ENABLE_TUNNEL:-false}"
CLOUDFLARE_SESSION_NAME="${CLOUDFLARE_SESSION_NAME:-cloudflare-tunnel}"
CLOUDFLARE_TUNNEL_URL_TARGET="${CLOUDFLARE_TUNNEL_URL_TARGET:-http://localhost:${GATEWAY_PORT}}"
CLOUDFLARED_BINARY_NAME="${CLOUDFLARED_BINARY_NAME:-cloudflared}"
CLOUDFLARED_DOWNLOAD_URL="${CLOUDFLARED_DOWNLOAD_URL:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64}"
CLOUDFLARE_LOG_FILE="${CLOUDFLARE_LOG_FILE:-cloudflared.log}"

if [ ! -f "${PIPELINE_CONFIG_PATH}" ]; then
	echo "Pipeline config not found at ${PIPELINE_CONFIG_PATH}"
	exit 1
fi

IFS=',' read -r -a WORKER_PORT_ARRAY <<< "${PADDLEX_WORKER_PORTS}"
if [ ${#WORKER_PORT_ARRAY[@]} -eq 0 ]; then
	echo "No worker ports configured. Set PADDLEX_WORKER_PORTS, e.g. 8101,8102"
	exit 1
fi

UPSTREAM_URLS=""
for WORKER_PORT_RAW in "${WORKER_PORT_ARRAY[@]}"; do
	WORKER_PORT="$(echo "${WORKER_PORT_RAW}" | xargs)"
	if [ -z "${WORKER_PORT}" ]; then
		continue
	fi

	UPSTREAM_URL="http://${PADDLEX_WORKER_HOST}:${WORKER_PORT}"
	if [ -z "${UPSTREAM_URLS}" ]; then
		UPSTREAM_URLS="${UPSTREAM_URL}"
	else
		UPSTREAM_URLS="${UPSTREAM_URLS},${UPSTREAM_URL}"
	fi
done

if [ -z "${UPSTREAM_URLS}" ]; then
	echo "Failed to derive upstream URLs from PADDLEX_WORKER_PORTS=${PADDLEX_WORKER_PORTS}"
	exit 1
fi

if command -v tmux >/dev/null 2>&1; then
	for WORKER_PORT_RAW in "${WORKER_PORT_ARRAY[@]}"; do
		WORKER_PORT="$(echo "${WORKER_PORT_RAW}" | xargs)"
		if [ -z "${WORKER_PORT}" ]; then
			continue
		fi

		WORKER_SESSION_NAME="${PADDLEX_WORKER_SESSION_PREFIX}-${WORKER_PORT}"
		if tmux has-session -t "${WORKER_SESSION_NAME}" 2>/dev/null; then
			echo "tmux session '${WORKER_SESSION_NAME}' already exists. Skipping worker start."
		else
			tmux new-session -d -s "${WORKER_SESSION_NAME}" "cd \"${SERVE_WORKDIR}\" && source venv/bin/activate && paddlex --serve --pipeline \"${PIPELINE_CONFIG_PATH}\" --host \"${PADDLEX_WORKER_HOST}\" --port \"${WORKER_PORT}\""
			echo "Started PaddleX worker in tmux session '${WORKER_SESSION_NAME}' on ${PADDLEX_WORKER_HOST}:${WORKER_PORT}."
		fi
		echo "Attach using: tmux attach -t ${WORKER_SESSION_NAME}"
	done

	if tmux has-session -t "${GATEWAY_SESSION_NAME}" 2>/dev/null; then
		echo "tmux session '${GATEWAY_SESSION_NAME}' already exists. Skipping gateway start."
	else
		tmux new-session -d -s "${GATEWAY_SESSION_NAME}" "cd \"${SERVE_WORKDIR}\" && source venv/bin/activate && UPSTREAM_URLS=\"${UPSTREAM_URLS}\" MAX_IN_FLIGHT=\"${MAX_IN_FLIGHT}\" QUEUE_WAIT_TIMEOUT_SECONDS=\"${QUEUE_WAIT_TIMEOUT_SECONDS}\" REQUEST_TIMEOUT_SECONDS=\"${REQUEST_TIMEOUT_SECONDS}\" uvicorn app.main:app --host \"${GATEWAY_HOST}\" --port \"${GATEWAY_PORT}\""
		echo "Started FastAPI gateway in tmux session '${GATEWAY_SESSION_NAME}' on ${GATEWAY_HOST}:${GATEWAY_PORT}."
	fi
	echo "Attach using: tmux attach -t ${GATEWAY_SESSION_NAME}"
else
	echo "tmux not found. Starting workers and gateway with nohup fallback..."
	for WORKER_PORT_RAW in "${WORKER_PORT_ARRAY[@]}"; do
		WORKER_PORT="$(echo "${WORKER_PORT_RAW}" | xargs)"
		if [ -z "${WORKER_PORT}" ]; then
			continue
		fi
		nohup bash -lc "cd \"${SERVE_WORKDIR}\" && source venv/bin/activate && paddlex --serve --pipeline \"${PIPELINE_CONFIG_PATH}\" --host \"${PADDLEX_WORKER_HOST}\" --port \"${WORKER_PORT}\"" > "paddlex-worker-${WORKER_PORT}.log" 2>&1 &
		echo "Started PaddleX worker on ${PADDLEX_WORKER_HOST}:${WORKER_PORT}. Logs: ${SERVE_WORKDIR}/paddlex-worker-${WORKER_PORT}.log"
	done

	nohup bash -lc "cd \"${SERVE_WORKDIR}\" && source venv/bin/activate && UPSTREAM_URLS=\"${UPSTREAM_URLS}\" MAX_IN_FLIGHT=\"${MAX_IN_FLIGHT}\" QUEUE_WAIT_TIMEOUT_SECONDS=\"${QUEUE_WAIT_TIMEOUT_SECONDS}\" REQUEST_TIMEOUT_SECONDS=\"${REQUEST_TIMEOUT_SECONDS}\" uvicorn app.main:app --host \"${GATEWAY_HOST}\" --port \"${GATEWAY_PORT}\"" > paddlex-gateway.log 2>&1 &
	echo "Started FastAPI gateway on ${GATEWAY_HOST}:${GATEWAY_PORT}. Logs: ${SERVE_WORKDIR}/paddlex-gateway.log"
fi

if [ "${CLOUDFLARE_ENABLE_TUNNEL}" = "true" ]; then
	echo "Cloudflare tunnel is enabled. Preparing tunnel startup..."
	if ! command -v tmux >/dev/null 2>&1; then
		echo "tmux is required for cloudflare tunnel session. Skipping tunnel start."
	else
		if tmux has-session -t "${CLOUDFLARE_SESSION_NAME}" 2>/dev/null; then
			echo "tmux session '${CLOUDFLARE_SESSION_NAME}' already exists. Skipping cloudflare tunnel start."
		else
			tmux new-session -d -s "${CLOUDFLARE_SESSION_NAME}" "cd \"${SERVE_WORKDIR}\" && if [ ! -x \"${CLOUDFLARED_BINARY_NAME}\" ]; then echo 'Downloading cloudflared...'; wget -O \"${CLOUDFLARED_BINARY_NAME}\" \"${CLOUDFLARED_DOWNLOAD_URL}\" && chmod +x \"${CLOUDFLARED_BINARY_NAME}\"; fi && ./\"${CLOUDFLARED_BINARY_NAME}\" tunnel --url \"${CLOUDFLARE_TUNNEL_URL_TARGET}\" 2>&1 | tee \"${CLOUDFLARE_LOG_FILE}\""
			echo "Started cloudflare tunnel in tmux session '${CLOUDFLARE_SESSION_NAME}'."
		fi

		echo "Attach using: tmux attach -t ${CLOUDFLARE_SESSION_NAME}"
		echo "Tunnel URL target: ${CLOUDFLARE_TUNNEL_URL_TARGET}"
		echo "Try getting public URL with: tmux capture-pane -pt ${CLOUDFLARE_SESSION_NAME} | grep -Eo 'https://[-a-zA-Z0-9]+\\.trycloudflare\\.com' | tail -n 1"
	fi
else
	echo "Cloudflare tunnel is disabled. Set CLOUDFLARE_ENABLE_TUNNEL=true to start it automatically."
fi

echo "Setup complete."
