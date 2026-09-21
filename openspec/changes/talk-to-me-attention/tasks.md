# Ordered implementation tasks

All boxes are pending implementation. Proposal authoring does not complete them. Task IDs
are local checklist references, not external tracking requirements. Shared-file work must
be reconciled against the worktree at execution start. No universal phases are implied.

## Foundation

- [ ] T01 [AR1, AR2, AR4; F04,F05,F09] Freeze JSON request/response fixtures and extend
  pkg/notify state + CLI seams with durable event identity, channel claims, history and
  bounded recovery. Add schema, concurrent-process, truncated-tail/interior-corruption,
  disk-full, idempotency/conflict and retention tests. Verify through built CLI JSON and
  real HTTP handlers plus process contention, not only internal struct tests.
- [ ] T02 [AR1, NC4; depends T01] Implement POST /attention admission and bin/notify.sh
  --event-file plus local --wait path. Verify actual subprocess exit codes and elapsed
  bounds, provider-stalled p95 acceptance, 400/409/503, no fallback after connection,
  process termination after channel claim, canonical-key golden fixtures, no duplicated
  attempt rows, JSON admission/channel uncertainty and alias lookup, conflict fixtures for
  every compared field, operator heard/dismiss/retry reconciliation through CLI and HTTP, and old
  POST /notify unchanged. Touch existing
  service/send/lifecycle code and tests/notify-service.test.sh only after reconciling edits.
- [ ] T03 [AR3, AR4; F06,F07; depends T01,T02] Implement deterministic event, coordinator,
  rate, TTL, coalescing, mute, quiet-hours and atomic policy controls. Verify real
  CLI policy validate/set/show, invalid edits, service/local parity and config divergence,
  DST edges, concurrent duplicate hooks, required-event floods, and global-mute all-channel
  behavior with a deterministic clock. Add scenario fixtures for every AR3 branch.

## Channels and communication skill

- [ ] T04 [NC1, NC2; F03,F08,F11; depends T02,T03] Implement configured ntfy text adapter,
  public-text rules, safe session resolver and independent bounded channel workers.
  Verify public wrapper -> real Herald HTTP -> local ntfy-compatible HTTP fixture with
  exact headers/body, origin/redirect rejection, response loss, 429/Retry-After, timeout,
  token-file permissions and partial channel success. Fixture checks are not live ntfy
  acceptance. Add real-server acceptance script for T12 without enabling it in CI.
- [ ] T05 [TS1, TS2; F01,F02; depends T02,T03] Package plugin/skills/talk-to-me and thin
  Herald-backed adapter, preserve /notify and voice controls, implement safe install preview,
  status/uninstall for skill wiring. Prepare explain-* migration documentation/adapter,
  not edits to installed external skills. Verify clean temporary HOME install, discovery,
  actual subprocess delegation, missing binary and shell-metacharacter inputs, byte-exact
  preservation of unrelated config, and retired Jcode installer no-op regression.
- [ ] T06 [NC3; F13; depends T04,T05] Add reusable synthesis artifact lifecycle and ntfy
  audio follow-up, existing voice/speed/blend resolution, file cleanup and expiry reporting.
  Verify text-before-audio despite stalled Kokoro, capped upload, remote rejection,
  canceled synthesis, temp-file cleanup, one serialized speech path and independent
  channel histories. Verify real ntfy attachment manual playback in T12.
- [ ] T07 [AR5; F10; depends T03,T04] Implement optional manual/macOS presence providers,
  capability detection, TTL and privacy restrictions. Verify CLI presence state and routing
  with current/stale/unknown focus/headphone fixtures, provider timeout, unsupported OS,
  manual override and absence of camera/mic/calendar access. Record actual macOS capability
  observations separately in T12 rather than assuming fixture parity.
- [ ] T08 [AR6; F12; depends T03,T04] Implement ack/defer controls and durable bounded
  reminders, scoped expiring action nonces, task-resolution supersession and private
  ntfy action compatibility fallback. Verify public CLI/HTTP ack twice, invalid/expired
  nonce issuance/hash storage/expiry/single-use and replay, two-event scope isolation,
  broad-token rejection, authorized retry, rate limits, unsupported device endpoint output,
  private Host/Origin rejection, disabled reminders, restart before due time, ack/reminder
  race, mute-at-send-time and pending local timers. Confirm no action approves agent tools.

## Jev and skill experiments

- [ ] T09 [JA1; F15; depends T03,T04] Implement a Go TypeSafe adapter using reviewed public
  API docs and local adapter patterns. Discover integration setup before using new APIs.
  Require pinned model, secure credentials, off/shadow/enforce config, validated probabilities,
  allowlisted 8 KiB state, 750 ms wall bound and deterministic fallback. Test via public
  `jev evaluate` and POST /attention against controlled HTTP fixtures, including wrong
  model, missing fields, NaN/range/sum errors, adversarial state and simultaneous outages.
- [ ] T10 [JA2; depends T09] Implement calibration/report tools, freeze >=200 labeled
  redacted events with task-isolated holdout, and compare rules, agent and Jev results.
  Obtain label review and explicit provider-call approval before the live evaluation.
  Record actual usage/latency and false positives/negatives. Enforce is gated on the exact
  model/policy pair, zero missed mandatory cases, no actionable-recall regression, >=20%
  relative unwanted-alert reduction and p95 <=750 ms. If blocked or failing, record evidence
  and retain shadow. Never mark enforce acceptance passed without that evidence.
- [ ] T11 [TS3; depends T05,T06,T08,T09] Author skill-creator evals JSON and isolated
  execution adapters, run with-skill and baseline prompts, grade objective behavior,
  aggregate benchmark and run eval-viewer/generate_review.py for human review. Cover
  speech/brief boundaries, complete swarm, permissions, privacy, noise, channel failure
  and hostile text. Improve and rerun failed cases. No eval emits production notifications.

## Integration acceptance and activation

- [ ] T12 [all AR/NC/TS requirements; depends T06,T07,T08,T09,T11] Run ./bin/verify.sh,
  go test -race ./..., go vet ./..., package tests and real socket/process acceptance.
  With explicit approval naming target speaker, subscribed device and disposable topic,
  run built CLI/pipe -> deployed Herald -> real Kokoro/player and real ntfy end-to-end.
  Observe one audible clip, subscriber text and manually playable attachment, expected
  mute/quiet behavior, safe navigation, ack on supported client or documented CLI fallback,
  partial failures and no duplicate after ambiguous response. Capture elapsed times,
  event/channel IDs and redacted history. Human hearing/phone receipt is distinct from
  HTTP publish success. Missing device access blocks live acceptance, not passed by mocks.
- [ ] T13 [deployment; depends T10,T12] Present calibrated routing and activation diff.
  Obtain target-specific permission for service-sync, new channel enablement, skill install
  and any external explain-* replacement. Back up existing config/skill, build binary,
  run bin/service-sync.sh, poll health and prove running build identity. Start with Jev
  shadow, enable enforce only after its gate. Verify rollback without deleting history,
  and preserve existing CLI fallback and Moshi permission UI. Phone autoplay is separately
  gated by phone-speech-experiment, not silently included in this activation.
- [ ] T14 [closure; depends T13] Map each requirement/scenario to fresh observed evidence,
  distinguish supported/unsupported/blocked capabilities, and archive only after acceptance
  or explicit operator disposition of remaining experimental gates. Update maintained
  specs/docs and preserve configuration rollback instructions.

## Feature traceability

| Features | Requirements | Tasks |
| --- | --- | --- |
| F01,F02 | TS1,TS2 | T05,T11,T12 |
| F03,F08,F11 | NC1,NC2 | T04,T12 |
| F04,F05,F09 | AR1,AR2,AR4 | T01,T02,T03 |
| F06,F07 | AR3,AR4 | T03,T12 |
| F10 | AR5 | T07,T12 |
| F12 | AR6 | T08,T12 |
| F13 | NC3,NC4 | T06,T12 |
| F14 | PS1,PS2,PS3 in dependent proposal | phone-speech-experiment P01–P05 |
| F15 | JA1,JA2 | T09,T10,T13 |

## Dependency graph

T01 -> T02 -> T03 -> {T04,T05}
T04 + T05 -> T06
T03 + T04 -> {T07,T08,T09}
T09 -> T10
T05 + T06 + T08 + T09 -> T11
T06 + T07 + T08 + T09 + T11 -> T12
T10 + T12 -> T13 -> T14
