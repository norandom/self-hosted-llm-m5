#!/usr/bin/env bash
# Stop the local vllm-mlx server and release unified memory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT/.server.pid"
RESTORE_WIRED="${RESTORE_WIRED:-0}"

if [[ ! -f "$PID_FILE" ]]; then
  echo "no pid file; nothing tracked as running"
else
  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "stopping pid $pid"
    kill "$pid"
    for i in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "still alive after 30s, sending SIGKILL"
      kill -9 "$pid" || true
    fi
  else
    echo "pid $pid not running"
  fi
  rm -f "$PID_FILE"
fi

# Belt and braces: the uvx wrapper can leave the child behind.
pkill -f "vllm-mlx serve" 2>/dev/null && echo "reaped stray vllm-mlx serve" || true

if [[ "$RESTORE_WIRED" == "1" ]]; then
  echo "restoring default wired-memory limit"
  sudo sysctl iogpu.wired_limit_mb=0
fi

echo "stopped"
