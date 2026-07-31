# Proposal: Make the voice pleasant and human-like — engine parameters + speakable text

## Change ID

`voice-quality`

## Depends on

`extract-notify-pipeline` (edits land in herald's `pkg/notify` and `voices.json` schema).

## Base commits (STOP on drift)

- herdr-shepherd `531863a` — the `pkg/notify` sources being extended (post-extraction the
  same code lives in herald; re-verify against herald HEAD then)
- cc `c820c42d` — `output-styles/tts-summary.md` (or its plugin location after
  `herald-cc-plugin`)

## Why

Advisor run 2026-07-31. Two independent causes of robotic output:

1. **Unused engine capability.** `kokoro.go`'s `speechRequest` (herdr-shepherd
   `plugins/herdr-state/pkg/notify/kokoro.go:94-99`) sends only
   `model/input/voice/response_format`. Kokoro-FastAPI also accepts `speed` (0.5–2.0),
   weighted **voice blending** (`af_heart+af_bella`, ratios normalized), and
   `normalization_options` (numbers, currency, URLs) — all absent from the wire request
   and from `voices.json`, which maps project → voice string and nothing else
   (`voice.go:37-39`).
2. **Telegraphic input text.** The `tts-summary` output style mandates fragments —
   "Grammar: Forgo for speed", "No greetings … 'the/a/and' when droppable"
   (cc `output-styles/tts-summary.md:66-74`). Those rules optimize the *written* summary
   block but also govern the spoken line, so the synthesizer is fed clipped fragments and
   unexpanded jargon ("PR", "e2e", "tRPC", repo codes) — robotic by construction,
   regardless of engine tuning.

## What Changes

- **voices.json schema**: per-project and default entries grow optional `speed` and keep
  the voice value, which MAY now be a blend expression passed through verbatim
  (`kokoro:af_heart+af_bella(2)`). Absent fields behave exactly as today.
- **`pkg/notify`**:
  - `speechRequest` gains `Speed float64` and `NormalizationOptions` (omitempty — absent
    fields must serialize away so the wire stays byte-compatible when unconfigured).
  - `Voice` resolution carries speed alongside provider/voice; history records include it.
  - Blend strings: strip the provider prefix, pass the rest verbatim to Kokoro — the
    service validates; on 400 the existing error path already surfaces the payload
    snippet (`kokoro.go:144-151`).
- **Speakable-text rule** in the tts-summary output style: the `say_notify` argument is
  exempted from the density rules — it MUST be one natural conversational sentence
  (subject, verb, article words allowed), with speech-hostile tokens expanded
  ("PR" → "pull request", "e2e" → "end to end", project codes → project names). The
  *written* Summary block keeps every existing density rule. Add 3 worked
  before/after examples to the style file.
- **Default voice audition**: pick the default (current `kokoro:af_heart`,
  `voice.go:23`) deliberately — audition top candidates and one or two blends at
  0.9–1.0 speed, record the choice in `voices.json`.

## Non-goals / out of scope

- No new synthesis provider (ElevenLabs path stays rejected, `kokoro.go:117-120`).
- No SSML — Kokoro-FastAPI does not speak it; phrasing improvements come from text.
- No changes to `bin/notify.sh` transport or timeouts.
- The GPU image swap for lower latency is a homelab capacity question — note it in
  `docs/`, do not do it here.

## Exemplars

- Adding a wire field with tests: `kokoro_test.go` (same package) — extend its
  request-marshalling assertions; do not write a new test file.
- Config parse with backward compat: `voice.go:50-59` `ParseQualified` — the
  bare-value/legacy rule shows the shape for "absent field = old behavior".
- Output-style rule table: cc `output-styles/tts-summary.md:64-74` — add the speakable
  row + examples in that table's format.

## Definition of Done

- **Mechanical**: `go test ./pkg/notify/` passes with new cases: (a) speed serialized
  when set, absent when zero; (b) blend string passes through verbatim minus provider;
  (c) voices.json with `speed` resolves; (d) legacy voices.json unchanged behavior.
- **Behavior**: A/B evidence run — same sentence synthesized with old config vs. blended
  voice + speed + normalization (`--wait`, both history records cited); a spoken line
  from a real session reads as a full sentence with jargon expanded.
- **Done-when**: proposal archived; default voice decision recorded in `voices.json` with
  a one-line rationale in the commit; output style carries the speakable-text rule.

## STOP conditions

- Cited `kokoro.go` / `voice.go` lines drifted from stamp.
- Kokoro rejects the blend syntax on the deployed image version — record the deployed
  tag + the 400 payload and report; do not upgrade the image inside this change.
