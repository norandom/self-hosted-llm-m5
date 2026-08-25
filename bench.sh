#!/usr/bin/env bash
# Measure what this box actually does: memory bandwidth, then time to first token
# and generation speed at several prompt lengths.
#
#   ./bench.sh                    # bandwidth, then three prompt sizes
#   ./bench.sh --bandwidth        # bandwidth only, no server needed
#   MAX_TOKENS=256 ./bench.sh     # longer generations
#   ./bench.sh --agent            # add one round trip through opencode
#
# Talks to /v1/chat/completions directly, so the numbers are the server's and
# not the client's. Uses the GPU for about a minute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
API_KEY="${API_KEY:-local}"
MODEL="${MODEL:-reasoner}"
MAX_TOKENS="${MAX_TOKENS:-64}"
MODEL_GB="${MODEL_GB:-28}"
AGENT=0
BW_ONLY=0
case "${1:-}" in
  --agent)     AGENT=1 ;;
  --bandwidth) BW_ONLY=1 ;;
esac

# --- memory bandwidth --------------------------------------------------------
# This is the number that decides whether the whole setup is viable. Generation
# reads weights out of memory for every token, so bandwidth divided by model size
# is the hard ceiling for a dense model. Sparse models beat that ceiling because
# only the active experts are read.
#
# Prefers .venv (mlx is already there via vllm-mlx) and falls back to uvx, so
# this works before the venv exists.
if [ -x "$ROOT/.venv/bin/python" ]; then
  BW_PY=("$ROOT/.venv/bin/python")
else
  BW_PY=(uvx --from mlx-lm --with mlx python)
fi

"${BW_PY[@]}" - "$MODEL_GB" <<'PY'
import statistics, sys, time
import mlx.core as mx

model_gb = float(sys.argv[1])
info = mx.device_info()
print(f"device            : {info.get('device_name', '?')}")

# 256 MB of bf16, multiplied in place: one read plus one write per element.
a = mx.zeros((256 * 1024 * 1024 // 2,), dtype=mx.bfloat16)
mx.eval(a)
for _ in range(3):
    mx.eval(a * 1.0001)          # warm up, let Metal settle

# Several rounds, reported as a range. The best round approximates the hardware
# ceiling. The median is what you should actually plan with, because a dev machine
# is busy: an editor, a browser, containers and the model itself all compete for
# the same memory controller. Sizing against the best round flatters the hardware
# and then disappoints you during real work.
iters, rounds = 20, 5
samples = []
for _ in range(rounds):
    t = time.perf_counter()
    for _ in range(iters):
        mx.eval(a * 1.0001)
    samples.append(iters * a.nbytes * 2 / (time.perf_counter() - t) / 1e9)

best, mid, worst = max(samples), statistics.median(samples), min(samples)
print(f"memory bandwidth  : {best:.0f} best / {mid:.0f} median / {worst:.0f} worst GB/s"
      f"  ({rounds} rounds)")
print(f"dense ceiling     : {mid / model_gb:.1f} tok/s for a {model_gb:.0f} GB model"
      f"  (from median, since the machine will be busy)")
if mid < 150:
    print("verdict           : too slow, this stack will not be pleasant here")
elif mid < 250:
    print("verdict           : workable with a sparse model, not with a dense one")
else:
    print("verdict           : fine")
if best - worst > 0.2 * best:
    print("note              : wide spread, so something else was competing for memory."
          "\n                    That is the normal case on a working machine.")
PY

if [ "$BW_ONLY" -eq 1 ]; then
  exit 0
fi
echo

curl -sf -m 5 -H "Authorization: Bearer $API_KEY" \
  "http://$HOST:$PORT/v1/models" >/dev/null || {
  echo "no server on $HOST:$PORT. Run ./start.sh first."; exit 1
}

python3 - "$HOST" "$PORT" "$API_KEY" "$MODEL" "$MAX_TOKENS" <<'PY'
import json, sys, time, urllib.request

host, port, key, model, max_tokens = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
url = f"http://{host}:{port}/v1/chat/completions"

# One repeated sentence, so prompt length is the only variable between rows.
UNIT = "The specification requires deterministic rounding of monetary amounts. "
SIZES = [("short", 5), ("medium", 400), ("long", 1600)]


def run(filler_units):
    prompt = UNIT * filler_units + "\nReply with the single word: acknowledged."
    body = json.dumps({
        "model": model, "stream": True, "temperature": 0,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})

    start = time.perf_counter()
    ttft = None
    tokens = 0
    for raw in urllib.request.urlopen(req, timeout=1800):
        line = raw.decode().strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        try:
            delta = json.loads(payload)["choices"][0].get("delta") or {}
        except Exception:
            continue
        # Reasoning tokens count as generation too; both cost the same.
        if delta.get("content") or delta.get("reasoning_content"):
            if ttft is None:
                ttft = time.perf_counter() - start
            tokens += 1
    total = time.perf_counter() - start
    gen = total - (ttft or 0)
    return ttft, total, tokens, (tokens / gen if gen > 0 else 0)


print(f"model={model}  max_tokens={max_tokens}")
print()
print(f"{'prompt':8} {'TTFT':>9} {'total':>9} {'tokens':>7} {'tok/s':>8}")
print("-" * 46)
for label, units in SIZES:
    ttft, total, tokens, tps = run(units)
    print(f"{label:8} {ttft or 0:8.2f}s {total:8.2f}s {tokens:7d} {tps:8.1f}")
print()
print("TTFT scales with prompt length (prefill); tok/s should not.")
print("If tok/s falls as the prompt grows, the KV cache is not being reused.")
PY

if [ "$AGENT" -eq 1 ]; then
  echo
  echo "=== end to end through opencode ==="
  echo "Measures wall clock only. The harness adds its system prompt and tool"
  echo "definitions on top of your prompt, so expect this to be slower than the"
  echo "rows above; the gap is the harness overhead, which is the useful number."
  command -v opencode >/dev/null || { echo "opencode not on PATH"; exit 0; }
  raw="$ROOT/.bench-events.jsonl"
  start=$(python3 -c 'import time;print(time.perf_counter())')
  opencode run --format json "Reply with the single word: acknowledged." > "$raw" 2>/dev/null || true
  end=$(python3 -c 'import time;print(time.perf_counter())')
  python3 -c "print(f'wall clock: {$end - $start:.2f}s')"
  echo "raw events: $raw"
  echo "Check the server log for the matching request:"
  echo "  grep '\[REQUEST\]' server.log | tail -1"
  echo "The tools= and prompt_tokens= values there explain most of the gap."
fi
