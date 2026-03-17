#!/usr/bin/env bash

set -u

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${WORKDIR}"

GATEWAY_SESSION_NAME="${GATEWAY_SESSION_NAME:-paddlex-gateway}"
PADDLEX_WORKER_SESSION_PREFIX="${PADDLEX_WORKER_SESSION_PREFIX:-paddlex-worker}"
CLOUDFLARE_SESSION_NAME="${CLOUDFLARE_SESSION_NAME:-cloudflare-tunnel}"

stopped_any=0

kill_tmux_session_if_exists() {
	local session_name="$1"
	if tmux has-session -t "${session_name}" 2>/dev/null; then
		tmux kill-session -t "${session_name}"
		echo "Stopped tmux session: ${session_name}"
		stopped_any=1
	fi
}

kill_process_pattern_if_exists() {
	local pattern="$1"
	local label="$2"
	if pgrep -f "${pattern}" >/dev/null 2>&1; then
		pkill -f "${pattern}" || true
		echo "Stopped process pattern: ${label}"
		stopped_any=1
	fi
}

if command -v tmux >/dev/null 2>&1; then
	kill_tmux_session_if_exists "${GATEWAY_SESSION_NAME}"
	kill_tmux_session_if_exists "${CLOUDFLARE_SESSION_NAME}"

	while IFS= read -r session_name; do
		if [[ "${session_name}" == "${PADDLEX_WORKER_SESSION_PREFIX}-"* ]]; then
			kill_tmux_session_if_exists "${session_name}"
		fi
	done < <(tmux ls 2>/dev/null | awk -F: '{print $1}')
fi

# Also stop nohup/background processes in case tmux was not used.
kill_process_pattern_if_exists "uvicorn app.main:app" "FastAPI gateway"
kill_process_pattern_if_exists "paddlex --serve --pipeline" "PaddleX workers"
kill_process_pattern_if_exists "cloudflared tunnel --url" "Cloudflare tunnel"

if [ "${stopped_any}" -eq 1 ]; then
	echo "Stop complete."
else
	echo "No matching sessions or processes were running."
fi
