#!/usr/bin/env bash
# Idempotent model download via aria2c. Safe to re-run: files already present at
# their exact expected byte size are skipped, everything else is (re)queued and
# resumed. Exits 0 with nothing to do when complete.
#
# Usage:
#   ./download.sh                 # the reasoner (default, and the only model)
#   ./download.sh --verify        # check only, download nothing
#
# Model: mlx-community/gemma-4-26b-a4b-it-8bit (28.0 GB)
#   General instruction model, deliberately NOT code-tuned. The job is judging
#   specs, not emitting code. 25.2B total but only 3.8B active per token, so it
#   is fast on this machine's 219 GB/s, and it takes 260k context for long specs.
#   Already MLX-native: no conversion pass needed.
#
# NOTE: macOS ships bash 3.2 (no associative arrays, and `set -u` errors on
# expanding an empty array). Everything below stays 3.2-compatible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="${MODEL_DIR:-$ROOT/models}"
LIST_DIR="$ROOT/.aria2"

# repo:path:bytes,path:bytes,...   bytes=0 means existence-check only.
# Sizes verified against the HF tree API.
repo_spec() {
  case "$1" in
    reasoner) echo "mlx-community/gemma-4-26b-a4b-it-8bit:config.json:0,generation_config.json:0,chat_template.jinja:0,processor_config.json:0,tokenizer_config.json:0,tokenizer.json:32169626,model.safetensors.index.json:0,model-00001-of-00006.safetensors:5180812050,model-00002-of-00006.safetensors:5205340944,model-00003-of-00006.safetensors:5205341183,model-00004-of-00006.safetensors:5205341191,model-00005-of-00006.safetensors:5205341163,model-00006-of-00006.safetensors:1951464898" ;;
    *)        echo "" ;;
  esac
}

VERIFY_ONLY=0
ARGS=""
for a in "$@"; do
  case "$a" in
    --verify) VERIFY_ONLY=1 ;;
    *)        ARGS="$ARGS $a" ;;
  esac
done
# shellcheck disable=SC2086
set -- $ARGS

if [ $# -eq 0 ]; then
  KEYS=(reasoner)
else
  KEYS=("$@")
fi

for key in "${KEYS[@]}"; do
  [ -z "$(repo_spec "$key")" ] && { echo "unknown key: $key"; exit 1; }
done

if [ "$VERIFY_ONLY" -eq 0 ]; then
  command -v aria2c >/dev/null || { echo "aria2c missing: brew install aria2"; exit 1; }
fi

AUTH_ARGS=()
if [ -n "${HF_TOKEN:-}" ]; then
  AUTH_ARGS=(--header "Authorization: Bearer ${HF_TOKEN}")
fi

mkdir -p "$LIST_DIR"
LIST="$LIST_DIR/urls.txt"
: > "$LIST"

queued=0
have=0
for key in "${KEYS[@]}"; do
  spec="$(repo_spec "$key")"
  repo="${spec%%:*}"
  files="${spec#*:}"
  dest="$MODEL_DIR/${repo##*/}"
  # Only create the destination when actually downloading; otherwise --verify
  # leaves empty directories behind that look like present-but-empty models.
  [ "$VERIFY_ONLY" -eq 0 ] && mkdir -p "$dest"

  IFS=',' read -ra arr <<< "$files"
  for entry in "${arr[@]}"; do
    f="${entry%:*}"
    want="${entry##*:}"
    path="$dest/$f"

    # Complete iff: no aria2 control file, exists, and matches expected size
    # (or exists at all when no size is recorded).
    if [ ! -e "$path.aria2" ] && [ -f "$path" ]; then
      if [ "$want" = "0" ]; then
        have=$((have + 1)); continue
      fi
      actual="$(stat -f%z "$path")"
      if [ "$actual" = "$want" ]; then
        have=$((have + 1)); continue
      fi
      echo "size mismatch, requeueing: $key/$f (have $actual, want $want)"
    fi

    printf '%s\n  dir=%s\n  out=%s\n' \
      "https://huggingface.co/${repo}/resolve/main/${f}" "$dest" "$f" >> "$LIST"
    queued=$((queued + 1))
  done
done

echo "complete: $have file(s); to fetch: $queued file(s)"

if [ "$queued" -eq 0 ]; then
  echo "nothing to do"
  exit 0
fi
if [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "--verify: not downloading"
  exit 1
fi

ARIA_ARGS=(
  --input-file="$LIST"
  --max-concurrent-downloads=4     # concurrent files
  --max-connection-per-server=16   # -x: connections per host
  --split=16                       # -s: range-split each file
  --min-split-size=1M
  --continue=true                  # resume partials
  --auto-file-renaming=false
  --allow-overwrite=true
  --file-allocation=none
  --human-readable=true
)

# Progress reporting has three cases, because pyinfra captures a command's
# stdout at every verbosity level (-vv only echoes the command, never output).
#
#   1. Interactive terminal      -> aria2c's live readout, straight through.
#   2. Captured but /dev/tty is  -> force the readout on and tee it to the
#      reachable (pyinfra @local)   terminal device, bypassing the capture.
#                                   stdout still gets a copy for the logs.
#   3. No terminal at all (CI)   -> the carriage-return readout is unreadable
#                                   in a log, so switch it off and print
#                                   periodic summary BLOCKS instead.
#                                   --console-log-level=notice is required or
#                                   aria2c suppresses those summaries.
if [ -t 1 ]; then
  exec aria2c "${ARIA_ARGS[@]}" \
    --show-console-readout=true \
    --summary-interval="${ARIA_SUMMARY_INTERVAL:-5}" \
    --console-log-level=warn \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
# Test by actually opening it: on macOS /dev/tty always exists as a character
# device and passes -c/-w even when there is no controlling terminal, and the
# failure only shows up later as "tee: /dev/tty: Device not configured".
elif { : > /dev/tty; } 2>/dev/null; then
  echo "(progress bar routed to /dev/tty, bypassing output capture)"
  aria2c "${ARIA_ARGS[@]}" \
    --show-console-readout=true \
    --summary-interval="${ARIA_SUMMARY_INTERVAL:-5}" \
    --console-log-level=warn \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>&1 | tee /dev/tty
  exit "${PIPESTATUS[0]}"
else
  echo "(no terminal: printing a progress summary every ${ARIA_SUMMARY_INTERVAL:-15}s)"
  exec aria2c "${ARIA_ARGS[@]}" \
    --show-console-readout=false \
    --summary-interval="${ARIA_SUMMARY_INTERVAL:-15}" \
    --console-log-level=notice \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
fi
