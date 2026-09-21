# Design

## 1. Boundaries and alternatives

Selected: thin talk-to-me skill, Herald policy/delivery, optional direct Jev provider
adapter in Go. Alternative skill-only suppression is inconsistent across hooks and agents.
Alternative mandatory model routing adds latency and an external failure point to every
notification. Neither is selected. Reuse patterns from the local TypeSafe adapter rather
than importing its application server or introducing a required TypeScript runtime.

Ship the skill source under `plugin/skills/talk-to-me/`, with SKILL.md, references and evals.
Headline mode is one conversational sentence, normally <=25 words. Brief mode is 60–150
words, explicit-only. Existing voice/speed/blend controls and stop semantics remain the
only implementation. A thin bundled adapter may accept mode and structured event data,
but must delegate to bin/notify.sh. No direct Kokoro or player calls in skill scripts.

## 2. Public interfaces and compatibility

Keep POST /notify, say_notify and say_brief unchanged for legacy callers. Extend
bin/notify.sh with `--event-file PATH` (mutually exclusive with raw positional text) to
send the versioned envelope to POST /attention. `--wait` always runs the local execution
path for evidence. All send wrappers remain exit-0 and bounded: 15 seconds for ordinary
calls and the existing 60-second explicit briefing bound. Control/validation tools can
report errors without mutating state, as existing management tools do.

New management views: `herald notify attention history --json`, `policy show|validate|set`,
`presence show|set`, `ack ID`, `defer ID DURATION`,
`attention resolve ID --channel CHANNEL --disposition heard|dismiss|retry`, and
`jev status|evaluate|report`.
`jev evaluate` uses an explicitly supplied redacted fixture and never delivers a message.
`policy set` validates an input file atomically, never interpolates shell fragments.
HTTP counterparts: GET /attention/history, GET/PUT /attention/policy,
GET/PUT /attention/presence, POST /attention/ack, POST /attention/defer.
Also POST /attention/resolve exposes the same explicit reconciliation operation.
All remain loopback plus configured tailnet only. There is no public callback listener.
New state-changing HTTP controls require application/json, reject unexpected Host and
browser Origin values, emit no permissive CORS headers, and never mutate through GET.
The existing trusted-tailnet access model is retained, not expanded to public access.

POST /attention validates <=32 KiB of JSON, checks global mute, reserves capacity and
persists acceptance before returning 202 with event_id. It performs no provider calls.
Invalid input -> 400, full bounded queue -> 503, durable-store failure -> 503 plus health
counter. Rejected requests do not schedule delivery. A duplicate identical event returns
its existing canonical event ID/state with 200, a reused ID with different content returns 409.
A 503 returns rejected=true with no delivery ownership transfer. Once connected, the wrapper
still never falls back, even on that explicit rejection. Response loss is acceptance_unknown
in caller diagnostics, not a second server-owned event or a new legacy delivery record. HTTP
acceptance p95 target <100 ms in the local fixture while providers are stalled.

Envelope v1 fields:
- event_id (caller-generated UUID), source, session_id, task_id, revision (nonnegative int),
  project, kind (needs_decision|blocked|completed|progress|failed), origin (explicit|automatic),
  role (coordinator|worker), occurred_at, expires_at, requested_channels (speech|ntfy_text|
  ntfy_audio), speech_text, public_text, detail_ref, session_ref.
- IDs <=128 characters from letters/digits/._:-, timestamps RFC3339, text <=4096 UTF-8
  bytes each, refs <=1024 bytes, explicit boolean facts for recovery_in_progress and
  all_work_terminal. Unknown schema version, enum or oversized input is rejected.
- No URL, topic, voice-provider endpoint or host from an event controls a destination.
  References are opaque identifiers resolved against configuration, not arbitrary fetches.
- Missing canonical task/revision identity never triggers fuzzy cross-emitter suppression.
  Event UUID still deduplicates retries, and history records correlation_unavailable.

Service-unreachable fallback retains the existing connect-phase-only rule. New attention
state mutations and local execution share the same process-safe state implementation so
service and local claims cannot deliver the same event/channel concurrently. Explicit
nondefault remote service URLs with independent state cannot promise cross-host exactly
once. An ambiguous server response never causes local fallback or automatic resubmission.

## 3. State and delivery semantics

Add versioned attention state under HERALD_STATE_DIR using a bounded append-only journal,
a short OS advisory lock, and atomic snapshots (0600 files, 0700 directory). Persist
accepted -> classified -> suppressed|deferred|ready -> claimed -> terminal transitions.
No network or synthesis work occurs while holding the lock. Deferred capacity defaults
256 and event retention defaults seven days, configurable with validated bounds. Compact
under the same lock, recover a truncated final record, reject interior corruption, expose
a degraded health state, and do not silently replay uncertain deliveries.

Canonical dedupe key is SHA-256 of a length-prefixed UTF-8 tuple
(source namespace, session_id, task_id, kind, revision). Inline and adapter emitters for
one harness use the same configured source namespace and upstream-issued task/session IDs,
not process IDs, normalized paths or guessed summaries. Case is preserved. Tuple encoding
has golden cross-language fixtures. The first valid event UUID wins, subsequent UUIDs map
to that canonical ID in the same locked transaction. Different content on the same tuple is
a 409 conflict, not silently selected content. Shared state resides on the service host's
local filesystem with one configured user owner. Local fallback means that same host/state,
not shared NFS or an independent remote directory. Lock covers key lookup, capacity and
journal transition only. A duplicate HTTP submission may add a diagnostic transition but
never another logical event or physical-attempt history row.

Keep notify.ndjson's existing outcome vocabulary and one record per physical delivery
attempt. Add optional event_id/channel/attempt_id fields without breaking old readers.
Attention decisions, ntfy publish status and acknowledgments live in the attention ledger,
not invented legacy speech outcomes. A suppressed event is not a delivery attempt. New ntfy attempts map HTTP success to
legacy delivered with channel=ntfy_text|ntfy_audio, confirmed failure to transport_failed
or transport_timeout, and uncertain response to transport_timeout with reason=acceptance_unknown.
That channel outcome means transport accepted, not human receipt. Each real attempt has
one unique attempt_id row, even on partial delivery. Classification-only failures never
create a speech row. Existing raw speech callers keep their current record semantics.

Each channel claim is durable before side effects. On crash, a claimed operation with no
terminal evidence becomes uncertain, not automatically retried. Uncertain channels are prominently listed in attention history/status with a reconcilable
event ID, never silently dropped. The operator may mark heard, dismiss, or explicitly retry
that channel after being warned that it may duplicate playback. Retry mints a new attempt_id
under the same event and does not replay successful sibling channels. An unavailable service
never silently authorizes this retry. Successful ntfy HTTP means
published, never seen or heard. Queueing a speech clip is not receipt. Preserve existing
speech outcome terms but expose observed playback confirmation separately. One notification
can have partial channel success. Retrying failed text must not replay successful speech.

The service owns deferred/ack reminder timers, not a recurring agent or automatic briefing.
On shutdown stop admission, bounded-drain in-flight work, retain unexpired deferred events,
and record canceled/uncertain attempts honestly. On restart re-evaluate policy and expiry
before any unclaimed pending item. A local fallback may deliver immediately but leaves
future timers durably pending and visible as deferred_service_unavailable until service
returns. It never starts an unbounded detached scheduler.

## 4. Deterministic policy

Resolve global mute first, then operator channel restrictions, quiet/focus privacy rules,
event validity/expiry, exact duplicate state, worker/coordinator status, mandatory event
rules, rate controls, optional semantic classification and final channel selection.
A mandatory event bypasses semantic suppression and routine rate limits, never user mute
or an explicit channel prohibition. If every channel is prohibited, retain visibly with
reason, do not leak speech. Existing global mute applies to all new channels.

Defaults: progress silent, worker completion internal, coordinator completion only when
all_work_terminal=true, needs_decision and blocked notify once per state revision, failed
silent while recovery_in_progress=true unless it also needs a decision. Legacy raw calls
retain their behavior. Routine automatic events: maximum three per project per ten minutes,
excess coalesced to the latest revision. Required decision alerts have a separate ten per
minute safety cap, with an immediate overflow summary and no repeating flood. Explicit
operator requests are not semantically suppressed and do not consume routine budgets.

Quiet hours are optional IANA-timezone windows. During configured quiet/focus, speech is
disallowed and allowed text is low-priority. If no allowed text channel exists, defer until
the window ends or expiry. Global mute suppresses rather than replaying a backlog on unmute.
Routine default TTL 30 minutes, decision default TTL 24 hours, configurable. Resolve DST
using the selected timezone and test both repeated and nonexistent local hours.

Store rules in `${HERALD_CONFIG_DIR}/attention-policy.json`, selected through the shared
KEY=value config as HERALD_ATTENTION_POLICY_FILE. Both CLI and service load the same file
per event. Global policy -> project -> invocation channel restriction, with restrictions
intersected, never broadened by an event. Atomic invalid edits leave last valid policy in
service and local callers use a safe default with a visible configuration error. Status
reports effective policy hash. Compare caller policy path/hash and ntfy/Jev settings with
shared deployed config for default-service divergence, extending existing state/Kokoro
bypass checks. Secrets are compared by opaque local fingerprints, never displayed.

## 5. Channels, privacy and security

ntfy URL/topic/token-file are deployment config with no default external destination.
Disabled until configured. Token files are owner-readable only. Existing private no-auth
ntfy deployments remain supported, not silently reconfigured. Allow only the configured
origin, reject redirects, userinfo, header/control injection, arbitrary attachments and
request-provided destinations. HTTPS is required except an explicitly configured private
HTTP deployment. Tests use isolated loopback fixtures, not production endpoints.

ntfy text has title/project/kind, public_text and configured safe navigation. Standard text
uses default priority, quiet/deferred informational text uses low, decision alerts use high.
Do not override OS DND through urgent priority by default. POST bound 3 seconds, max response
64 KiB, one initial attempt. Retry only confirmed nonacceptance (connect failure or documented
rejection), at most two retries at 5 and 30 seconds within event TTL. Response loss after
connection is uncertain and is not retried. Honor Retry-After only within remaining TTL
and retry count. Speech and ntfy workers are independently bounded so stalled synthesis
cannot head-of-line block a decision text. The speech queue remains single-worker.

public_text is required for mobile output. For sensitive events use a fixed generic message
and opaque session link. No transcript, secrets, credentials, arbitrary file paths or raw
provider errors in history or push. Secret detection is defense in depth, not permission
to upload arbitrary content. Jev receives only allowlisted redacted summaries and facts.

ntfy audio reuses Kokoro-produced bytes and voice resolution, not a parallel synthesis
implementation. Text publishes independently first so a synth/upload error does not silence
an alert. Audio is an optional follow-up correlated to the same event and labeled
listen-later, no additional audible push by default. Limit clip bytes to 10 MiB and reuse
existing brief length bound. Private temp files are removed after upload or failure. Report
attachment expiry from server response when available, otherwise unknown. Downloadability
and actual playback are separate observations. No arbitrary local-file upload API.

Safe navigation resolves session_ref via configured scheme/origin templates. Reject
javascript/data/file URLs and raw commands. Unknown session -> show identifier without link.
A click opens the session only. Moshi approval and execution permissions remain unchanged.

## 6. Presence and user controls

Optional local presence providers report focused_session, quiet_mode, meeting and headphones
with source timestamp. Manual state works on every platform. macOS local capability probe
supports Focus/headphone state where available, without camera, microphone, calendar access
or new OS permission grants. Other platforms truthfully report unsupported unless tested.
Presence TTL 60 seconds. If unavailable, assume no permission for public speech when the
operator selected headphones-only, and use allowed text or defer. Do not infer that missing
presence means the operator is away. Status shows unknown/stale, not guessed availability.

Ack is an explicit operator CLI/control action or configured ntfy HTTP action that reaches
Herald over the private network. POST body carries event_id and expiring single-event nonce,
not executable instructions. A nonce cannot approve tools or alter other events. No secrets
in URLs. Duplicate ack is idempotent, expired or mismatched nonce is rejected. Action support
is capability-tested per client; unsupported clients retain CLI ack and safe open-session.

Optional reminders default off. When enabled, unacknowledged decision events may get two
reminders at 5 and 15 minutes. Recheck mute, expiry, supersession, focus and ack before each.
Acknowledgment cancels reminders, not running jobs. Defer supports 5m/15m/1h up to expiry.
A newer resolved task revision cancels old reminders. Delivery does not itself count as ack.

## 7. Jev integration

HERALD_JEV_MODE=off|shadow|enforce, default off. Explicit configuration permits provider
calls, shadow records suggestions without affecting routing. Endpoint is configured to the
TypeSafe public service, with origin validation and no redirects. Require a pinned concrete
model for shadow/enforce, not jev-latest. Credentials come from an owner-only token file,
never argv or the plain shared config. Bound each call to 750 ms including connect/read,
state to 8 KiB and response to 64 KiB. No retries in the decision path. On any failure,
fall back to deterministic policy and record a redacted reason. Jev is after HTTP acceptance.

Ask atomic questions: operator_decision_required (Noul), materially_new (Choice: new|repeated|uncertain), consequence
(Score), meaningful_completion (Choice). Use returned probabilities/confidence, not an extra
self-rated confidence question. Validate enum support, finite ranges, probability sums,
model identity and completeness. Independent answers can conflict: code resolves conflicts
conservatively to baseline, not the model. Counting, rate limits and deadlines stay in code.

Initial enforce authority: suppress only otherwise routine completion events where
P(materially_new=repeated) >=0.95 and novelty Choice confidence >=0.90, plus
operator_decision_required <0.05. Missing or conflicting required-action evidence uses
baseline routing. No suppression of explicit requests, needs_decision, blocked, or unrecovered
failure. Store the exact policy/model/version used with decisions and provide instant off.

Calibration fixture: >=200 human-labeled redacted events across projects, including >=50
required-action cases and >=30 adversarial/noisy cases. Freeze a 25% held-out split by task,
not individual repeated event. Compare rules-only, agent judgment and Jev. Report missed
required-action events, unwanted alerts per 100, duplicate rate, p50/p95/p99, cost from actual
usage and calibration error. Enforcement gate: zero missed mandatory cases, no regression
in human-labeled actionable recall versus baseline, >=20% relative reduction in unwanted
routine alerts (requires nonzero baseline), and p95 <=750 ms over the live evaluation.
Insufficient data or failed criteria leaves shadow enabled and enforcement blocked, not
claimed successful. Never send private production history without separate reviewed consent.

## 8. Packaging, migration and rollback

Install skill from the repo-owned package into a disposable harness first. Preserve user
preferences and existing plugin commands, no reactivation of retired Jcode hooks. Ship
explicit uninstall/diff/status paths for new skill wiring only. Existing explain-* styles
may delegate through the packaged adapter after named external activation approval. Back up
that installed skill before replacement; do not retain a live direct-Kokoro fallback.

Validate new configuration before deployment, then build and use bin/service-sync.sh so the
running artifact is refreshed. Live smoke requires chosen devices/topics and approval to
speak/push. Rollback first disables Jev enforcement, then new channels/attention adapters,
restores prior skill/config snapshot and restarts through the lifecycle owner. Preserve
existing legacy history and readable attention state. Do not roll back by deleting data.

## 9. Review clarifications: identity, receipt schema and control authority

Canonical equality compares every supplied v1 field except event_id and occurred_at.
Optional absent fields normalize to their documented schema defaults before comparison.
Arrays of requested_channels normalize to sorted unique enums; text is exact UTF-8 after
JSON decoding, with no whitespace or case folding. Source namespace uses configured adapter
mapping before comparison. expires_at and channel/text/reference changes conflict on the
same canonical key. Callers change revision for changed event intent. Policy changes are
not envelope fields and do not create conflicts: pending work uses current policy while
history retains each evaluated policy hash. Both duplicate 200 and conflict 409 return
canonical_event_id, supplied_event_id and admission state, so callers discover the winner.
Conflict responses never echo private event content. Golden fixtures cover every excluded,
normalized and compared field, including channel reorder versus channel-set change.

Public admission JSON is `{schema_version:1, supplied_event_id, canonical_event_id:null|ID,
admission:accepted|rejected|acceptance_unknown, retry_eligibility:never_automatic|
explicit_resubmit_allowed|reconcile_first, reason}`. A durable 202 and duplicate 200 use
accepted/never_automatic. Confirmed 400/409/503 use rejected/explicit_resubmit_allowed,
with corrections required for 400/409. They still never trigger automatic local fallback
once connected. A response lost after connection is caller-produced acceptance_unknown/
reconcile_first with nullable canonical ID. `herald notify attention lookup --event-id ID`
and GET /attention/events?event_id=ID resolve aliases and return the current event or
not_found. Not_found alone cannot prove remote nonacceptance during outages or retention
expiry and does not authorize automatic replay. Connect-phase-only failure remains the
existing bounded local fallback path, not an acceptance_unknown server attempt.

Per-channel JSON is `{channel, attempt_id, phase:pending|claimed|published|played|failed|
uncertain|canceled, failure_class:null|confirmed_nonacceptance|acceptance_unknown,
retry_eligibility:never_automatic|bounded_retry_allowed|operator_retry_only}`. Missing
provider confirmation is uncertain/acceptance_unknown/operator_retry_only. Confirmed
nonacceptance permits only the bounded retry budget. Published/played channels are never
automatically retried. Explicit retry warns of possible duplicate delivery and persists
operator authorization before minting the next attempt ordinal. Admission uncertainty is
separate from channel uncertainty. `bin/notify.sh --event-file` prints admission JSON when
`--json` is selected while retaining exit-0, and normal output remains compatible.

Control authority retains trust in the operator's local Unix account and configured tailnet
for legacy endpoints. New policy/presence mutations and resolve/retry require an explicit
owner-only control token file, with its bearer value in an Authorization header over the
configured trusted network, never a URL. CLI reads the file without printing it. New controls
are unavailable until configured rather than silently unauthenticated. Token comparison is
constant-time; missing or wrong credentials return 401 and make no state changes. Default
new-control request cap is 30/minute per authenticated principal, with 429 on excess. Do not
expose or log authorization values. New HTTP control clients follow the same configured
private-origin transport allowance as existing local/tailnet deployment; public transport
requires HTTPS and is not enabled by this proposal.

ntfy actions do not receive the broad control token. Herald mints a cryptographically random
256-bit nonce per event and permitted action (ack or defer only), bound to canonical event,
configured client identity and expiry=min(event expiry, issue+24h). Persist only a hash plus
scope. One successful action consumes its nonce transactionally; an exact repeated request
returns the original result, and different payload replay returns 409. No nonce permits
resolve/retry, policy changes or agent approval. Limit invalid action attempts to 10/minute
per source and 100/minute globally. Emit nonce only in the intended action body, not logs or
history. On the existing no-auth ntfy island all topic readers can see the action, so it is
a scoped bearer capability, not proof of a human/device identity. Mobile ack/defer is disabled
by default on unrestricted topics unless the operator explicitly accepts that trust boundary
or configures authenticated read restrictions. CLI acknowledgment remains available.

Parent reserves GET /attention/devices and `herald notify devices --json` for the dependent
experiment. Before that capability is implemented they return supported=false and an empty
device list. The device endpoint requires the new control credential and never exposes device
network addresses, action nonces or private artifact URLs. Device records expose only alias,
capability, version_fingerprint and last_verified_at. The PS1–PS3 contract owns implementation;
T08 verifies safe unsupported output and access rejection, and phone P02 verifies actual
capability and receipt transitions. New endpoints are included in origin/Host/privacy tests.
