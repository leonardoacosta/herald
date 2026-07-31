# Tasks — deep-briefings

## 1. Pipe support

- [ ] 1.1 Measure: synthesize 60 / 100 / 150-word texts on the deployed Kokoro (cold +
      warm), record timings in the PR. STOP if 150 words cold exceeds 60s.
- [ ] 1.2 Add `say_brief` to the plugin lib (same file as `say_notify`): raised default
      bound (60s), otherwise identical contract. Verify: shell test — long text + Kokoro
      down → exit 0 fast, `synth_failed`; Kokoro up → exit 0, `delivered`.
- [ ] 1.3 Confirm `store.go` handles long text (cap recorded text ~300 chars if verbatim).
      Verify: store test with 150-word input.

## 2. Command + trigger

- [ ] 2.1 Add `brief [topic]` to `plugin/commands/notify.md`: composition rules (60–150
      words, spoken register, outcome/why/decisions/next), then `say_brief`. Verify:
      `/notify brief` in a live session speaks a complete digest.
- [ ] 2.2 Add the "brief me" trigger rule to the tts-summary output style with the
      explicit-only warning (never from hooks/Stop). Verify: rule present; cc
      `grep -rn say_brief scripts/hooks/` empty.

## 3. Evidence

- [ ] 3.1 One recorded session: "brief me" → digest spoken → history record cited. Leo
      confirms usefulness before archive.
