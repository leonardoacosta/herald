package notify

import (
	"bytes"
	"context"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// Delivery: shipping synthesized audio to the playback host.
//
// # Why this is a port and not a rewrite
//
// bin/notify.sh has carried this leg since Herald existed, and its comment
// block documents four constraints that were each paid for with a real failure.
// The service needs the same leg in-process, so the constraints move with it
// verbatim rather than being re-derived:
//
//  1. The ssh call is bounded by an EXTERNAL wall-clock timeout. ConnectTimeout
//     does not bound wall clock — the mesh's ConnectionAttempts turned
//     ConnectTimeout=3 into 7009ms elapsed against an offline node. Here that is
//     exec.CommandContext with a deadline, and a deadline hit is reported as its
//     own outcome (OutcomeTransportTimeout) because "the playback host is
//     asleep" is a different operator state from "the transport broke".
//
//  2. NO `ssh -n`. It redirects stdin from /dev/null, which silently discards
//     the piped audio: exit 0, no sound, no error. Stdin IS the payload here.
//     TestDeliveryNeverPassesDashN guards this.
//
//  3. The remote side writes to a dot-prefixed name and RENAMES it into the
//     spool only once complete, so a drainer scanning mid-write can never play a
//     truncated clip.
//
//  4. A remote trap covers the window between mktemp and the bytes landing, so a
//     timeout-killed ssh cannot leak audio into the playback host's /tmp.
//
// Constraints 3 and 4 live in the remote script text, which is shared with
// bin/notify.sh — see remoteSpoolScript and its drift test.

// DeliveryConfig is the transport's deployment configuration. No defaults are
// baked in beyond the timeout: the playback host is deployment configuration,
// resolved by the caller, never a literal in this package (AGENTS.md § No
// hardcoded host addresses).
type DeliveryConfig struct {
	PlaybackHost string
	Timeout      time.Duration
}

// DefaultPlaybackTimeout mirrors bin/notify.sh's NOTIFY_PLAYBACK_TIMEOUT default.
const DefaultPlaybackTimeout = 10 * time.Second

const sshWaitDelay = 250 * time.Millisecond

// ErrNoPlaybackHost is returned when the transport has nowhere to send audio.
var ErrNoPlaybackHost = errors.New("notify: playback host is not configured")

// configuredClientHost resolves an opaque client identity through deployment
// configuration. Values are comma-separated identity=ssh-host pairs. A
// request never supplies an SSH host directly.
var configuredClientIdentity = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)

func parseClientTargetMapping(mapping string) (map[string]string, error) {
	resolved := make(map[string]string)
	if strings.TrimSpace(mapping) == "" {
		return resolved, nil
	}
	for _, raw := range strings.Split(mapping, ",") {
		entry := strings.TrimSpace(raw)
		key, host, ok := strings.Cut(entry, "=")
		key, host = strings.TrimSpace(key), strings.TrimSpace(host)
		if !ok || !configuredClientIdentity.MatchString(key) || host == "" || strings.HasPrefix(host, "-") || strings.ContainsAny(host, " \t\r\n\v\f") {
			return nil, errors.New("notify: invalid HERALD_NOTIFY_CLIENT_TARGETS mapping")
		}
		if _, duplicate := resolved[key]; duplicate {
			return nil, errors.New("notify: duplicate identity in HERALD_NOTIFY_CLIENT_TARGETS mapping")
		}
		resolved[key] = host
	}
	return resolved, nil
}

func configuredClientHost(client string) (string, bool) {
	if !configuredClientIdentity.MatchString(strings.TrimSpace(client)) {
		return "", false
	}
	mapping, err := parseClientTargetMapping(os.Getenv("HERALD_NOTIFY_CLIENT_TARGETS"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return "", false
	}
	host, ok := mapping[strings.TrimSpace(client)]
	return host, ok
}

func resolvePlaybackHost(cfg DeliveryConfig, client string) string {
	if host, ok := configuredClientHost(client); ok {
		return host
	}
	return strings.TrimSpace(cfg.PlaybackHost)
}

func resolveRequestDelivery(cfg DeliveryConfig, client string) DeliveryConfig {
	cfg.PlaybackHost = resolvePlaybackHost(cfg, client)
	return cfg
}

// DeliveryResult is the outcome of one delivery attempt, shaped so the caller
// can hand it straight to AppendRecord.
type DeliveryResult struct {
	Outcome string
	Reason  string
	Bytes   int
}

// Deliver ships the audio at path to the playback host's spool.
//
// It returns a DeliveryResult rather than an error for transport failures: every
// outcome here is a history record, not an exception. A non-nil error means the
// attempt could not be made at all (no host configured, unreadable audio), which
// the caller still records — as OutcomeTransportFailed — but which is a
// different class from "we tried and the host was asleep".
func Deliver(ctx context.Context, cfg DeliveryConfig, audioPath string, requestIDs ...string) (DeliveryResult, error) {
	requestID := ""
	if len(requestIDs) > 0 {
		requestID = requestIDs[0]
	}
	if len(requestIDs) > 1 && strings.TrimSpace(requestIDs[1]) != "" {
		// The request carries only an opaque identity. An unknown identity must
		// never become an SSH host and retains the deployment's static fallback.
		cfg = resolveRequestDelivery(cfg, requestIDs[1])
	}
	host := strings.TrimSpace(cfg.PlaybackHost)
	if host == "" {
		return DeliveryResult{Outcome: OutcomeTransportFailed, Reason: ErrNoPlaybackHost.Error()}, ErrNoPlaybackHost
	}
	audio, err := os.ReadFile(audioPath)
	if err != nil {
		return DeliveryResult{
			Outcome: OutcomeTransportFailed,
			Reason:  fmt.Sprintf("read synthesized audio: %v", err),
		}, fmt.Errorf("notify: read audio %s: %w", audioPath, err)
	}

	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = DefaultPlaybackTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ssh", DeliverySSHArgs(host, requestID)...)
	cmd.WaitDelay = sshWaitDelay
	// Constraint 2: stdin carries the audio. Never /dev/null, never `-n`.
	cmd.Stdin = bytes.NewReader(audio)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	runErr := cmd.Run()
	switch {
	case runErr == nil:
		return DeliveryResult{Outcome: OutcomeDelivered, Bytes: len(audio)}, nil
	case ctx.Err() == context.DeadlineExceeded:
		// Constraint 1: its own outcome. This is the state an operator wants on
		// the board — the host was asleep or off the tailnet — rather than a
		// generic transport failure.
		return DeliveryResult{
			Outcome: OutcomeTransportTimeout,
			Reason: fmt.Sprintf("ssh exceeded %s (playback host %s asleep or unreachable?)",
				timeout, host),
			Bytes: len(audio),
		}, nil
	default:
		return DeliveryResult{
			Outcome: OutcomeTransportFailed,
			Reason:  fmt.Sprintf("ssh to %s failed: %v: %s", host, runErr, collapseReason(stderr.String())),
			Bytes:   len(audio),
		}, nil
	}
}

// DeliverySSHArgs builds the ssh argv. Exported so a test can assert the shape
// — specifically that `-n` never appears (constraint 2), which is invisible in
// any behavioural test that happens to run against a reachable host.
func DeliverySSHArgs(host string, requestIDs ...string) []string {
	requestID := ""
	if len(requestIDs) > 0 {
		requestID = requestIDs[0]
	}
	remote := remoteSpoolScript
	if validRequestID(requestID) {
		// The service must not finalize history when bytes merely reached the
		// spool. Waiting keeps the request in the delivering stage until the
		// resident player or fallback drainer removes the clip, so stop can
		// interrupt physical playback rather than racing a premature delivered
		// record. The fire-and-forget shell pipe does not use this path unless its
		// explicit --wait mode sets the same contract.
		remote = fmt.Sprintf("HERALD_REQUEST_ID=%s HERALD_WAIT=1\n%s", requestID, remoteSpoolScript)
	}
	return []string{"-o", "BatchMode=yes", host, remote}
}

func StopRemoteRequest(ctx context.Context, cfg DeliveryConfig, requestID string) bool {
	if !validRequestID(requestID) {
		return false
	}
	host := strings.TrimSpace(cfg.PlaybackHost)
	if host == "" {
		return false
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = DefaultPlaybackTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	remote := fmt.Sprintf("HERALD_STOP_REQUEST_ID=%s\n%s", requestID, remoteSpoolScript)
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", host, remote)
	cmd.WaitDelay = sshWaitDelay
	cmd.Stdin = strings.NewReader("")
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if cmd.Run() != nil || ctx.Err() != nil {
		return false
	}
	return strings.TrimSpace(stdout.String()) == "stopped"
}

// remoteSpoolScript is the shell run ON the playback host: enqueue into the
// spool, spawn a fallback drainer candidate, and nudge a resident player.
//
// EMBEDDED from the same file bin/notify.sh reads, deliberately. The first draft
// of this port kept a hand-copied Go string instead, and it silently dropped the
// drainer-candidate block — which would have meant a clip never plays whenever
// the resident player is down, the exact case the fallback exists for. Two
// copies of a 58-line shell script cannot be kept honest by review; one file
// read by both callers can.
//
//go:embed remote_spool.sh
var remoteSpoolScript string
