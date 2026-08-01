package notify

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// The send path: `POST /notify {text, project}`.
//
// # Why this returns before the work is done
//
// proposal.md's whole "Request semantics" decision exists because synthesis
// measures 2.5-8.5s against say_notify's 15s caller bound. A synchronous
// handler that does resolve-voice -> synth -> deliver -> respond can still
// blow that bound on a cold Kokoro container or a slow ssh round trip; the
// caller then times out AFTER delivery already happened, falls through to
// bin/notify.sh, and the notification speaks twice. That is the double-send
// race `## STOP conditions` forbids outright.
//
// So HandleNotify does only three things before it writes a response:
// validate, resolve the current mute state, and hand a job to a bounded
// queue. Everything that can be slow — voice resolution's file I/O aside,
// which is fast — happens on SendQueue's single worker goroutine, entirely
// after the response has already gone out.
//
// # Why one worker, not one goroutine per request
//
// A goroutine-per-request design has no natural backpressure: a stuck
// playback host (AGENTS.md's own example — the resident player dies, ssh
// blocks for the full DefaultPlaybackTimeout) would let requests pile up as
// an unbounded set of goroutines and pending audio buffers, which is exactly
// the memory-leak shape this file's task explicitly forbids. A single worker
// draining a bounded channel caps the damage: at most one delivery is ever
// in flight, backlog is capped at the channel's capacity, and once it fills
// the handler refuses new work outright (see the `default` branch below)
// rather than growing without limit. The cost is throughput — bursts of
// notifications queue up rather than fanning out — which is the right trade
// for a personal attention channel where "one at a time, in order" is
// already this package's delivery contract (AGENTS.md "One voice at a
// time").
//
// # Why Synthesize and Deliver are both injectable
//
// Same convention as TailscaleIPResolver (service.go): a function type,
// defaulted to the real implementation when nil, so the slow-synthesis test
// this task requires (and the delivered/synth_failed/muted outcome tests)
// never have to reach a live Kokoro container or a real ssh transport to
// prove the queue's behaviour. Production callers (NewServer, via the single
// registration line in service.go) pass a zero-value SendQueueOptions and
// get the real thing.

// Synthesizer produces audio bytes for text spoken in v. Matches
// (*Client).Synthesize's signature exactly so the real implementation is a
// one-line wrapper, not a reimplementation.
type Synthesizer func(ctx context.Context, text string, v Voice) ([]byte, error)

// DeliverFunc ships the audio at path to the playback host. Narrower than
// Deliver itself (no DeliveryConfig parameter) because the config —
// playback host and timeout — is deployment-configuration the default
// implementation resolves per call from the environment (see
// resolvePlaybackConfig), exactly as ResolveBaseURL is read fresh by every
// caller rather than captured once at construction time.
type DeliverFunc func(ctx context.Context, audioPath string) (DeliveryResult, error)

// PlaybackHostEnv and PlaybackTimeoutEnv are the Go-side overrides for the
// send path's delivery leg. bin/notify.sh reads the equivalent values
// through herald_config's config-file-plus-legacy-env precedence
// (NOTIFY_PLAYBACK_HOST / HERALD_NOTIFY_PLAYBACK_HOST); this service is a
// standalone Go binary with no shell config-file layer sourced ahead of it,
// so — like BaseURLEnv and BindTailscaleIPEnv before it — it reads exactly
// one HERALD_-prefixed variable and carries no baked-in host default
// (AGENTS.md "No hardcoded host addresses"; delivery.go's DeliveryConfig
// doc makes the same commitment for the config struct itself).
const (
	PlaybackHostEnv    = "HERALD_NOTIFY_PLAYBACK_HOST"
	PlaybackTimeoutEnv = "HERALD_NOTIFY_PLAYBACK_TIMEOUT"
)

// DefaultSendQueueCapacity bounds the worker's backlog. Sized for this
// package's actual concurrency shape — a handful of agents or hooks
// notifying around the same moment, not a request flood — with headroom
// for a playback host stuck for one full DefaultPlaybackTimeout (10s) while
// the worker processes one job at a time: at one job per ~10s worst case,
// 32 slots is several minutes of backlog before the queue-full path engages,
// which is long enough to be a real operational signal rather than a
// twitchy threshold.
const DefaultSendQueueCapacity = 32

// sendJob is one accepted /notify request, queued for the worker.
//
// Muted and MutedUntil are resolved in the HANDLER, not the worker — task
// 1.5 lists the handler's steps in order as "validate, check mute, enqueue",
// and resolving mute here means the record eventually written reflects the
// mute state the caller's request actually observed, rather than whatever
// state happens to hold whenever the worker gets around to this job.
type sendJob struct {
	Project    string
	Text       string
	Muted      bool
	MutedUntil time.Time
}

// SendQueueOptions configures a SendQueue. The zero value is production
// configuration: real synthesis, real delivery, DefaultSendQueueCapacity.
type SendQueueOptions struct {
	Capacity   int
	Synthesize Synthesizer
	Deliver    DeliverFunc
}

// SendQueue owns the bounded backlog and the single worker goroutine that
// drains it.
type SendQueue struct {
	jobs       chan sendJob
	synthesize Synthesizer
	deliver    DeliverFunc
}

// NewSendQueue builds a queue and starts its worker. The worker runs for
// the lifetime of the process — there is no Close, matching Server's own
// lifecycle (task 1.4 has no shutdown path for the mux's handlers, only for
// the listeners) and this package's general posture that the daemon's unit
// of shutdown is the whole process, supervised by systemd (task 1.9).
func NewSendQueue(opts SendQueueOptions) *SendQueue {
	capacity := opts.Capacity
	if capacity <= 0 {
		capacity = DefaultSendQueueCapacity
	}
	synth := opts.Synthesize
	if synth == nil {
		synth = defaultSynthesize
	}
	deliver := opts.Deliver
	if deliver == nil {
		deliver = defaultDeliver
	}
	q := &SendQueue{
		jobs:       make(chan sendJob, capacity),
		synthesize: synth,
		deliver:    deliver,
	}
	go q.run()
	return q
}

// defaultSynthesize builds a Kokoro client from the environment on every
// call, exactly like configuredClient does for the CLI path — there is no
// cached client held across requests, so a base-URL change (or a mid-run
// Kokoro restart on a different port) takes effect on the very next job
// rather than requiring the service to restart.
func defaultSynthesize(ctx context.Context, text string, v Voice) ([]byte, error) {
	client, err := NewClient(ResolveBaseURL(), 0)
	if err != nil {
		return nil, err
	}
	return client.Synthesize(ctx, text, v)
}

// defaultDeliver resolves DeliveryConfig fresh per call, for the same reason
// defaultSynthesize resolves its client fresh: the send path must observe
// env changes without a restart, matching every other resolver in this
// package (ResolveBaseURL, ResolveStateDir, ResolveBindConfig).
func defaultDeliver(ctx context.Context, audioPath string) (DeliveryResult, error) {
	return Deliver(ctx, resolvePlaybackConfig(), audioPath)
}

// resolvePlaybackConfig reads PlaybackHostEnv/PlaybackTimeoutEnv. An unset
// or malformed timeout falls back to DefaultPlaybackTimeout rather than
// failing — the timeout is a tuning knob, not access control, unlike
// ResolveBindConfig's strict validation of the bind address itself.
func resolvePlaybackConfig() DeliveryConfig {
	timeout := DefaultPlaybackTimeout
	if raw := strings.TrimSpace(os.Getenv(PlaybackTimeoutEnv)); raw != "" {
		if secs, err := strconv.Atoi(raw); err == nil && secs > 0 {
			timeout = time.Duration(secs) * time.Second
		}
	}
	return DeliveryConfig{
		PlaybackHost: strings.TrimSpace(os.Getenv(PlaybackHostEnv)),
		Timeout:      timeout,
	}
}

// notifyRequest is the wire body for POST /notify.
type notifyRequest struct {
	Text    string `json:"text"`
	Project string `json:"project"`
}

// maxNotifyBodyBytes bounds the request body a caller can hand the handler
// before it is even decoded, mirroring the LimitReader guards Kokoro's own
// client code already applies to response bodies (kokoro.go) — an
// unauthenticated tailnet endpoint (proposal.md `## Decisions`,
// "Authentication: none") must not let a single caller hand it an unbounded
// body to decode.
const maxNotifyBodyBytes = 1 << 20 // 1MiB; MaxRecordedText truncates long text anyway.

// HandleNotify implements POST /notify. Registered onto Server.Mux by the
// single line in service.go's NewServer (task 1.5's whole footprint there).
//
// Response codes, and which ones carry a history record, per proposal.md's
// "exactly one history record per ACCEPTED request":
//
//	405 wrong method              -> no record (never a notification attempt)
//	400 invalid body/text/project -> no record (rejected before acceptance;
//	                                  see the package doc comment below for why)
//	202 enqueued                  -> exactly one record, written by the worker
//	503 queue full                -> exactly one record, written HERE (there
//	                                  is no queue slot left to defer it to)
func (q *SendQueue) HandleNotify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeNotifyJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}

	var body notifyRequest
	dec := json.NewDecoder(io.LimitReader(r.Body, maxNotifyBodyBytes))
	if err := dec.Decode(&body); err != nil {
		writeNotifyJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("notify: malformed request body: %v", err),
		})
		return
	}

	text := strings.TrimSpace(body.Text)
	if text == "" {
		writeNotifyJSON(w, http.StatusBadRequest, map[string]string{"error": "notify: text is required"})
		return
	}

	// An empty project is valid — Voices.Resolve treats "" as "use the
	// configured default" (voice.go), the same as every CLI subcommand that
	// takes an optional --project. A NON-empty project must be one this
	// operator actually configured; canonicalProject is the same check `set`
	// and `reset` already apply (cli.go), reused rather than re-derived.
	project := strings.TrimSpace(body.Project)
	if project != "" {
		if err := canonicalProject(project); err != nil {
			writeNotifyJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
	}

	// Resolved once, here, in request order — see sendJob's doc comment for
	// why this is not deferred to the worker. A MuteState read error (an
	// unreadable mute file) degrades to "not muted": AGENTS.md's fail-soft
	// contract says a broken switch must not SILENCE a notification either,
	// which MuteState.go already enforces for malformed content but not for
	// an I/O error on the read itself — that residual case is handled the
	// same way here.
	dir := ResolveStateDir()
	muted, until, err := MuteState(dir)
	if err != nil {
		muted, until = false, time.Time{}
	}

	job := sendJob{Project: project, Text: text, Muted: muted, MutedUntil: until}
	select {
	case q.jobs <- job:
		writeNotifyJSON(w, http.StatusAccepted, map[string]string{"status": "accepted"})
	default:
		// The queue is full. Unlike the 400s above, this request WAS valid
		// and WAS never delivered — that is a herald-side failure an
		// operator needs on the board (AGENTS.md: "History is the
		// debugging surface"), not a caller mistake to discard silently.
		// There is no slot left to hand this to the worker, so the record
		// is written right here instead, synchronously, before the 503
		// goes out — the one case in this file where that happens.
		//
		// The outcome vocabulary is closed (store.go) and has no "queue
		// full" member. synth_failed is the nearest honest fit: nothing
		// past synthesis ever had a chance to run for this call, exactly
		// the same as a real synthesis failure from the caller's point of
		// view (no audio was ever produced), and Reason carries the real
		// cause for anyone reading the row.
		voice := DefaultVoice
		if v, verr := ResolveVoice(dir, project); verr == nil {
			voice = v.String()
		}
		_ = AppendRecord(dir, Record{
			Project: project,
			Text:    text,
			Voice:   voice,
			Outcome: OutcomeSynthFailed,
			Reason:  fmt.Sprintf("send queue full (capacity %d): dropped before synthesis", cap(q.jobs)),
		})
		writeNotifyJSON(w, http.StatusServiceUnavailable, map[string]string{
			"error": "notify: send queue is full, try again shortly",
		})
	}
}

func writeNotifyJSON(w http.ResponseWriter, status int, body map[string]string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// run drains jobs one at a time for the life of the process.
func (q *SendQueue) run() {
	for job := range q.jobs {
		q.process(job)
	}
}

// process carries one job through resolve-voice -> synth -> deliver ->
// record, the same sequence runSynth/runRecord (cli.go) and bin/notify.sh
// perform for the CLI/pipe path — this is that sequence's in-process,
// asynchronous twin, not a divergent reimplementation.
//
// Wrapped in its own recover: a panic anywhere in one job (a bad Voice
// value, an injected test double behaving badly, a future bug) must not
// take the worker goroutine down and silence every notification queued
// behind it — AGENTS.md's fail-soft contract applies to this async path
// exactly as it does to bin/notify.sh's synchronous one. A panicking job
// necessarily forfeits its own history record (there is no safe point to
// resume the sequence from), which is the one case in this file where an
// accepted request does not end up with exactly one row; it is judged an
// acceptable trade against the alternative of a wedged worker silencing
// every notification after it.
func (q *SendQueue) process(job sendJob) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "notify: send worker recovered from a panic processing project=%q: %v\n", job.Project, r)
		}
	}()

	dir := ResolveStateDir()

	if job.Muted {
		// Mirrors bin/notify.sh's mute branch: no synthesis, no delivery,
		// the playback host is never contacted. The voice is still resolved
		// best-effort for the record — matching runRecord's fallback (voice
		// omitted -> resolve from project, "unknown" only if THAT fails —
		// see cli.go) — so a muted row on the board still says what would
		// have spoken.
		voice := DefaultVoice
		if v, err := ResolveVoice(dir, job.Project); err == nil {
			voice = v.String()
		}
		_ = AppendRecord(dir, Record{
			Project: job.Project,
			Text:    job.Text,
			Voice:   voice,
			Outcome: OutcomeMuted,
			Reason:  fmt.Sprintf("muted until %s", job.MutedUntil.Format(time.RFC3339)),
		})
		return
	}

	// Deliberately context.Background(), not a context tied to the HTTP
	// request: r.Context() is canceled the moment HandleNotify returns,
	// which happens before this function ever runs. Using it here would
	// cancel synthesis and delivery out from under every accepted request —
	// the exact bug this queue exists to make impossible. Synthesize and
	// Deliver each carry their own bound (the Kokoro client's timeout,
	// DeliveryConfig.Timeout), so this call is not unbounded despite the
	// background context.
	ctx := context.Background()

	// Resolve-first, exactly as runSynth does: on failure it still prints
	// DefaultVoice rather than "unknown" (cli.go), because a typo'd
	// voices.json should not also cost the record the voice that was
	// intended. Mirrored verbatim here.
	voice, err := ResolveVoice(dir, job.Project)
	if err != nil {
		_ = AppendRecord(dir, Record{
			Project: job.Project, Text: job.Text, Voice: DefaultVoice,
			Outcome: OutcomeSynthFailed, Reason: err.Error(),
		})
		return
	}

	audio, err := q.synthesize(ctx, job.Text, voice)
	if err != nil {
		_ = AppendRecord(dir, Record{
			Project: job.Project, Text: job.Text, Voice: voice.String(), Speed: voice.Speed,
			Outcome: OutcomeSynthFailed, Reason: err.Error(),
		})
		return
	}

	audioPath, cleanup, err := stageAudio(audio)
	if err != nil {
		_ = AppendRecord(dir, Record{
			Project: job.Project, Text: job.Text, Voice: voice.String(), Speed: voice.Speed,
			Outcome: OutcomeTransportFailed,
			Reason:  fmt.Sprintf("stage synthesized audio for delivery: %v", err),
		})
		return
	}
	defer cleanup()

	// Deliver's own doc: "every outcome here is a history record, not an
	// exception" — the error return is reserved for attempts that could not
	// even be MADE (config, unreadable audio), which DeliveryResult already
	// encodes as a record-worthy outcome too. So the error is deliberately
	// not branched on here; the result is what the record cares about.
	result, _ := q.deliver(ctx, audioPath)
	_ = AppendRecord(dir, Record{
		Project: job.Project, Text: job.Text, Voice: voice.String(), Speed: voice.Speed,
		Outcome: result.Outcome, Reason: result.Reason,
	})
}

// stageAudio writes synthesized bytes to a local temp file for Deliver,
// which reads from a path (delivery.go) rather than taking bytes directly —
// that signature is shared with the CLI's --out flag (cli.go's runSynth),
// so this is the async worker's equivalent of runSynth writing to *out.
//
// 0o600: the same reasoning runSynth's own write carries — this is the
// notification text spoken aloud, staged in a world-readable temp
// directory.
func stageAudio(audio []byte) (path string, cleanup func(), err error) {
	f, err := os.CreateTemp("", "herald-notify-audio.*")
	if err != nil {
		return "", nil, fmt.Errorf("notify: create staging file: %w", err)
	}
	tmp := f.Name()
	cleanup = func() { _ = os.Remove(tmp) }
	if chErr := f.Chmod(0o600); chErr != nil {
		_ = f.Close()
		cleanup()
		return "", nil, fmt.Errorf("notify: chmod staging file: %w", chErr)
	}
	if _, wErr := f.Write(audio); wErr != nil {
		_ = f.Close()
		cleanup()
		return "", nil, fmt.Errorf("notify: write staging file: %w", wErr)
	}
	if cErr := f.Close(); cErr != nil {
		cleanup()
		return "", nil, fmt.Errorf("notify: close staging file: %w", cErr)
	}
	return tmp, cleanup, nil
}
