# Phone speech experiment

## Status

Approved for implementation on 2026-09-21, alongside its parent talk-to-me-attention.
Covers F14, the requested experimental automatic phone speech capability. The activation
boundary in this proposal still governs live device operations: implementation proceeds,
but device trials need the operator to complete P01, and P03 names any OS automation
before installing it. This is a dependent boundary, not a claim that ntfy attachments
autoplay. No two-way microphone interaction is included.

## Dependency and scope

Depends on talk-to-me-attention T01/T02/T03/T04/T06/T08 and its versioned attention/policy interfaces.
Do not require Jev enforcement or wait for the entire parent proposal to archive.
Implement a capability probe, delivery/receipt reporting and one selected device adapter
if the trial establishes a supported route. Retain listen-later audio plus text on every
platform where automatic speech cannot be verified. Synthesis stays exclusively in Herald.

## Product decisions

Automatic phone speech is opt-in per device and off by default. It obeys mute, quiet hours,
headphones/privacy policy, expiration and per-event deduplication. It never creates an
automatic long briefing. A phone clip requires the same accepted event identity as other
channels. No custom public relay or new mobile application is authorized by this proposal.

Investigate installed ntfy client capabilities and existing OS-supported automation on the
operator-selected device. Prefer playback of the Herald-synthesized artifact over device TTS
so there is no second synthesis implementation. If only built-in TTS is available, record
that as an architectural conflict requiring a later explicit proposal, not a silent bypass.

## Activation boundary

P01 requires the operator to name OS/version/device and approve a disposable topic, harmless
message, app/automation changes, and locked-device test window. Inspect existing client and
network capability read-only first. A separate P03 activation approval names any proposed
OS automation and permissions before installing it. Never reset passwords or bypass OS DND.
Missing target/access leaves this change blocked at P01, independent of the parent rollout.

## Acceptance and failure dispositions

Test foreground, background, locked screen, quiet/DND, offline/reconnect, expired clip,
duplicate delivery and unavailable synthesis. Record OS/app versions, network/VPN state,
event IDs, observed speech or absence, and receipt evidence. HTTP publish success is not
an audio receipt. At least three repetitions per supported state, no overlapping or duplicate
clips. A successful automatic speech trial needs observed speech within 15 seconds of
publication in the supported connected states and zero speech in forbidden states.

A clean unsupported result must describe the exact platform limitation, preserve working
text/listen-later behavior, and receive operator disposition before archival. It is not
permission to close the parent as having working phone autoplay.

## Capability and receipt contract

P02 exposes GET /attention/devices and `herald notify devices --json` with per-device
capability states unverified -> trial_ready -> verified|unsupported. Explicit revocation,
OS/client changes or missing required permissions move verified -> unverified and disable
autoplay. Discovery alone cannot move directly to verified.

Each event/device pair has a stable device_attempt_id derived from canonical event ID,
configured device identity and attempt ordinal. Receipt progression is published -> fetched
-> playback_started -> playback_finished, or failed|expired|uncertain. Ack is separate.
Automatic retry never increments the ordinal. Only an operator reconciliation operation
can authorize a new attempt. The device adapter durably claims the ID before playback and
rejects duplicates across push, OS automation callbacks and reconnect, including after
restart. Unknown post-crash playback remains uncertain pending operator reconciliation.
If an existing client cannot provide these guarantees, the route is unsupported.

The 15-second trial interval begins when the ntfy publish response is received and ends at
observed audible onset, measured by one trial observer's monotonic clock. Client/server
wall clocks are diagnostic only. Playback receipts are corroborated by actual observation,
not inferred from downloads. Trial records capture onset/finish and duplicate count. A
manual observer log is acceptable trial evidence but not a fabricated automated receipt.
The result matrix explicitly identifies which receipt stages are instrumented versus human
observed. Policy eligibility is rechecked at playback time through the private Herald
endpoint. If the device cannot recheck current policy or fetch its artifact while locked,
it must not play and cannot pass locked-state automatic speech acceptance.

Transport retries for one device attempt reuse the same device_attempt_id idempotency key;
they receive distinct diagnostic transport_try_id values which never influence playback
claims. Persist both the event/device attempt ordinal and the device's consumed-key set
through restart until event expiry plus the seven-day event retention window. Automatic
retry and reconnect reuse the persisted ordinal and key, never derive a fresh value from
process start. Only the authenticated operator resolve/retry operation can increment the
ordinal, with the same duplicate warning and authorization record as parent channel retry.
The device endpoint uses the parent's new control authentication and redacted record schema.
