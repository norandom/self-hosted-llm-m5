# --- PATCH: lenient-args-repair (applied by apply-patch.sh) ---
#
# vllm-mlx's Gemma 4 tool parser expects string values delimited by the literal
# <|"|> token. The model intermittently emits plain "-quoted values instead, and
# when one contains unescaped inner quotes -- newString: "echo "new"" -- the
# conversion yields invalid JSON, _extract_canonical() returns NO tool call, and
# the client waits forever for a call that never arrives.
#
# This repair runs ONLY after the original conversion has already failed, so it
# cannot regress input that currently works. Scope: flat argument objects, which
# is the shape of every opencode tool. Nested objects fall through unchanged.

_PATCH_ORIG_ARGS_TO_JSON = _gemma4_args_to_json
_PATCH_KEY_RE = re.compile(r'"?([A-Za-z_][A-Za-z0-9_]*)"?\s*:\s*')
_PATCH_LITERALS = {"true", "false", "null"}


def _patch_repair_flat_object(text: str) -> str | None:
    """Rebuild a flat {k: v} object, re-escaping plain-quoted values.

    Values are delimited by scanning to the next key rather than by trusting
    quotes, which is what lets unescaped inner quotes survive.
    """
    s = text.strip()
    if not (s.startswith("{") and s.endswith("}")):
        return None
    body = s[1:-1]

    keys = list(_PATCH_KEY_RE.finditer(body))
    if not keys:
        return None

    out = {}
    for i, m in enumerate(keys):
        name = m.group(1)
        end = keys[i + 1].start() if i + 1 < len(keys) else len(body)
        raw = body[m.end():end].strip()
        raw = raw.rstrip(",").strip()          # trailing separator before next key
        if not raw:
            return None
        if raw.startswith("{") or raw.startswith("["):
            return None                        # nested: out of scope, bail
        low = raw.lower()
        if low in _PATCH_LITERALS:
            out[name] = {"true": True, "false": False, "null": None}[low]
            continue
        if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
            raw = raw[1:-1]                    # strip the outer quotes only
        out[name] = _patch_decode_value(raw)
    return json.dumps(out)


def _patch_escape_bare_quotes(s: str) -> str:
    """Escape only the " characters that are not already escaped, leaving every
    other backslash sequence intact so \\n stays a newline escape rather than
    becoming a literal backslash-n."""
    buf, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            buf.append(s[i:i + 2])
            i += 2
            continue
        buf.append('\\"' if c == '"' else c)
        i += 1
    return "".join(buf)


def _patch_decode_value(raw: str):
    """Decode a plain-quoted value's contents, preserving JSON escapes.

    Order matters: decode as-is first (values that were already correctly
    escaped), then retry with bare inner quotes escaped. Only if both fail do we
    fall back to the literal text — and that last case is the one that would
    turn \\n into a literal backslash-n, so it is deliberately last.
    """
    for candidate in (raw, _patch_escape_bare_quotes(raw)):
        try:
            return json.loads(f'"{candidate}"')
        except (json.JSONDecodeError, ValueError):
            continue
    return raw


def _gemma4_args_to_json(text: str) -> str:  # noqa: F811  (deliberate override)
    converted = _PATCH_ORIG_ARGS_TO_JSON(text)
    try:
        json.loads(converted)
        return converted                        # original path worked: unchanged
    except (json.JSONDecodeError, ValueError):
        pass

    for candidate in (text, _patch_repair_flat_object(text)):
        if not candidate:
            continue
        try:
            json.loads(candidate)
            logger.info("Gemma 4 tool parser: recovered args via lenient repair")
            return candidate
        except (json.JSONDecodeError, ValueError):
            continue

    return converted                            # let the caller raise as before
# --- END PATCH: lenient-args-repair ---
