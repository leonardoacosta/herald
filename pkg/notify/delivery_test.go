package notify

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// notify-service task 1.3. Each case below pins one of the four constraints
// bin/notify.sh's comment block documents, so the Go port cannot quietly lose
// what the shell paid for in incidents.

// Constraint 2. This is invisible to any behavioural test that happens to run
// against a reachable host: with -n the ssh exits 0 and nothing plays.
func TestDeliveryNeverPassesDashN(t *testing.T) {
	for _, arg := range DeliverySSHArgs("somehost", "") {
		if arg == "-n" {
			t.Fatal("delivery passed `ssh -n`, which discards the piped audio: exit 0, no sound, no error")
		}
	}
}

func TestDeliveryUsesBatchModeSoItNeverPromptsForAPassword(t *testing.T) {
	joined := strings.Join(DeliverySSHArgs("somehost", ""), " ")
	if !strings.Contains(joined, "BatchMode=yes") {
		t.Errorf("delivery argv lacks BatchMode=yes: %s", joined)
	}
}

func TestClientTargetMappingSharedContract(t *testing.T) {
	fixture, err := os.ReadFile(filepath.Join("..", "..", "tests", "fixtures", "client-targets.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name     string `json:"name"`
		Mapping  string `json:"mapping"`
		Valid    bool   `json:"valid"`
		Identity string `json:"identity"`
		Host     string `json:"host"`
	}
	if err := json.Unmarshal(fixture, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			got, err := parseClientTargetMapping(tc.Mapping)
			if (err == nil) != tc.Valid {
				t.Fatalf("valid=%v, want %v (map=%v, err=%v)", err == nil, tc.Valid, got, err)
			}
			if tc.Valid && tc.Identity != "" && got[tc.Identity] != tc.Host {
				t.Fatalf("mapping[%q]=%q, want %q", tc.Identity, got[tc.Identity], tc.Host)
			}
		})
	}
}

func TestInvalidClientTargetMappingFallsBackToStaticHost(t *testing.T) {
	for _, mapping := range []string{"laptop=host,", "laptop=host,laptop=other", ".laptop=host", "laptop=-option"} {
		t.Run(mapping, func(t *testing.T) {
			t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", mapping)
			if got := resolvePlaybackHost(DeliveryConfig{PlaybackHost: "static-host"}, "laptop"); got != "static-host" {
				t.Fatalf("invalid map selected %q, want static fallback", got)
			}
		})
	}
}

func TestPlaybackTargetResolvesOnlyConfiguredIdentity(t *testing.T) {
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=bb-mac, phone=phone-host")
	cfg := DeliveryConfig{PlaybackHost: "static-host"}

	if got := resolvePlaybackHost(cfg, "laptop"); got != "bb-mac" {
		t.Fatalf("configured identity resolved to %q, want bb-mac", got)
	}
	if got := resolvePlaybackHost(cfg, "ssh://attacker"); got != "static-host" {
		t.Fatalf("unconfigured identity became %q, want static fallback", got)
	}
}

func TestPlaybackTargetMappingNeverTreatsIdentityAsHost(t *testing.T) {
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=bb-mac")
	if got := resolvePlaybackHost(DeliveryConfig{PlaybackHost: "static-host"}, "bb-mac"); got != "static-host" {
		t.Fatalf("raw host-like identity resolved to %q, want static fallback", got)
	}
}

// Constraints 3 and 4 live in the remote script text. Assert they are present in
// what actually ships rather than trusting the file was not edited.
func TestRemoteScriptKeepsRenameAfterCompleteAndTheTrapWindow(t *testing.T) {
	if !strings.Contains(remoteSpoolScript, ".incoming.") {
		t.Error("remote script does not write to a dot-prefixed staging name")
	}
	if !strings.Contains(remoteSpoolScript, `mv "$tmp" "$clip"`) {
		t.Error("remote script does not rename into the spool after the bytes land")
	}
	if !strings.Contains(remoteSpoolScript, `trap 'rm -f "$tmp" "$meta_tmp"' EXIT INT TERM`) {
		t.Error("remote script lost the trap covering mktemp-to-bytes-landed")
	}
	if !strings.Contains(remoteSpoolScript, "trap - EXIT INT TERM") {
		t.Error("remote script never clears the trap, so a delivered clip would be deleted")
	}
}

// The fallback drainer is the whole reason delivery survives a dead resident
// player. The first draft of this port dropped it; this is the guard.
func TestRemoteScriptStillSpawnsTheFallbackDrainer(t *testing.T) {
	if !strings.Contains(remoteSpoolScript, "afplay") {
		t.Fatal("remote script carries no fallback drainer — a clip would never play with the resident player down")
	}
	if !strings.Contains(remoteSpoolScript, "drainer.lock") {
		t.Error("remote script lost the drainer lock, so two players could run at once")
	}
}

// Constraint 1: an unreachable host is BOUNDED and reports its own outcome,
// rather than hanging or blurring into a generic transport failure.
func TestUnreachableHostTimesOutWithinTheBoundAndRecordsItsOwnOutcome(t *testing.T) {
	audio := filepath.Join(t.TempDir(), "clip.mp3")
	if err := os.WriteFile(audio, []byte("not really audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	// RFC 5737 TEST-NET-1: guaranteed non-routable, so this exercises the
	// wall-clock bound rather than a fast connection refusal.
	cfg := DeliveryConfig{PlaybackHost: "192.0.2.1", Timeout: 2 * time.Second}

	start := time.Now()
	res, err := Deliver(context.Background(), cfg, audio, "")
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("Deliver returned a hard error for an unreachable host: %v", err)
	}
	if res.Outcome != OutcomeTransportTimeout && res.Outcome != OutcomeTransportFailed {
		t.Errorf("outcome %q, want transport_timeout or transport_failed", res.Outcome)
	}
	if elapsed > 10*time.Second {
		t.Errorf("took %s against a 2s bound — the wall clock is not bounded", elapsed)
	}
	if res.Reason == "" {
		t.Error("a non-delivered outcome carried no reason")
	}
}

func TestDeliveryWithoutAPlaybackHostIsRefusedNotGuessed(t *testing.T) {
	audio := filepath.Join(t.TempDir(), "clip.mp3")
	if err := os.WriteFile(audio, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := Deliver(context.Background(), DeliveryConfig{}, audio, "")
	if err == nil {
		t.Fatal("empty playback host was accepted; AGENTS.md forbids a baked-in default")
	}
	if res.Outcome != OutcomeTransportFailed {
		t.Errorf("outcome %q, want %s", res.Outcome, OutcomeTransportFailed)
	}
}

func TestDeliveryReportsUnreadableAudioRatherThanSendingNothing(t *testing.T) {
	res, err := Deliver(context.Background(),
		DeliveryConfig{PlaybackHost: "somehost", Timeout: time.Second},
		filepath.Join(t.TempDir(), "does-not-exist.mp3"), "")
	if err == nil {
		t.Fatal("missing audio file was accepted")
	}
	if res.Outcome != OutcomeTransportFailed {
		t.Errorf("outcome %q, want %s", res.Outcome, OutcomeTransportFailed)
	}
}
