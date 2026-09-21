# Jcode wiring

Herald's Jcode harness adapter. Jcode consumes herald's pipe the same way cc consumes
the CC plugin: herald owns the notification capability, Jcode only fires the events.

## Install

```bash
$HERALD/plugin/jcode/install.sh            # retired: report a no-op
$HERALD/plugin/jcode/install.sh --status   # what is wired vs what this repo ships
$HERALD/plugin/jcode/install.sh --remove   # drop only herald's entries
```

The automatic installer is retired. Its default invocation is a byte-identical no-op.
Use `--remove` only to clean entries from older deployments. It edits the `[hooks]`
table in `~/.jcode/config.toml` (override with `JCODE_CONFIG`) and preserves unrelated
wiring, including `jcode-herdr-agent-state.sh`.

`--remove` and `--status` fail loudly when the existing `[hooks]` table cannot be
parsed safely. Removal leaves that configuration untouched on failure. The default
invocation does not parse or modify configuration.

## Legacy wiring table

These adapters describe older installations. The retired installer does not enable them.

| Jcode event | Herald script | Default |
|---|---|---|
| `turn_end` | `plugin/jcode/hooks/turn-end.sh` | on (duration-gated) |
| `session_end` | `plugin/jcode/hooks/session-end.sh` | **off** (`HERALD_JCODE_SESSION_END=1`) |
| `session_start` | — | not wired (no attention value) |
| `pre_tool` / `post_tool` | — | not wired (gating is policy, not attention) |

`session_end` is default-off because Jcode sessions open and close far more often than
cc sessions; the default must not be noisy.

## Env knobs

| Variable | Default | Meaning |
|---|---|---|
| `HERALD` | this repo (derived from the script path) | herald root; the adapter no-ops silently if the pipe is missing |
| `HERALD_JCODE_MIN_TURN_MS` | `30000` | minimum `JCODE_HOOK_DURATION_MS` before a turn is worth speaking |
| `HERALD_JCODE_SESSION_END` | `0` | `1` enables the session-close notification |
| `HERALD_JCODE_TIMEOUT` | `15` | seconds bounding the `bin/notify.sh` delegation |

Everything else (voice, project, service URL, state dir, mute) resolves through the
normal herald config chain; the adapter adds no configuration of its own.

## Control surface from a Jcode session

There is no `/notify` command to install — the control surface is the existing CLI:

```bash
$HERALD/bin/herald notify status      # service/config state
$HERALD/bin/herald notify history     # recent attempts (the debugging surface)
$HERALD/bin/herald notify mute        # and: unmute
$HERALD/bin/herald notify voices      # voice readout; `set` / `reset` to change
$HERALD/bin/notify.sh --wait "test"   # round-trip through playback, evidence capture
```

Jcode sets `JCODE_HOOKS_DISABLED=1` in every hook process, so a hook script may safely
shell out to the `jcode` CLI without re-triggering hooks. Conversely, hook scripts get
no TTY and must not assume one, and they must not depend on the session cwd
(`JCODE_HOOK_CWD` carries it explicitly).

## Parity matrix

| Capability | cc | Jcode | Note |
|---|---|---|---|
| Turn/stop attention event | yes (`Stop`) | yes (`turn_end`) | Jcode adds a duration gate |
| Session close | yes | yes, default-off | frequency difference |
| Tool-level observation | wired for policy elsewhere | not wired | out of scope: attention only |
| Ask / permission prompt | yes (`Notification`) | **platform limit** | Jcode has no ask/permission observer event today; recorded, not a task |
| Mobile push (Moshi) | via `moshi-hook` | not wired | owned upstream by `moshi-hook install --target jcode`, not hand-wired here |
| Briefings (`say_brief`) | explicit-only | explicit-only | never fired from a hook |

## Fail-soft contract

Both adapter scripts exit 0 on every path and bound their delegation with `timeout`.
Jcode's observer hooks are already detached fire-and-forget (failures are only logged
and can never block a turn), so this is belt-and-braces rather than a requirement on
Jcode. The adapter carries no speech implementation: it delegates to `bin/notify.sh`,
which keeps the service-first path and its fallback guarantee unchanged.

## Follow-ups (out of scope here)

- `herald notify mute` accepts no duration argument comparable to the CC `/notify mute`
  ergonomics; parity, if wanted, is a separate change.
- No Moshi/mobile leg for Jcode (see the matrix above).
