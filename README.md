# local-llm-stack

A local reasoning model for quant workflow design — judging specs, quantitative
math, and Python — served by `vllm-mlx` over an OpenAI-compatible endpoint.

**Model:** `mlx-community/gemma-4-26b-a4b-it-8bit`, 28 GB, served as `reasoner`.
A general instruction model, deliberately not code-tuned: the job is deciding
whether a spec is any good, not transcribing it. 25.2B total with 3.8B active per
token, GPQA 79.2, 260k context.

## Setup

```sh
uvx --from pyinfra pyinfra inventory.py deploy.py -y
```

Idempotent; `--dry` shows what it would do. Installs `aria2`/`uv`, downloads
weights, builds the patched runtime venv, validates `models.yaml`, and reports
the enabled feature set. Already MLX-native, so there is no conversion step.

## Run

```sh
./start.sh                  # blocks until /v1/models answers, then backgrounds
./stop.sh
RESTORE_WIRED=1 ./stop.sh   # also restore the default Metal memory ceiling
```

`start.sh` needs sudo to raise `iogpu.wired_limit_mb`; that is why it is outside
pyinfra. The setting resets on reboot.

On launch it asks which kind of work to pre-warm the prefix cache for:

```
  1) Information security and compliance
  2) Software programming — Python, JavaScript or Rust
  3) Quantitative finance analysis and factor research
  4) None — skip pre-warming
```

Non-interactively, pass `WARM_CATEGORY=infosec|programming|quant|none`; with no
stdin to prompt on (pyinfra, cron) it skips warming rather than blocking.

> **Pre-warming only pays off if the warmed text shares a literal prefix with
> what the client later sends.** The files in `warm-prompts/` are therefore meant
> to hold the *actual* system preamble you use for that domain — edit them to
> match yours. A merely topical prompt warms nothing.

## Layout

| Path | Role |
|---|---|
| `deploy.py` / `inventory.py` | pyinfra setup, `@local` connector, no SSH |
| `download.sh` | aria2c `-j4 -x16 -s16`; skips byte-exact files, resumes partials |
| `apply-patch.sh` / `patches/` | pinned venv + Gemma 4 tool-parser repair |
| `models.yaml` | vllm-mlx registry. Hand-owned — the deploy validates, never rewrites |
| `start.sh` / `stop.sh` | server lifecycle, tuning flags, pre-warm prompt, readiness poll |
| `warm-prompts/` | one preamble file per pre-warming category |
| `opencode.json` / `.opencode/` | provider, plugins, MCP state, DCP config |

## Configuration that matters

**Use `response_format` with a JSON schema for classification, not tool calls.**
Constrained JSON output keeps the tool-call template out of the path entirely,
which is both more reliable and the right interface for classification work.

**MCP servers stay mostly off.** The global `~/.config/opencode/opencode.jsonc`
enables `markitdown`, `zscaler` and `playwright`; together those contributed 253
tool definitions and a 72,746-token prompt per turn. Only `markitdown` is on
here. After any MCP change, check the server's `[REQUEST] ... tools=N` line.

**`continuous_batching: true` is required**, or overlapping requests are rejected
with `SimpleEngine serialized route is busy` and surface as empty responses.

**Parser name is `gemma4`, not `gemma`** — argparse rejects the latter before the
server binds a port, which looks like "cannot connect to API".

**The server must run from `.venv`.** `apply-patch.sh` adds a repair path for a
vllm-mlx bug where plain-quoted tool arguments containing unescaped inner quotes
cause the parser to drop the tool call silently, hanging the client. Upstream
`main` (4b654c0) behaves the same. `start.sh` warns if `.venv` is missing.
Revert with `rm -rf .venv`.

**Scripts stay bash 3.2 compatible** — macOS `/bin/bash` has no associative
arrays, and `set -u` errors on expanding an empty array.

## Performance ceiling

Measured on this machine:

```
Apple M5 Pro, 20 GPU cores, Metal 4
achieved memory bandwidth : 219 GB/s
```

Generation is bandwidth-bound: a dense model's ceiling is `219 / size_in_GB`
tok/s. This model is sparse — 3.8B of 25.2B active — so it reads a fraction of
its 28 GB per token and is far faster than a dense model of the same file size.
That is the property to preserve in any future model choice; a dense 24 GB model
caps near 9 tok/s here.

Keep total resident weights under ~40 GB. Above that this machine swaps, and
generation drops below 1 tok/s.
