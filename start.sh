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

echo "Upgrading pip inside virtual environment..."
./venv/bin/python -m pip install --upgrade pip

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

echo "Setup complete."
