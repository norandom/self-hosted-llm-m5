#!/usr/bin/env bash
# Build a pinned local venv and apply the Gemma 4 tool-parser repair patch.
# Idempotent: detects the marker and exits without touching an already-patched
# install. Safe to re-run.
#
# WHY A VENV: uvx builds a throwaway environment per invocation, so a patched
# file would not survive. This creates one persistent env that start.sh uses.
#
# WHY THE PATCH: see patches/gemma4_lenient_args.py. Short version: the model
# intermittently emits plain "-quoted tool arguments instead of Gemma's <|"|>
# template form, the strict parser then drops the tool call entirely, and
# opencode waits forever for a call that never arrives. Upstream main has the
# same behaviour, so there is nothing to upgrade to.
#
# To revert: rm -rf .venv  (then re-run this script for a clean unpatched env,
# or delete the script's invocation from deploy.py)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/.venv"
VLLM_MLX_VERSION="${VLLM_MLX_VERSION:-0.4.1}"
PATCH_FILE="$ROOT/patches/gemma4_lenient_args.py"
# No leading dashes: BSD grep would parse them as options even with -F.
MARKER="PATCH: lenient-args-repair"

: "${UV_SYSTEM_CERTS:=1}"
export UV_SYSTEM_CERTS

command -v uv >/dev/null || { echo "uv missing: brew install uv"; exit 1; }
[ -f "$PATCH_FILE" ] || { echo "missing patch: $PATCH_FILE"; exit 1; }

if [ ! -x "$VENV/bin/python" ]; then
  echo "creating venv at $VENV"
  uv venv "$VENV"
fi

if ! "$VENV/bin/python" -c "import vllm_mlx" 2>/dev/null; then
  echo "installing vllm-mlx==$VLLM_MLX_VERSION into $VENV"
  uv pip install --python "$VENV/bin/python" "vllm-mlx==${VLLM_MLX_VERSION}"
fi

TARGET="$("$VENV/bin/python" -c \
  'import vllm_mlx.tool_parsers.gemma4_tool_parser as m; print(m.__file__)')"
echo "target: $TARGET"

if grep -qF -e "$MARKER" "$TARGET"; then
  echo "already patched, nothing to do"
else
  cp -n "$TARGET" "${TARGET}.orig"
  printf '\n\n' >> "$TARGET"
  cat "$PATCH_FILE" >> "$TARGET"
  echo "patch appended (original saved as ${TARGET}.orig)"
fi

# Verify against the exact shape that used to silently drop the tool call.
echo "verifying..."
"$VENV/bin/python" - <<'PY'
import json, sys
import vllm_mlx.tool_parsers.gemma4_tool_parser as g
S, E = g.TOOL_CALL_START, g.TOOL_CALL_END
p = g.Gemma4ToolParser()
checks = [
    ("plain-quoted with inner quotes",
     f'{S}call:edit{{"filePath": "/tmp/a.sh", "oldString": "echo "old"", "newString": "echo "new""}}{E}',
     lambda a: a["oldString"] == 'echo "old"'),
    ("multiline content keeps real newlines",
     f'{S}call:write{{"filePath": "/h.sh", "content": "#!/bin/bash\\necho "hi"\\n"}}{E}',
     lambda a: "\n" in a["content"] and '"hi"' in a["content"]),
    ("proper <|\"|> form still works",
     f'{S}call:edit{{filePath: <|"|>/tmp/a.sh<|"|>, newString: <|"|>echo "x"<|"|>}}{E}',
     lambda a: a["newString"] == 'echo "x"'),
]
bad = 0
for label, text, ok in checks:
    calls, _ = p._extract_canonical(text)
    if not calls:
        print(f"  FAIL {label}: no tool call"); bad += 1; continue
    try:
        args = json.loads(calls[0]["arguments"])
    except Exception as e:
        print(f"  FAIL {label}: invalid JSON {e}"); bad += 1; continue
    print(f"  {'ok  ' if ok(args) else 'FAIL'} {label}")
    if not ok(args):
        bad += 1
sys.exit(1 if bad else 0)
PY
echo "patch verified"
