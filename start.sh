#!/usr/bin/env bash
# Start the local vllm-mlx server (router + implementer from models.yaml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

VLLM_MLX_VERSION="${VLLM_MLX_VERSION:-0.4.1}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
API_KEY="${API_KEY:-local}"
PID_FILE="$ROOT/.server.pid"
LOG_FILE="$ROOT/server.log"

command -v uvx >/dev/null || { echo "uvx missing: brew install uv"; exit 1; }

# Trust the macOS Keychain so a corporate TLS-inspecting proxy does not break
# uv's package resolution. UV_NATIVE_TLS is the deprecated spelling of this.
: "${UV_SYSTEM_CERTS:=1}"
export UV_SYSTEM_CERTS

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "already running (pid $(cat "$PID_FILE")) on $HOST:$PORT"
  exit 0
fi

# Raise the Metal wired-memory ceiling. Default caps you around 48 GB on a
# 64 GB box, which is not enough for 41 GB of weights plus a long-context KV
# cache. Reverts on reboot; `sudo sysctl iogpu.wired_limit_mb=0` to undo now.
WIRED_MB="${WIRED_MB:-57344}"
current="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
if [[ "$current" != "$WIRED_MB" ]]; then
  echo "raising iogpu.wired_limit_mb: $current -> $WIRED_MB (needs sudo)"
  sudo sysctl iogpu.wired_limit_mb="$WIRED_MB"
fi

# --- tuning ------------------------------------------------------------------
# Every value here is overridable by env var. Rationale per flag:
#
# CACHE_MEMORY_MB    The server otherwise reports "prefix-cache maximum none
#                    configured" and auto-sizes to ~20% of RAM (~12.8 GB). With
#                    28 GB of weights that lands near 41 GB, which is where this
#                    machine starts swapping. Bound it explicitly.
# KV quantization    KV geometry here is 8 KV heads x 256 head_dim x 30 layers,
#                    about 240 KB/token at fp16. 8-bit halves that; quality cost
#                    is negligible and it buys real context headroom.
# CHUNKED_PREFILL    Caps prefill tokens per scheduler step so a long prefill
#                    cannot starve an in-flight request. This is the fix for the
#                    occasional 0.7 tok/s outlier in the logs.
# THINKING_BUDGET    Biggest latency lever for classification: without a cap a
#                    reasoning model spends thousands of tokens thinking about a
#                    yes/no. Per-request thinking_token_budget overrides it.
# SSD cache          Persists the prefix cache across restarts, so a standing
#                    spec preamble stays warm. Cheap on this machine's SSD.
# MAX_NUM_SEQS       Single user; the default of 16 reserves concurrency
#                    headroom that is never used.
# --offline          Everything is local, so this keeps the corporate TLS proxy
#                    entering the picture at all.
#
# Deliberately NOT set:
#   --enable-mtp     This model has no num_nextn_predict_layers, so there are no
#                    MTP heads and the flag is a no-op.
#   --max-kv-size    Switches to RotatingKVCache, which silently drops early
#                    context. Wrong for reasoning over a long spec.
#   --specprefill    Approximates prefill to cut TTFT. Fine for code output,
#                    wrong when the task is judging the prompt itself.
#   --use-paged-cache  Marked experimental; only worth trying if memory-bound.
CACHE_MEMORY_MB="${CACHE_MEMORY_MB:-10240}"
CHUNKED_PREFILL="${CHUNKED_PREFILL:-2048}"
THINKING_BUDGET="${THINKING_BUDGET:-2048}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
SSD_CACHE_DIR="${SSD_CACHE_DIR:-$ROOT/.kvcache}"
SSD_CACHE_MAX_GB="${SSD_CACHE_MAX_GB:-20}"

# --- pre-warming category ----------------------------------------------------
# Which domain preamble to pre-run at startup, populating the prefix cache.
#
# IMPORTANT: prefix caching only helps to the extent that a warmed prompt shares
# a literal prefix with what the client later sends. These files are therefore
# meant to hold the *actual* system preamble you use for that domain. Edit them
# to match. A merely topical prompt warms nothing.
#
# Pick non-interactively with WARM_CATEGORY=infosec|programming|quant|none.
WARM_DIR="$ROOT/warm-prompts"

warm_file_for() {
  case "$1" in
    1|infosec)     echo "$WARM_DIR/infosec.json" ;;
    2|programming) echo "$WARM_DIR/programming.json" ;;
    3|quant)       echo "$WARM_DIR/quant.json" ;;
    4|none)        echo "none" ;;
    *)             echo "" ;;
  esac
}

if [ -n "${WARM_CATEGORY:-}" ]; then
  CHOICE="$WARM_CATEGORY"
elif [ -t 0 ]; then
  echo
  echo "Pre-warm the prefix cache for which kind of work?"
  echo "  1) Information security and compliance"
  echo "  2) Software programming, Python, JavaScript or Rust"
  echo "  3) Quantitative finance analysis and factor research"
  echo "  4) None, skip pre-warming"
  CHOICE=""
  while [ -z "$(warm_file_for "$CHOICE")" ]; do
    printf 'Select [1-4]: '
    read -r CHOICE || CHOICE=4
    [ -z "$(warm_file_for "$CHOICE")" ] && echo "  not a valid choice: $CHOICE"
  done
else
  # No stdin to prompt on (pyinfra, cron, CI). Skip rather than block forever.
  echo "(non-interactive: skipping pre-warming; set WARM_CATEGORY to choose one)"
  CHOICE=none
fi

WARM_PROMPTS="$(warm_file_for "$CHOICE")"
if [ -z "$WARM_PROMPTS" ]; then
  echo "ERROR: invalid WARM_CATEGORY '$CHOICE'"
  echo "       expected one of: infosec, programming, quant, none (or 1-4)"
  exit 2
fi
if [ "$WARM_PROMPTS" = "none" ]; then
  echo "pre-warming: disabled"
  WARM_PROMPTS=""
elif [ ! -f "$WARM_PROMPTS" ]; then
  echo "WARNING: $WARM_PROMPTS not found. Starting without pre-warming."
  WARM_PROMPTS=""
else
  echo "pre-warming: $(basename "$WARM_PROMPTS")"
fi

TUNING=(
  --cache-memory-mb "$CACHE_MEMORY_MB"
  --kv-cache-quantization
  --kv-cache-quantization-bits 8
  --chunked-prefill-tokens "$CHUNKED_PREFILL"
  --default-thinking-token-budget "$THINKING_BUDGET"
  --max-num-seqs "$MAX_NUM_SEQS"
  --ssd-cache-dir "$SSD_CACHE_DIR"
  --ssd-cache-max-gb "$SSD_CACHE_MAX_GB"
  --enable-metrics
  --offline
)
mkdir -p "$SSD_CACHE_DIR"
[ -f "$WARM_PROMPTS" ] && TUNING+=(--warm-prompts "$WARM_PROMPTS")

# Roll the log before appending to it. The launchd agent handles the daily case
# while the server runs; this covers a machine that was asleep at 00:05.
[ -x "$ROOT/rotate-logs.sh" ] && "$ROOT/rotate-logs.sh" >/dev/null 2>&1 || true

echo "starting vllm-mlx $VLLM_MLX_VERSION on $HOST:$PORT"
# Parser name is `gemma4`; `gemma` is not in the enum and argparse rejects it
# before the server binds a port. Without --reasoning-parser, the model's
# <|channel>thought markers leak into `content` instead of `reasoning_content`.
# Prefer the patched venv (see apply-patch.sh). uvx builds a throwaway env per
# run, so the patch would not survive there.
if [ -x "$ROOT/.venv/bin/vllm-mlx" ]; then
  SERVE=("$ROOT/.venv/bin/vllm-mlx")
  echo "using patched venv: $ROOT/.venv"
else
  SERVE=(uvx --from "vllm-mlx==${VLLM_MLX_VERSION}" vllm-mlx)
  echo "WARNING: .venv missing, running UNPATCHED via uvx. File writes may hang."
  echo "         run ./apply-patch.sh (or the pyinfra deploy) to fix."
fi

"${SERVE[@]}" serve \
  --models-config "$ROOT/models.yaml" \
  --host "$HOST" \
  --port "$PORT" \
  --api-key "$API_KEY" \
  --enable-auto-tool-choice \
  --tool-call-parser gemma4 \
  --reasoning-parser gemma4 \
  "${TUNING[@]}" \
  >> "$LOG_FILE" 2>&1 &

echo $! > "$PID_FILE"
echo "pid $(cat "$PID_FILE"), logging to $LOG_FILE"

# Wait for readiness rather than guessing. Preloading 24 GB takes a while.
for i in $(seq 1 120); do
  if curl -sf -H "Authorization: Bearer $API_KEY" \
       "http://$HOST:$PORT/v1/models" >/dev/null 2>&1; then
    echo "ready:"
    curl -s -H "Authorization: Bearer $API_KEY" "http://$HOST:$PORT/v1/models"
    echo
    exit 0
  fi
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "server died during startup; last log lines:"
    tail -30 "$LOG_FILE"
    rm -f "$PID_FILE"
    exit 1
  fi
  sleep 2
done

echo "timed out waiting for readiness; check $LOG_FILE"
exit 1
