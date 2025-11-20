#!/usr/bin/env bash
set -euo pipefail

# Monitor the RTX 3090 presence/health. If the GPU disappears or nvidia-smi fails,
# sound a bell and print a warning with a timestamp.
# Usage: ./gpu-monitor.sh [interval_seconds]  (default: 5)

INTERVAL="${1:-5}"
GPU_QUERY_CMD=(nvidia-smi -L)

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

do_beep() {
  # Prefer hardware PC speaker beep if the 'beep' utility is present and pcspkr is loaded.
  modprobe pcspkr 2>/dev/null || true

  if command -v beep >/dev/null 2>&1; then
    beep -f 880 -l 200 -r 2 2>/dev/null && return
  fi

  # Fallback terminal bell (depends on terminal settings).
  printf '\a'
}

while true; do
  TS="$(date '+%Y-%m-%d %H:%M:%S')"
  if "${GPU_QUERY_CMD[@]}" >/dev/null 2>&1; then
    echo -e "${GREEN}[$TS] OK: GPU present${RESET}"
  else
    do_beep
    echo -e "${YELLOW}[$TS] WARN: GPU missing or driver not responding${RESET}"
  fi
  sleep "${INTERVAL}"
done
