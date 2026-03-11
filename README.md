# Paddle OCR Setup

This repository uses a single setup script: `start.sh`.

## What start.sh does

- Updates apt package index
- Upgrades installed apt packages
- Installs missing system packages only when needed:
  - python3
  - python3-pip
  - python3-venv
- Creates Python virtual environment named `venv` if it does not already exist
- Upgrades pip inside the virtual environment
- Creates directories if missing:
  - model
  - ft-paddle-ocr

The script is safe to run multiple times.

## Prerequisites

- Linux or WSL environment with `apt`
- `sudo` access

## Run

```bash
chmod +x start.sh
./start.sh
```

## After setup

Activate the virtual environment:

```bash
source venv/bin/activate
```
