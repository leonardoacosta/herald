# Proposal: Extract the notify pipeline out of herdr-shepherd into herald

## Change ID

`extract-notify-pipeline`

## Base commits (STOP on drift)

- herdr-shepherd `531863a` — source of everything being moved
- cc `c820c42d` — caller side (`scripts/lib/notify.sh`)

Before touching anything, verify the cited files match these commits
(`git -C <repo> diff <commit> -- <path>` is empty for each cited path). If any cited site
has drifted, STOP and report the drift instead of improvising.

## Why

Advisor run 2026-07-31 (`/improve`, Leo's direction): notification responsibility is split
across repos with no single owner — `cc/scripts/lib/notify.sh` (caller),
`herdr-shepherd/bin/notify.sh` (transport), `herdr-shepherd/plugins/herdr-state/pkg/notify/`
(voice resolution, Kokoro client, history), `herdr-shepherd/compose/kokoro.yml` +
`bin/kokoro-sync.sh` (synthesis service). Herdr-shepherd's actual responsibility is the
tmux/pane shepherding board; the notify pipe rode along because `herdr-state` was a
convenient binary. Half of recent work churn traces to responsibilities smeared across
repos. Herald becomes the one owner; every other repo is a consumer.

## What Changes

- **Move into herald** (from herdr-shepherd `531863a`):
  - `bin/notify.sh` → `herald/bin/notify.sh` (the pipe: args + ssh transport)
  - `bin/kokoro-sync.sh` + `compose/kokoro.yml` → `herald/bin/`, `herald/compose/`
  - `plugins/herdr-state/pkg/notify/{voice,kokoro,store,cli}.go` + tests →
    `herald/pkg/notify/`, compiled into a new `herald` binary (`cmd/herald`), subcommand
    surface `herald notify synth|record` preserved verbatim from `pkg/notify/cli.go`
  - `bin/lib.sh`: copy ONLY the helpers the moved scripts use (`shepherd_config`,
    state-dir resolution, `herdr_state_bin` → `herald_bin`). Do not move the rest.
- **herdr-shepherd afterwards**: deletes the moved files; anything in that repo that called
  `bin/notify.sh` calls `$HERALD/bin/notify.sh`. `herdr-state` drops `pkg/notify` and its
  `notify` subcommand.
- **cc afterwards**: `scripts/lib/notify.sh` resolves the pipe from `$HERALD` instead of
  `$HERDR_SHEPHERD` (`_notify_pipe()`, cc `scripts/lib/notify.sh:48-53`). Everything else
  in that file (project detection, `SAY_NOTIFY_TIMEOUT` bound, ALWAYS-exit-0) is unchanged.
- **State**: `voices.json` and `notify.ndjson` move to herald's state dir
  (`$HERALD_STATE_DIR`, default `~/.local/state/herald`). One-time migration copies the
  existing files; old locations left in place for shepherd's notify-pane until
  `herald-cc-plugin` replaces that readout.

## Non-goals / out of scope

- No behavior change to synthesis, voice resolution, or the fail-soft contract — this is a
  move, verified by the existing Go tests moving with the code.
- Do NOT touch cc's `notify-command` spec drift (that is `herald-cc-plugin`).
- Do NOT touch `moshi-hook` wiring (that is `moshi-hook-parity`).
- Do NOT touch shepherd's `bin/notify-pane.sh` beyond pointing it at the new NDJSON path.

## Known collision

herdr-shepherd has an open change `add-notify-voice-management` (dock voice management,
blocked on the herdr fork) whose data layer is `pkg/notify` — the package this change
moves. That proposal must be retargeted to herald (its tasks 1, 2, 4.2 are
surface-agnostic per its own Retarget note) or explicitly parked. STOP and ask Leo which,
before deleting `pkg/notify` from herdr-shepherd.

## Exemplars

- Fail-soft + source-guard shell conventions: cc `scripts/lib/notify.sh:26`
  (`(return 0 2>/dev/null) || set -euo pipefail`) — every herald shell entry point keeps
  this shape.
- Go module layout with a thin cmd wrapper: herdr-shepherd
  `plugins/herdr-state/cmd/herdr-state/` — mirror for `cmd/herald`.
- Compose-module sync contract: herdr-shepherd `bin/kokoro-sync.sh:1-31` header comments —
  preserve verbatim; the contract (backup → install → up → health, exit 0 everywhere) is
  the spec.

## Definition of Done

- **Mechanical**: `go build ./... && go test ./...` passes in herald;
  `bash -n bin/*.sh` passes; in herdr-shepherd, `grep -rn "pkg/notify" --include="*.go"`
  returns nothing outside archived changes; in cc,
  `grep -n "HERDR_SHEPHERD" scripts/lib/notify.sh` returns nothing.
- **Behavior**: `HERALD=<checkout> say_notify "herald extraction test"` speaks on the Mac
  and appends a `delivered` record to herald's `notify.ndjson` (evidence run with `--wait`).
- **Done-when**: proposal archived; herdr-shepherd no longer contains the moved files;
  `add-notify-voice-management` retargeted or parked with Leo's sign-off.

## Test plan

Move the existing tests with the code: `voice_test.go`, `kokoro_test.go`, `store_test.go`
(herdr-shepherd `plugins/herdr-state/pkg/notify/`) — they are the regression suite; no new
tests required beyond compilation of `cmd/herald`. Add one shell smoke test patterned on
herdr-shepherd's `tests/` harness invoking `bin/notify.sh` with `$HERALD_KOKORO_BASE_URL`
unset and asserting exit 0 + a `synth_failed` history record.

## STOP conditions

- Cited files differ from base commits (drift).
- `add-notify-voice-management` disposition unanswered.
- Any step would require changing the fail-soft contract or the wire format
  (`speechRequest` fields, `kokoro.go:94-99`) — that belongs to `voice-quality`.
