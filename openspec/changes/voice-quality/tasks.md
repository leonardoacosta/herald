# Tasks — voice-quality

## 1. Engine parameters

- [ ] 1.1 `pkg/notify/kokoro.go`: add `Speed float64` and
      `NormalizationOptions *NormalizationOptions` to `speechRequest`, both
      `json:",omitempty"`-safe (zero value serializes away). Verify: existing
      `kokoro_test.go` marshalling assertions still pass byte-identical for the
      unconfigured case; new assertions cover the configured case.
- [ ] 1.2 `pkg/notify/voice.go`: extend voices.json schema with optional per-entry
      `speed`; resolution carries it (default 0 = engine default). Blend voice values
      pass through with provider prefix stripped. Verify: new `voice_test.go` cases —
      legacy file, speed file, blend value.
- [ ] 1.3 History records include the effective speed/voice actually sent. Verify:
      `store_test.go` extended case.

## 2. Audition + default

- [ ] 2.1 Script one audition run (fixed paragraph, candidates: `af_heart`,
      `af_bella`, `af_nicole`, one blend, speeds 0.9/1.0) via `--wait`; Leo picks.
      Verify: chosen default written to `voices.json` with rationale in the commit body.

## 3. Speakable text

- [ ] 3.1 Amend the tts-summary output style: `say_notify` argument = one natural
      sentence, jargon expanded; written Summary block rules unchanged; add 3
      before/after examples. Verify: the file's rule table renders and the examples
      contradict no existing row.
- [ ] 3.2 Sweep cc for hardcoded spoken strings that violate the rule
      (`grep -rn "say_notify \"" scripts/hooks/ commands/` at cc `c820c42d` — e.g.
      `stop-failure.sh:66`, `telemetry.sh:1801` bodies) and rephrase the templates.
      Verify: grep list reviewed; each remaining literal is a full sentence.

## 4. Evidence

- [ ] 4.1 A/B recording: same text, old vs new config, both history records cited in
      the PR. Leo confirms the new default is audibly better before archive.
