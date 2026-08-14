# Tasks: jcode-native-integration

## 1. Verify runtime contract (STOP gate)

- [x] 1.1 Confirm the installed Jcode's `docs/HOOKS.md` still documents `turn_end` /
      `session_start` / `session_end` observers with `JCODE_HOOK_STATUS`,
      `JCODE_HOOK_LAST_ASSISTANT_TEXT`, `JCODE_HOOK_PAYLOAD`, and the
      `JCODE_HOOKS_DISABLED=1` recursion guard. Confirm `[hooks]` values accept arrays
      (per `docs/HERDR.md`). STOP and re-scope on mismatch.
- [x] 1.2 Snapshot the current `~/.jcode/config.toml` `[hooks]` table (herdr wiring) as
      the restore fixture for installer tests.

## 2. Adapter scripts

- [x] 2.1 `plugin/jcode/hooks/turn-end.sh`: threshold gate
      (`HERALD_JCODE_MIN_TURN_MS`, default 30000), skip on missing/empty
      `JCODE_HOOK_LAST_ASSISTANT_TEXT`, summary line from project dir name + status,
      delegate to `$HERALD/bin/notify.sh`, exit 0 on every path, bounded.
- [x] 2.2 `plugin/jcode/hooks/session-end.sh`: default-off
      (`HERALD_JCODE_SESSION_END=1` opt-in), same fail-soft shape.
- [x] 2.3 Shellcheck clean; no hardcoded hosts; no secrets in any output.

## 3. Installer

- [x] 3.1 `plugin/jcode/install.sh`: idempotent add/refresh of herald hook entries as
      array members in `[hooks]`, preserving existing entries; `--remove` drops only
      herald entries; `--status` reports wired vs shipped. Never touches other keys.
- [x] 3.2 Installer refuses to run if it cannot parse the existing `[hooks]` table
      round-trip-safely (fail loud at install time is fine — install is interactive,
      delivery is not).

## 4. Tests

- [x] 4.1 `tests/jcode-hooks.test.sh`: synthetic-env invocation of `turn-end.sh` —
      above-threshold produces one history record, below-threshold produces none,
      missing `$HERALD` exits 0 silently.
- [x] 4.2 Installer test against a fixture config: install twice → byte-identical;
      remove → restores fixture exactly.

## 5. Docs and doctrine

- [x] 5.1 `docs/jcode.md`: wiring table, env knobs, `herald notify` CLI usage from a
      Jcode session, Jcode-column parity matrix including platform limits (no
      ask/permission observer event).
- [x] 5.2 `openspec/project.md`: add Jcode row to the external-seams table.
- [x] 5.3 Record any discovered `herald notify` CLI gaps (e.g. mute parity) as
      follow-up items in the PR, not in-scope work.

## 6. Live acceptance

- [x] 6.1 Install on the workstation, run a real Jcode turn past the threshold, show
      the new `notify.ndjson` record and (if the playback host is up) the delivered
      outcome. Capture the evidence in the PR.
- [x] 6.2 Run `--remove`, confirm the herdr wiring is intact and no herald entries
      remain.
