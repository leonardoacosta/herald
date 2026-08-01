# notify-pipeline Spec Delta — voice-quality

## ADDED Requirements

### Requirement: Voice configuration supports prosody parameters

`voices.json` SHALL support optional per-project and default `speed` and blend voice
expressions; absent fields SHALL preserve today's behavior byte-for-byte on the wire.

#### Scenario: Legacy configuration untouched

- **WHEN** a voices.json entry has only a voice string
- **THEN** the synthesized request body is identical to the pre-change wire format

#### Scenario: Blend passes through

- **WHEN** a project's voice is `kokoro:af_heart+af_bella(2)`
- **THEN** the request's `voice` field is `af_heart+af_bella(2)` and a service rejection
  surfaces the payload snippet in the `synth_failed` reason

### Requirement: Spoken lines are prose

The spoken notification text contract SHALL require one natural conversational sentence
with speech-hostile abbreviations expanded; written summary density rules SHALL NOT apply
to the spoken line.

#### Scenario: Jargon expanded

- **WHEN** a completion event mentions a pull request and e2e tests
- **THEN** the spoken line says "pull request" and "end to end", not "PR" and "e2e"
