# Proposal: Voice-management data layer (retargeted from herdr-shepherd)

## Change ID

`voice-management-core`

## Provenance

Retarget of the surface-agnostic half of herdr-shepherd's open change
`add-notify-voice-management` (its own Retarget note marks sections 1, 2, 4.2
surface-agnostic). The dock UI half (its section 3) STAYS in herdr-shepherd as a slimmed
change consuming this change's CLI seams, still blocked on the herdr fork shipping
`placement = "dock"`. This split resolves `extract-notify-pipeline`'s STOP-gate 4.1.

## Depends on

`extract-notify-pipeline`. Coordinates with `voice-quality` (shared `voices.json` schema
and `WriteVoices` — see § Interaction).

## Base commits (STOP on drift)

- herdr-shepherd `531863a` — the source proposal + the pkg/notify code being extended
- herald — HEAD at execution time

## Why

Carried from the source proposal: `voices.json` is hand-edited; an operator cannot safely
discover valid Kokoro voices, see which projects inherit a fallback, or audition a voice
without hand-built requests. The data layer belongs to whoever owns `pkg/notify` — herald
after extraction.

## What Changes

Sections 1 and 2 of the source proposal's tasks, path-renamed
(`plugins/herdr-state/pkg/notify` → `pkg/notify`; `herdr-state notify` → `herald notify`):

- Effective-voice read model (stored value, effective qualified value, source:
  project/default/built-in) without changing `Resolve` precedence.
- Configured-endpoint Kokoro catalog client + validation for new `kokoro:<id>`
  selections; catalog access never required for read/resolve.
- Bounded fixed-text audition operation: constant sample, local playback only, never
  writes voice state, never appends notify history, never touches the playback host.
- Atomic persistence: same-directory temp file, mode 0600, sync, rename; failure leaves
  the prior file intact.
- Canonical project-code reader sharing `bin/lib.sh`'s configuration precedence.
- `herald notify` read/manage subcommands with stable JSON/line output for any UI
  surface. No arbitrary-text synthesis command.

## Interaction with sibling proposals

- **voice-quality**: extends the same `voices.json` schema (`speed`, blends) and touches
  `WriteVoices`. Sequencing: whichever lands second rebases; catalog validation MUST
  accept blend expressions by validating each component voice individually.
- **herald-cc-plugin**: `/notify voices` consumes this change's JSON seam instead of
  raw-rendering `voices.json`. If this change lands first, wire it; if not, the command
  notes the upgrade.
- **herdr-shepherd residual**: its slimmed change drops every pkg/notify Impact row,
  keeps dock rendering + docs, and declares a dependency on herald's CLI seams.

## Out of scope (carried verbatim from source)

Kokoro reachability policy, container hardening, web UI, multi-user authz, automatic
voice changes, arbitrary-text synthesis, any change to `bin/notify.sh`'s fail-soft
contract or CLI.

## Exemplars

- Read model + precedence: `pkg/notify/voice.go` `Resolve` (post-extraction) — the view
  model wraps it, never re-implements it.
- HTTP client shape + bounded timeout: `pkg/notify/kokoro.go` `NewClient` — the catalog
  client mirrors it.
- Test structure: `pkg/notify/voice_test.go` table tests.

## Definition of Done

- **Mechanical**: `go test ./pkg/notify/` passes with the source proposal's section 1–2
  test matrix (effective-source labeling, legacy preservation, catalog fixtures,
  atomic-write failure safety, audition no-write proofs); `herald notify voices --json`
  emits stable JSON.
- **Behavior**: against live Kokoro — catalog listing, one audition (no voices.json
  write, no notify.ndjson append), one override set + verified by
  `bin/notify.sh -p <project>`, one reset.
- **Done-when**: proposal archived; herdr-shepherd's residual change updated to consume
  the seams (its own repo, its own PR); `add-notify-voice-management` original marked
  superseded-in-part with a pointer here.

## STOP conditions

- Drift at stamp; extraction not yet landed.
- Blend-validation semantics unclear against the deployed Kokoro image — record the
  catalog response shape and report before implementing validation.
