package notify

import (
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// notify-service task 1.1: the coverage the markdown writer never had. Every
// case below was previously enforced only by a shell snippet inside a Claude
// command file, with nothing testing it.

func TestParseMuteDurationAcceptsTheOperatorVocabulary(t *testing.T) {
	cases := map[string]time.Duration{
		"30s": 30 * time.Second,
		"5m":  5 * time.Minute,
		"1h":  time.Hour,
		"2d":  48 * time.Hour,
		" 1h": time.Hour, // surrounding whitespace is the operator's, not an error
	}
	for in, want := range cases {
		got, err := ParseMuteDuration(in)
		if err != nil {
			t.Errorf("ParseMuteDuration(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("ParseMuteDuration(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestParseMuteDurationRejectsMalformedInput(t *testing.T) {
	// "1h30m" and "500ms" are the reason this is not time.ParseDuration: both
	// are valid Go durations and neither is valid here, and silently accepting
	// "500ms" would look like a mute that did nothing.
	for _, in := range []string{"", "1", "h", "-5m", "0h", "abc", "1h30m", "500ms", "5 m"} {
		if d, err := ParseMuteDuration(in); err == nil {
			t.Errorf("ParseMuteDuration(%q) = %s, want an error", in, d)
		}
	}
}

func TestSetMuteThenStateReportsMuted(t *testing.T) {
	dir := t.TempDir()
	until, err := SetMute(dir, time.Hour)
	if err != nil {
		t.Fatalf("SetMute: %v", err)
	}
	muted, got, err := MuteState(dir)
	if err != nil {
		t.Fatalf("MuteState: %v", err)
	}
	if !muted {
		t.Fatal("expected muted immediately after SetMute")
	}
	// Second-granularity on disk, so compare at that resolution.
	if got.Unix() != until.Unix() {
		t.Errorf("expiry round-tripped as %s, want %s", got, until)
	}
}

func TestMuteFileIsTheDocumentedEpochFormat(t *testing.T) {
	// The on-disk format is a contract with bin/notify.sh's reader (and with
	// any future non-Go caller). Assert the bytes, not just the round-trip.
	dir := t.TempDir()
	until, err := SetMute(dir, time.Hour)
	if err != nil {
		t.Fatalf("SetMute: %v", err)
	}
	b, err := os.ReadFile(MutePath(dir))
	if err != nil {
		t.Fatalf("read mute file: %v", err)
	}
	if strings.TrimSpace(string(b)) != strconv.FormatInt(until.Unix(), 10) {
		t.Errorf("mute file holds %q, want the expiry as epoch seconds", string(b))
	}
	if fi, err := os.Stat(MutePath(dir)); err == nil && fi.Mode().Perm() != 0o600 {
		t.Errorf("mute file mode is %v, want 0600", fi.Mode().Perm())
	}
}

func TestExpiredMuteReadsAsUnmutedAndCleansUp(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(MutePath(dir), []byte("1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	muted, _, err := MuteState(dir)
	if err != nil {
		t.Fatalf("MuteState: %v", err)
	}
	if muted {
		t.Error("an expiry in 1970 reported as muted")
	}
	if _, err := os.Stat(MutePath(dir)); !os.IsNotExist(err) {
		t.Error("expired mute file was not cleaned up")
	}
}

func TestMalformedMuteNeverWedgesTheNotifierSilent(t *testing.T) {
	// Fail-soft: a garbage switch must not be able to silence notifications
	// permanently. It reads as unmuted AND is removed.
	dir := t.TempDir()
	if err := os.WriteFile(MutePath(dir), []byte("not-a-number\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	muted, _, err := MuteState(dir)
	if err != nil {
		t.Fatalf("MuteState on malformed file: %v", err)
	}
	if muted {
		t.Error("malformed mute file reported as muted")
	}
	if _, err := os.Stat(MutePath(dir)); !os.IsNotExist(err) {
		t.Error("malformed mute file was not cleaned up")
	}
}

func TestMissingMuteFileIsNotMutedAndNotAnError(t *testing.T) {
	muted, _, err := MuteState(t.TempDir())
	if err != nil {
		t.Fatalf("MuteState on a clean dir: %v", err)
	}
	if muted {
		t.Error("clean state dir reported as muted")
	}
}

func TestClearMuteIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	if _, err := SetMute(dir, time.Hour); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := ClearMute(dir); err != nil {
			t.Fatalf("ClearMute call %d: %v", i+1, err)
		}
	}
	if muted, _, _ := MuteState(dir); muted {
		t.Error("still muted after ClearMute")
	}
}

func TestSetMuteRejectsNonPositive(t *testing.T) {
	dir := t.TempDir()
	for _, d := range []time.Duration{0, -time.Hour} {
		if _, err := SetMute(dir, d); err == nil {
			t.Errorf("SetMute(%s) succeeded, want an error", d)
		}
	}
	if _, err := os.Stat(MutePath(dir)); !os.IsNotExist(err) {
		t.Error("a rejected SetMute still created the file")
	}
}
