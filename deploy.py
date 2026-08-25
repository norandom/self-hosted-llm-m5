"""Idempotent setup for the local reasoning model.

    uvx --from pyinfra pyinfra inventory.py deploy.py -y

Re-running is a no-op once everything is in place. Setup only. Starting the
server lives in start.sh, which needs sudo for the Metal memory ceiling, so this
never requires elevated privileges.
"""

from pathlib import Path

from pyinfra import host, logger
from pyinfra.facts.files import Directory, File
from pyinfra.facts.server import Command
from pyinfra.operations import brew, files, server

ROOT = Path(__file__).parent.resolve()
MODELS_DIR = ROOT / "models"
MODEL_DIR_NAME = "gemma-4-26b-a4b-it-8bit"

# Largest artifact and its exact size from the HF tree API. Presence at the
# right byte count is the "is the download really done" test.
SENTINEL = "model-00005-of-00006.safetensors"
SENTINEL_SIZE = 5205341163


def _download_complete() -> bool:
    path = MODELS_DIR / MODEL_DIR_NAME / SENTINEL
    if host.get_fact(File, path=f"{path}.aria2"):
        return False  # partial transfer
    fact = host.get_fact(File, path=str(path))
    if not fact or fact.get("size") is None:
        return False
    if int(fact["size"]) != SENTINEL_SIZE:
        logger.warning(f"{SENTINEL}: size {fact['size']} != {SENTINEL_SIZE}")
        return False
    return True


brew.packages(name="Install aria2 and uv", packages=["aria2", "uv"])
files.directory(name="Create models directory", path=str(MODELS_DIR))

# Daily log rotation. The agent is a launchd user job, so no root involved.
# Installing is idempotent: --install boots out any existing copy first.
rotate_plist = Path.home() / "Library/LaunchAgents/com.local-llm-stack.logrotate.plist"
if host.get_fact(File, path=str(rotate_plist)):
    logger.info("log rotation: agent installed")
else:
    server.shell(
        name="Install daily log rotation agent",
        commands=["./rotate-logs.sh --install"],
        _chdir=str(ROOT),
    )

# markitdown-mcp is the one MCP server this setup keeps on: it converts PDFs,
# Office files and HTML to markdown, which is how specs usually arrive. Installed
# as a uv tool rather than left to uvx so the first request does not pay for a
# resolve, and so it works with --offline.
server.shell(
    name="Install markitdown-mcp",
    commands=["uv tool install --quiet markitdown-mcp || uv tool upgrade --quiet markitdown-mcp"],
    _chdir=str(ROOT),
)

if _download_complete():
    logger.info("weights: present and byte-exact")
else:
    server.shell(
        name="Download weights",
        commands=["./download.sh"],
        _chdir=str(ROOT),
    )

# The Gemma 4 tool parser drops tool calls outright when the model emits plain
# "-quoted arguments instead of the <|"|> template form, which presents as a
# client hanging on a tool call. apply-patch.sh builds a pinned venv with a
# repair path that only runs after the strict path has already failed.
parser_module = (
    ROOT / ".venv/lib/python3.14/site-packages/vllm_mlx/tool_parsers/gemma4_tool_parser.py"
)
patched = False
if host.get_fact(File, path=str(parser_module)):
    patched = "PATCH: lenient-args-repair" in parser_module.read_text()

if patched:
    logger.info("tool-parser patch: applied")
else:
    server.shell(
        name="Build patched venv",
        commands=["./apply-patch.sh"],
        _chdir=str(ROOT),
    )

# models.yaml is hand-owned, being the tuning surface. Validate its paths rather than
# rewriting it; a bad path otherwise surfaces as an opaque server error.
registry = ROOT / "models.yaml"
if not host.get_fact(File, path=str(registry)):
    logger.error("models.yaml is missing")
else:
    for line in registry.read_text().splitlines():
        stripped = line.strip()
        if not stripped.startswith("path:"):
            continue
        raw = stripped.split("path:", 1)[1].strip()
        target = (ROOT / raw).resolve() if raw.startswith(".") else Path(raw)
        # Check for weights, not just the directory. An empty directory would
        # otherwise report ok and the failure would surface at server start.
        if not host.get_fact(Directory, path=str(target)):
            logger.error(f"registry path MISSING: {raw}")
        elif not host.get_fact(File, path=str(target / "config.json")):
            logger.error(f"registry path EMPTY (no config.json): {raw}")
        else:
            logger.info(f"registry path ok: {raw}")

# --- final report -----------------------------------------------------------

oc_config = ROOT / "opencode.json"
dcp_config = ROOT / ".opencode" / "dcp.jsonc"
oc_text = oc_config.read_text() if host.get_fact(File, path=str(oc_config)) else ""

logger.info("--- enabled feature set ---")
logger.info("flash attention : built-in (mx.fast.scaled_dot_product_attention)")
logger.info(
    "log rotation    : "
    + ("daily via launchd" if host.get_fact(File, path=str(rotate_plist)) else "NOT installed")
)

markitdown = "markitdown" in (host.get_fact(Command, command="uv tool list") or "")
logger.info(
    "markitdown-mcp  : " + ("installed" if markitdown else "NOT installed")
)
logger.info(
    "tool parser     : gemma4"
    + (" + lenient-args repair" if patched else " (UNPATCHED)")
)

for name, want in (("markitdown", True), ("playwright", False)):
    if f'"{name}"' not in oc_text:
        logger.warning(f"mcp {name:<11}: absent from opencode.json")
        continue
    on = '"enabled": true' in oc_text.split(f'"{name}"', 1)[1][:60]
    msg = f"mcp {name:<11}: {'ENABLED' if on else 'disabled'}"
    logger.info(msg) if on == want else logger.warning(msg + " (unexpected)")

for pkg, label in (
    ("@tarquinen/opencode-dcp", "dynamic context pruning"),
    ("@dietrichgebert/ponytail", "ponytail"),
):
    if pkg in oc_text:
        logger.info(f"plugin          : {label} -> {pkg}")
    else:
        logger.warning(f"plugin          : {label} MISSING")

if host.get_fact(File, path=str(dcp_config)):
    logger.info("dcp config      : .opencode/dcp.jsonc (maxContext 24000)")
else:
    logger.warning("dcp config      : missing, DCP falls back to 100k defaults")

logger.info(
    "NOTE: opencode resolves plugins from the directory it runs in. Run it here, "
    "or copy opencode.json and .opencode/ alongside your project."
)
