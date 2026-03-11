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

echo "Installing Paddle dependencies in virtual environment..."

PADDLE_GPU_VERSION_INSTALLED="$(${PYTHON_CMD} -m pip show paddlepaddle-gpu 2>/dev/null | awk '/^Version:/{print $2}' || true)"
if [ "${PADDLE_GPU_VERSION_INSTALLED}" = "3.3.0" ]; then
	echo "paddlepaddle-gpu==3.3.0 already installed. Skipping."
else
	echo "Installing paddlepaddle-gpu==3.3.0"
	${PYTHON_CMD} -m pip install paddlepaddle-gpu==3.3.0 -i https://www.paddlepaddle.org.cn/packages/stable/cu130/
fi

if ${PYTHON_CMD} -m pip show paddleocr >/dev/null 2>&1; then
	echo "paddleocr already installed. Skipping paddleocr[all] install."
else
	echo "Installing paddleocr[all]"
	${PYTHON_CMD} -m pip install "paddleocr[all]"
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
	${PYTHON_CMD} -m pip install -r PaddleOCR/requirements.txt
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
	python -m pip install --upgrade "huggingface_hub[cli]"

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

echo "Setup complete."
