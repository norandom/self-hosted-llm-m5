# local-llm-stack

Runs a local reasoning model on an Apple Silicon Mac and serves it to opencode.
The model reviews specifications, quantitative maths and code. It is not a coding
agent and it is not tuned to emit code.

Before anything else: whether this is usable on your machine is decided by memory
bandwidth, not by disk space or core count. Check the requirements first. You can
otherwise spend an afternoon and 28 GB of download discovering that your Mac
generates four tokens a second.

## Requirements

| | Minimum | This was built and measured on |
|---|---|---|
| Chip | Apple Silicon, M-series Pro or better | Apple M5 Pro, 20 GPU cores |
| Memory | 48 GB unified | 64 GB |
| Free disk | 35 GB | |
| macOS | 15 or newer, Metal 4 | 25.6 |
| Tools | `uv`, `aria2`, `markitdown-mcp` (the deploy installs all three) | |

Memory bandwidth is what sets your speed. Token generation reads weights from
memory, so the ceiling for a dense model is roughly `bandwidth / model_size`
tokens per second. Measure yours before assuming any of the numbers here
transfer:

```sh
./bench.sh --bandwidth      # no server needed, runs in a few seconds
```

On the reference machine that reports:

```
device            : Apple M5 Pro
memory bandwidth  : 244 best / 234 median / 211 worst GB/s  (5 rounds)
dense ceiling     : 8.4 tok/s for a 28 GB model  (from median, since the machine will be busy)
verdict           : workable with a sparse model, not with a dense one
```

Three numbers, because one is misleading. The best round approximates the
hardware ceiling. Plan with the median instead: this is a development machine, so
an editor, a browser, containers and the model itself are all contending for the
same memory controller, and the loaded figure is what you will actually live
with. Single samples on this machine came out at 175 and 219 GB/s on hardware
whose best round is 244.

A dense 28 GB model would therefore cap somewhere under 9 tok/s here, which is
not usable. The model this repo serves is sparse, with 3.8B parameters active out
of 25.2B, so it reads a fraction of its weight file per token and measures 42 to
51 tok/s. That gap, roughly five times the dense ceiling, is the entire reason a
sparse model is specified.

Below roughly 150 GB/s I would not bother, and a base M-series chip sits in that
range. I spent a day building this on the assumption I had Max-class bandwidth. I
did not.

## What it runs

`mlx-community/gemma-4-26b-a4b-it-8bit`, 28 GB on disk, served as `reasoner`.
This is Google's general instruction model, not a code model. That is deliberate.
A model trained to produce code will happily turn a bad specification into bad
code. The job here is deciding whether the specification holds up, so the model
needs judgement over the domain rather than fluency in Python.

It scores 79.2 on GPQA and takes 260k tokens of context, which matters when the
thing you are reviewing is long.

A fair objection: why not use a frontier model through an API? Because these
specs contain material that should not leave machines you control. If that
constraint does not apply to you, use a bigger model. Nothing local at this size
will match GLM 5.2 or Opus at judging a specification, and pretending otherwise
would waste your time.

## Quick start

```sh
uvx --from pyinfra pyinfra inventory.py deploy.py -y
./start.sh
```

The deploy is idempotent, so re-running it is safe and cheap. Add `--dry` to see
what it would do without doing it. It installs `aria2` and `uv`, installs
`markitdown-mcp` as a uv tool, downloads the weights, builds a patched runtime
venv, checks that the paths in `models.yaml` resolve, and prints what ended up
enabled.

`markitdown-mcp` is installed as a tool rather than left to `uvx` so the first
request does not pay for a dependency resolve, and so it still works with the
server in `--offline` mode.

`start.sh` asks what kind of work to pre-warm the cache for:

```
  1) Information security and compliance
  2) Software programming, Python, JavaScript or Rust
  3) Quantitative finance analysis and factor research
  4) None
```

Pass `WARM_CATEGORY=infosec|programming|quant|none` to skip the question. With no
terminal to ask on, it skips warming rather than hanging.

Pre-warming only helps if the warmed text shares a literal prefix with what your
client later sends. The files in `warm-prompts/` should hold the actual system
preamble you use for that domain, so edit them to match yours. A prompt that is
merely on-topic warms nothing.

`start.sh` also raises `iogpu.wired_limit_mb` with sudo, which is why it sits
outside pyinfra. The setting goes back to default on reboot.

Point opencode at it by copying `opencode.json` into whatever project you are
working in, or merge it into `~/.config/opencode/opencode.json`.

## Measuring it

```sh
./bench.sh              # three prompt sizes against the API
./bench.sh --agent      # adds one round trip through opencode
MAX_TOKENS=256 ./bench.sh
```

On the reference machine:

```
prompt        TTFT     total  tokens    tok/s
----------------------------------------------
short        0.59s     1.79s      61     50.9
medium       1.85s     3.15s      61     46.9
long         5.79s     7.21s      61     42.8
```

Time to first token grows with prompt length because that is prefill, and prefill
is compute. Tokens per second should stay roughly flat. If your tok/s collapses as
the prompt grows, the KV cache is not being reused. Chase that before anything
else; it is usually worth more than any flag in this repo.

`--agent` measures wall clock through opencode. It will be slower than the rows
above, because the harness adds its own system prompt and tool definitions to
every turn. The size of that gap is the useful number, and `grep '\[REQUEST\]'
server.log` shows you what caused it.

Note that `opencode -p` is `--password`, not print. The scriptable flag is
`--format json`.

## Configuration

Turn MCP servers off for local use. Nothing else here comes close to mattering
this much, and I found it by accident. Three MCP servers left enabled in a global
opencode config contributed 253 tool definitions and a 72,746 token prompt on
every turn. A cloud model absorbs that. Locally it means nothing generates until
that prefill finishes. `opencode.json` here keeps only `markitdown`, which earns
its place by turning PDFs and Office files into markdown, since that is how specs
tend to arrive. Audit your own global config, then check `[REQUEST] ... tools=N`
in the server log after any MCP change.

Use `response_format` with a JSON schema for classification instead of tool
calls. Constrained output keeps the tool-call template out of the path, which is
both more reliable and a better fit for classification anyway.

`continuous_batching: true` in `models.yaml` is not optional. Clients issue
overlapping requests, one for the turn and one for things like title generation.
With batching off, the engine refuses the overlap with `SimpleEngine serialized
route is busy`, and opencode shows that as an empty reply rather than an error.

The tuning flags in `start.sh` are each commented with a reason. The ones that
mattered:

`--cache-memory-mb` bounds a prefix cache that the server otherwise reports as
"none configured" and auto-sizes to about 20% of RAM. On a 64 GB machine that
lands close to the point where it starts swapping. `--kv-cache-quantization` at 8
bits halves a KV cache that is roughly 240 KB per token here, given 8 KV heads,
256 head dimensions and 30 layers. `--chunked-prefill-tokens` stops a long
prefill from starving a request already in flight, which showed up in the logs as
occasional sub-1 tok/s replies. `--default-thinking-token-budget` caps reasoning,
and without it a reasoning model will spend thousands of tokens deliberating
about a yes or no answer.

Four flags are deliberately off, with reasons in the script: `--enable-mtp` (this
model has no MTP heads, so it does nothing), `--max-kv-size` (switches to a
rotating cache that silently drops early context), `--specprefill` (approximates
prefill, which is wrong when the prompt is the thing under review) and
`--use-paged-cache` (still marked experimental).

## Known problems

The tool-call parser needs a patch, and the server has to run from `.venv`.
vllm-mlx expects Gemma to delimit string arguments with a `<|"|>` token. The
model sometimes emits plain quotes instead, and when such a value contains an
unescaped inner quote, the parser returns no tool call at all and the client
waits forever. That is what a hung file write looks like. Upstream `main` at
4b654c0 behaves the same way, so there is nothing to upgrade to.
`apply-patch.sh` builds a pinned venv and adds a repair path that only runs after
the strict path has already failed, so it cannot break input that already worked.
`start.sh` warns if `.venv` is missing. Undo with `rm -rf .venv`.

The parser name is `gemma4`, not `gemma`. Argparse rejects the wrong one before
the server binds a port, which presents as "cannot connect to API".

This model loads through vllm-mlx's multimodal path, because it carries vision
and audio configs. That is fine here, and the log line to confirm it is
`MLLMBatchGenerator: KV prefix cache enabled`. A related model, Gemma 4 12B with
`model_type: gemma4_unified`, instead logs `System KV cache SKIP (text route)`
and runs without a KV cache, which makes it unusable for long prompts. If you
swap models, check that line first.

Keep total resident weights under about 40 GB. Past that this machine swaps and
generation drops below 1 tok/s.

Shell scripts here target bash 3.2, since that is what macOS ships. No
associative arrays, and `set -u` treats an empty array expansion as an error.

## Layout

| Path | Role |
|---|---|
| `deploy.py`, `inventory.py` | pyinfra setup over the `@local` connector, no SSH |
| `download.sh` | aria2c with 16 connections per file, skips byte-exact files, resumes partials |
| `apply-patch.sh`, `patches/` | pinned venv plus the tool-parser repair |
| `models.yaml` | vllm-mlx registry, hand-owned; the deploy checks it but never rewrites it |
| `start.sh`, `stop.sh` | server lifecycle, tuning, pre-warm selection, readiness poll |
| `bench.sh` | TTFT and tok/s at three prompt sizes |
| `warm-prompts/` | one preamble per pre-warming category |
| `opencode.json`, `.opencode/` | provider, plugins, MCP state, context-pruning config |

## Licence

No licence chosen yet for the scripts, so add one before publishing. The weights
are separate in any case: Gemma 4 comes under Google's Gemma Terms of Use, which
you accept when you download it.
