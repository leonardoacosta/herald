#!/usr/bin/env bash
# install.sh — wires herald's Jcode hook adapters into ~/.jcode/config.toml.
#
# Usage:
#   install.sh            add/refresh herald's entries in the [hooks] table
#   install.sh --remove   drop only herald's entries; everything else intact
#   install.sh --status   report wired vs shipped
#
# OWNERSHIP: this installer owns herald's lines in Jcode's [hooks] table the
# same way `moshi-hook install` owns its entries elsewhere. Hand-edits to the
# herald entries are a defect; re-run this installer instead.
#
# Herald entries are appended as ADDITIONAL array members (Jcode accepts hook
# lists, see its docs/HERDR.md), preserving existing wiring such as
# jcode-herdr-agent-state.sh. A scalar hook value is converted to an array
# with the original value first.
#
# Unlike delivery, install is interactive: this script FAILS LOUD (nonzero
# exit) when it cannot parse the existing [hooks] table round-trip-safely,
# rather than guessing and corrupting operator config.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${JCODE_CONFIG:-$HOME/.jcode/config.toml}"
MODE="install"
case "${1:-}" in
  --remove) MODE="remove" ;;
  --status) MODE="status" ;;
  "") ;;
  -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "install.sh: unknown option: $1" >&2; exit 1 ;;
esac

TURN_END="$REPO/plugin/jcode/hooks/turn-end.sh"
SESSION_END="$REPO/plugin/jcode/hooks/session-end.sh"

[ -f "$CONFIG" ] || { echo "install.sh: no config at $CONFIG" >&2; exit 1; }

python3 - "$MODE" "$CONFIG" "$TURN_END" "$SESSION_END" <<'PY'
import sys, re, tomllib

mode, config_path, turn_end, session_end = sys.argv[1:5]
MARKER = "/plugin/jcode/hooks/"  # identifies herald-owned entries
OWNED = {"turn_end": turn_end, "session_end": session_end}

with open(config_path, "r", encoding="utf-8") as f:
    text = f.read()
lines = text.splitlines(keepends=True)

# Locate the [hooks] table.
start = end = None
for i, ln in enumerate(lines):
    stripped = ln.strip()
    if start is None and stripped == "[hooks]":
        start = i
        continue
    if start is not None and re.match(r"^\[", stripped):
        end = i
        break
if start is not None and end is None:
    end = len(lines)

def fail(msg):
    print(f"install.sh: {msg}", file=sys.stderr)
    sys.exit(1)

if start is None:
    fail(f"no [hooks] table found in {config_path}; add one first")

# Group the section body into logical lines (multi-line arrays by bracket
# balance), keeping non-entry lines (blank/comment) verbatim.
body = lines[start + 1 : end]
logical = []  # (kind, key, value, raw_lines)
i = 0
while i < len(body):
    ln = body[i]
    stripped = ln.strip()
    if stripped == "" or stripped.startswith("#"):
        logical.append(("raw", None, None, [ln]))
        i += 1
        continue
    raw = [ln]
    depth = ln.count("[") - ln.count("]")
    while depth > 0:
        i += 1
        if i >= len(body):
            fail("unterminated array in [hooks] table")
        raw.append(body[i])
        depth += body[i].count("[") - body[i].count("]")
    chunk = "".join(raw)
    try:
        parsed = tomllib.loads(chunk)
    except tomllib.TOMLDecodeError as e:
        fail(f"cannot round-trip-parse [hooks] line {chunk.strip()!r}: {e}")
    if len(parsed) != 1:
        fail(f"unexpected [hooks] line shape: {chunk.strip()!r}")
    key, value = next(iter(parsed.items()))
    logical.append(("entry", key, value, raw))
    i += 1

def fmt(key, value):
    if isinstance(value, list):
        inner = ", ".join(f'"{v}"' for v in value)
        return f"{key} = [{inner}]\n"
    if isinstance(value, str):
        return f'{key} = "{value}"\n'
    if isinstance(value, bool):
        return f"{key} = {str(value).lower()}\n"
    return f"{key} = {value}\n"

def as_list(value):
    return list(value) if isinstance(value, list) else [value]

if mode == "status":
    print(f"config: {config_path}")
    for key, want in OWNED.items():
        current = None
        for kind, k, v, _ in logical:
            if kind == "entry" and k == key:
                current = as_list(v)
        wired = current is not None and want in current
        others = [c for c in (current or []) if MARKER not in c]
        state = "wired" if wired else "NOT wired"
        print(f"  {key}: {state} (ships {want}; other entries: {others or 'none'})")
    sys.exit(0)

out_body = []
seen = set()
for kind, key, value, raw in logical:
    if kind == "raw" or key not in OWNED:
        out_body.extend(raw)
        continue
    seen.add(key)
    entries = as_list(value)
    kept = [e for e in entries if not (isinstance(e, str) and MARKER in e)]
    if mode == "install":
        kept.append(OWNED[key])
    if kept == entries:
        # Semantics unchanged (already wired, or nothing herald-owned to
        # drop): keep the original bytes verbatim. This is what makes a
        # second install byte-identical to the first.
        out_body.extend(raw)
        continue
    if not kept:
        continue  # drop the key entirely (remove mode, herald was sole entry)
    # Shape: an entry that ends up with exactly one command is written as a
    # scalar, which is how Jcode's own default config writes it — so
    # `--remove` restores a scalar fixture byte-for-byte. A single-element
    # array in the source is therefore normalised to a scalar on removal;
    # semantically identical to Jcode, and the installer only ever rewrites
    # a line whose herald membership actually changed.
    out_body.append(fmt(key, kept if len(kept) > 1 else kept[0]))

if mode == "install":
    additions = [fmt(k, [OWNED[k]]) for k in OWNED if k not in seen]
    if additions:
        # insert before any trailing blank lines of the section
        idx = len(out_body)
        while idx > 0 and out_body[idx - 1].strip() == "":
            idx -= 1
        out_body[idx:idx] = additions

new_lines = lines[:start + 1] + out_body + lines[end:]
new_text = "".join(new_lines)

# Round-trip safety: the result must still parse, and non-herald hook
# entries must be exactly preserved.
try:
    before = tomllib.loads(text).get("hooks", {})
    after = tomllib.loads(new_text).get("hooks", {})
except tomllib.TOMLDecodeError as e:
    fail(f"internal error: rewrite produced invalid TOML: {e}")
for key in set(before) | set(after):
    b = [e for e in as_list(before.get(key, [])) if not (isinstance(e, str) and MARKER in e)]
    a = [e for e in as_list(after.get(key, [])) if not (isinstance(e, str) and MARKER in e)]
    if b != a:
        fail(f"internal error: non-herald entries for {key} would change ({b!r} -> {a!r}); aborting")

if new_text != text:
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print(f"install.sh: {mode}: updated {config_path}")
else:
    print(f"install.sh: {mode}: no changes needed")
PY
