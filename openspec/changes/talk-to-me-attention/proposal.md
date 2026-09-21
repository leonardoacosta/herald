# Talk-to-me: voice, mobile delivery, and attention routing

## Status and authorization

Approved for implementation on 2026-09-21: the operator approved "talk-to-me-attention"
and its dependent "phone-speech-experiment". This authorizes implementation of the
proposed features per the task order and external boundaries below. Live device
operations and external configuration changes remain governed by the separate activation
gates they define (phone speech P01/P03, ntfy via existing administration workflow,
explain-tts replacement as a named activation action). Previously on 2026-09-21 the
operator requested all previously researched P0, P1, and experimental features, including
ntfy and Jev integration, through `feature`. That authorized proposal preparation.

## Why

Agents need a shared way to communicate useful outcomes and requests without flooding the
operator. Herald already owns speech, voice selection, cancellation, history, and Moshi hook
wiring. Composition skills and ntfy currently sit outside that consistent delivery policy.
A useful voice requires both reliable delivery and selective interruption.

## Scope

| ID | Requested feature | Delivery boundary |
| --- | --- | --- |
| F01 | Short spoken announcements | Existing say_notify, new skill composition |
| F02 | Explicit spoken explanations and briefings | Existing say_brief, shared pipeline |
| F03 | Mobile text | Herald ntfy adapter |
| F04 | Event taxonomy | Versioned attention envelope |
| F05 | Cross-emitter deduplication | Durable event and channel claims |
| F06 | Swarm aggregation | Coordinator-only human completion |
| F07 | Quiet hours, mute, rate limits, channel/project preferences | Deterministic policy |
| F08 | Spoken and lock-screen privacy | Redacted channel-specific text |
| F09 | Decision observability | Attention ledger plus existing delivery history |
| F10 | Focus, meeting, headphone awareness | Optional bounded presence adapter |
| F11 | Safe session navigation | Configured deep-link resolvers |
| F12 | Acknowledgment and escalation | Explicit ack, bounded reminders |
| F13 | ntfy listen-later audio | Same Kokoro synthesis, attachment delivery |
| F14 | Automatic phone speech | Dependent phone-speech-experiment proposal |
| F15 | Jev semantic attention decisions | Off/shadow/enforce with calibration gates |

All P0/P1 features are implementation scope, not a shortlist. Experiments include real
implementations and acceptance trials, not documentation-only placeholders. F14 can finish
with a truthful unsupported-platform result and an implemented listen-later fallback, but
must not be represented as working automatic speech. Two-way microphone conversation was
marked "Later" in research and remains out of scope.

## Proposed behavior

The skill composes, Herald decides and delivers, and Jev optionally classifies ambiguity.
Explicit speech never becomes an automatic briefing. Existing notify callers retain their
contract. New attention envelopes add suppression, deferral, channels and correlation
without interpreting a transport failure as permission to retry accepted work.

## Dependencies and sequencing

Base inspected: a6e7ea7 (reliability follow-ups), including archived
`2026-09-21-audit-reliability-followups`. Its tests are evidence of hermetic reliability,
not live deployment. Existing working-tree changes in README.md, bin/notify.sh,
bin/service-sync.sh and pkg/notify/notify_e2e_test.go belong to other work and must be
reconciled before implementation touches them, not overwritten or claimed here.

Order: event/state contract -> policy -> channels and skill -> controls/presence -> Jev
shadow -> calibrated enforcement -> deployment acceptance. Phone speech depends on the
stable event, policy, ntfy attachment and receipt contracts, not on Jev enforcement.

`docs/jcode.md` and commit 51451e0 retire automatic hook installation. Preserve that
retirement. Do not install new automatic hooks or invent missing permission observers.

## External boundaries

- ntfy is configured by the operator through the existing ntfy-homelab administration
  workflow. No new server, ACL change, public topic or homelab compose edit is implicit.
- Jev is an external classification provider. Only redacted, allowlisted state leaves
  Herald, with explicit configured enablement. No production transcripts are trial inputs.
- Existing explain-tts installation is outside this repository. Ship a Herald-backed
  replacement adapter and migration instructions here. Replacing the installed transport
  is a separate activation action requiring the named target and rollback snapshot.
- Moshi remains owner of its approval UI. Notification acknowledgment never approves work.
- Phone application installation, OS permissions, push relay settings and locked-device
  trials belong to the dependent experiment and its explicit activation gate.

## Non-scope

Microphone capture, speech-to-text, wake words, general conversational voice agents,
production approval by notification buttons, model-driven rewriting of user preferences,
new cloud notification accounts, public exposure of Herald, and reactivating retired hooks.

## Acceptance

Every requirement has success and edge scenarios in the four spec deltas. `tasks.md` maps
features to executable checks. Public shell/CLI/HTTP acceptance must distinguish accepted,
published, played, and acknowledged. No package completion based only on source greps or
mocked delivery. Phone acceptance and Jev calibration remain separately visible gates.

## Research basis (retrieved 2026-09-21)

- https://github.com/PeonPing/peon-ping : deterministic noise controls and ntfy integration.
- https://github.com/disler/claude-code-hooks-mastery : composition and queued speech.
- https://docs.openclaw.ai/gateway/heartbeat : explicit no-notification decisions.
- https://docs.ntfy.sh/publish/ : priorities, actions, attachments, expiration.
- https://docs.ntfy.sh/config/#ios-instant-notifications : upstream wake and private fetch.
- https://docs.typesafe.ai/ : Choice/Score/Noul and independent typed questions.

These sources establish patterns, not measured effectiveness in this deployment. Local
Jev's typed adapter is implementation prior art, not a service dependency or approval to
transmit data. The local explain-tts transport is parallel prior art, not a second allowed
speech implementation for this feature.
