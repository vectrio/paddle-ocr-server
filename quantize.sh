#!/usr/bin/env bash

set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${WORKDIR}"

if [ -f "venv/bin/activate" ]; then
	# shellcheck disable=SC1091
	source venv/bin/activate
fi

if command -v python >/dev/null 2>&1; then
	PYTHON_CMD="python"
elif command -v python3 >/dev/null 2>&1; then
	PYTHON_CMD="python3"
else
	echo "Python executable not found."
	exit 1
fi

if ! ${PYTHON_CMD} -m pip --version >/dev/null 2>&1; then
	echo "pip is required but not available for ${PYTHON_CMD}."
	exit 1
fi

AUTO_INSTALL_QUANT_DEPS="${AUTO_INSTALL_QUANT_DEPS:-true}"
PADDLESLIM_INSTALL_FLAGS="${PADDLESLIM_INSTALL_FLAGS:---no-deps}"

if [ "${AUTO_INSTALL_QUANT_DEPS}" != "true" ] && [ "${AUTO_INSTALL_QUANT_DEPS}" != "false" ]; then
	echo "AUTO_INSTALL_QUANT_DEPS must be 'true' or 'false'."
	exit 1
fi

if ! ${PYTHON_CMD} -c "import yaml" >/dev/null 2>&1; then
	if [ "${AUTO_INSTALL_QUANT_DEPS}" = "true" ]; then
		echo "Installing missing dependency: pyyaml"
		${PYTHON_CMD} -m pip install pyyaml
	else
		echo "Missing dependency: pyyaml"
		echo "Install manually: ${PYTHON_CMD} -m pip install pyyaml"
		exit 1
	fi
fi

if ! ${PYTHON_CMD} -c "import paddleslim" >/dev/null 2>&1; then
	if [ "${AUTO_INSTALL_QUANT_DEPS}" = "true" ]; then
		echo "Installing missing dependency: paddleslim (${PADDLESLIM_INSTALL_FLAGS})"
		echo "Using --no-deps by default to avoid unintended package downgrades (for example opencv)."
		${PYTHON_CMD} -m pip install ${PADDLESLIM_INSTALL_FLAGS} paddleslim
	else
		echo "Missing dependency: paddleslim"
		echo "Install manually (safe default): ${PYTHON_CMD} -m pip install --no-deps paddleslim"
		exit 1
	fi
fi

CONFIG_PATH="${CONFIG_PATH:-${WORKDIR}/PP-StructureV3.yaml}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${WORKDIR}/quantized-models}"
WEIGHT_BITS="${WEIGHT_BITS:-8}"
QUANT_OPS="${QUANT_OPS:-conv2d,depthwise_conv2d,mul,matmul}"
EXTRA_MODEL_DIRS="${EXTRA_MODEL_DIRS:-}"

if [ ! -f "${CONFIG_PATH}" ]; then
	echo "Config not found: ${CONFIG_PATH}"
	exit 1
fi

echo "Starting PPStructureV3 sub-module quantization..."
echo "CONFIG_PATH=${CONFIG_PATH}"
echo "OUTPUT_ROOT=${OUTPUT_ROOT}"
echo "WEIGHT_BITS=${WEIGHT_BITS}"
echo "QUANT_OPS=${QUANT_OPS}"

CMD=(
	"${PYTHON_CMD}" "${WORKDIR}/scripts/quantize_ppstructurev3.py"
	"--config" "${CONFIG_PATH}"
	"--output-root" "${OUTPUT_ROOT}"
	"--weight-bits" "${WEIGHT_BITS}"
	"--quant-ops" "${QUANT_OPS}"
)

if [ -n "${EXTRA_MODEL_DIRS}" ]; then
	CMD+=("--extra-model-dirs" "${EXTRA_MODEL_DIRS}")
fi

"${CMD[@]}"

echo "Quantization complete."
