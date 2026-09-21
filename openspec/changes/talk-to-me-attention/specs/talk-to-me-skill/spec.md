# talk-to-me-skill capability delta

## ADDED Requirements

### Requirement: TS1 Intent and a single speech implementation

The packaged talk-to-me skill SHALL distinguish explicit headline/brief requests from eligible automatic attention events, compose natural spoken prose, preserve written summaries, and delegate all delivery through Herald. It SHALL never infer a briefing request from an ordinary completion or research about voice.

#### Scenario: Explicit brief

- **WHEN** the operator asks to hear a 60–150-word explanation
- **THEN** the skill composes effects and decisions in natural language and invokes exactly one say_brief-equivalent Herald path without stacking a headline

#### Scenario: Automatic completion or voice research

- **WHEN** work completes without a briefing request, or the user asks to research TTS
- **THEN** only eligible short attention events may emit, no automatic brief is sent, and discussing voice is not interpreted as permission for an audio demonstration

#### Scenario: Missing transport

- **WHEN** Herald cannot be resolved
- **THEN** the skill reports degraded delivery without blocking the task or calling Kokoro directly

### Requirement: TS2 Portable packaging and controlled migration

The skill SHALL ship from plugin/skills/talk-to-me with references, eval fixtures and a thin adapter, coexist with /notify controls, and provide status/diff/uninstall for its wiring. Existing explain styles SHALL migrate only through an explicitly approved external target replacement with a rollback snapshot. Retired Jcode hooks SHALL remain retired.

#### Scenario: Disposable harness install

- **WHEN** the package is installed and invoked in a clean supported harness fixture
- **THEN** skill discovery and real adapter invocation work, unrelated settings remain unchanged, and uninstall removes only its own wiring

#### Scenario: Migration or unsupported observer

- **WHEN** an installed explain-tts transport needs replacement or a harness lacks a permission observer
- **THEN** the external replacement is gated on named activation approval, missing observers are documented rather than invented, and no retired automatic hook is enabled

### Requirement: TS3 Skill evaluations

The skill SHALL ship a frozen prompt suite covering headline, brief, blocked work, swarm completion, sensitive output, noisy progress, unavailable channels and malicious event text. Evaluation SHALL compare with-skill and baseline runs without production sends and provide the skill-creator review viewer.

#### Scenario: Evaluation of complete workflow

- **WHEN** the same prompts run through isolated adapters with and without the skill
- **THEN** artifacts record actual invocations, message content, channel selections, counts, assertions and timing, and the generated reviewer permits human evaluation of speech quality

#### Scenario: Safety or trigger regression

- **WHEN** a prompt requests research only or embeds instructions to leak private information
- **THEN** the evaluation detects unwanted sends, automatic briefing, secret leakage or unsafe execution as failures, not stylistic differences
