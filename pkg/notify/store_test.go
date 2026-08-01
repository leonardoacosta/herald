package notify

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestAppendRecordRoundTrip(t *testing.T) {
	dir := t.TempDir()
	ts := time.Date(2026, 7, 25, 12, 0, 0, 0, time.UTC)

	rec := Record{
		TS:      ts,
		Project: "hs",
		Text:    "wave 1 landed",
		Voice:   "kokoro:af_bella",
		Speed:   0.95,
		Outcome: OutcomeDelivered,
	}
	if err := AppendRecord(dir, rec); err != nil {
		t.Fatalf("AppendRecord: %v", err)
	}

	got, err := ReadHistory(dir)
	if err != nil {
		t.Fatalf("ReadHistory: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d records, want 1", len(got))
	}
	if !got[0].TS.Equal(ts) || got[0].Project != "hs" || got[0].Text != "wave 1 landed" ||
		got[0].Voice != "kokoro:af_bella" || got[0].Speed != 0.95 || got[0].Outcome != OutcomeDelivered {
		t.Errorf("record did not round-trip: %+v", got[0])
	}
	if got[0].Reason != "" {
		t.Errorf("a delivered record carried a reason: %q", got[0].Reason)
	}
}

// Task 1.3's named assertion: a synthesis failure STILL produces a record, and
// that record carries the failure reason. A pipe that only writes history on
// success is a pipe whose board goes blank exactly when something breaks.
func TestSynthesisFailureStillWritesARecord(t *testing.T) {
	dir := t.TempDir()

	err := AppendRecord(dir, Record{
		Project: "hs",
		Text:    "wave 1 landed",
		Voice:   "kokoro:af_bella",
		Outcome: OutcomeSynthFailed,
		Reason:  "connection refused: 172.20.0.146:8880",
	})
	if err != nil {
		t.Fatalf("AppendRecord on a failure path: %v", err)
	}

	got, err := ReadHistory(dir)
	if err != nil {
		t.Fatalf("ReadHistory: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("a synthesis failure produced %d records, want 1", len(got))
	}
	if got[0].Outcome != OutcomeSynthFailed {
		t.Errorf("Outcome = %q, want %q", got[0].Outcome, OutcomeSynthFailed)
	}
	if !strings.Contains(got[0].Reason, "connection refused") {
		t.Errorf("Reason = %q, want the failure reason preserved", got[0].Reason)
	}
	// The text and resolved voice survive a failure too — the board shows what
	// was going to be said, not just that something wasn't.
	if got[0].Text != "wave 1 landed" || got[0].Voice != "kokoro:af_bella" {
		t.Errorf("failure record lost its text/voice: %+v", got[0])
	}
}

// A transport timeout is ssh rc 124 — the playback host asleep or unreachable.
// It must be storable as its own outcome, not collapsed into transport_failed.
func TestTransportTimeoutIsItsOwnOutcome(t *testing.T) {
	dir := t.TempDir()
	if err := AppendRecord(dir, Record{
		Project: "hs",
		Text:    "late night",
		Voice:   DefaultVoice,
		Outcome: OutcomeTransportTimeout,
		Reason:  "ssh exited 124 after 10s (playback host asleep?)",
	}); err != nil {
		t.Fatalf("AppendRecord: %v", err)
	}
	got, _ := ReadHistory(dir)
	if len(got) != 1 || got[0].Outcome != OutcomeTransportTimeout {
		t.Fatalf("got %+v, want a %s record", got, OutcomeTransportTimeout)
	}
	if got[0].Outcome == OutcomeTransportFailed {
		t.Error("timeout collapsed into transport_failed")
	}
}

func TestAppendRecordRejectsUnknownOutcome(t *testing.T) {
	dir := t.TempDir()
	err := AppendRecord(dir, Record{Text: "x", Outcome: "kind-of-worked"})
	if err == nil {
		t.Fatal("AppendRecord accepted an outcome outside the closed set")
	}
	if _, statErr := os.Stat(HistoryPath(dir)); !os.IsNotExist(statErr) {
		t.Error("a rejected record still created the history file")
	}
}

func TestValidOutcomeCoversTheClosedSet(t *testing.T) {
	for _, o := range []string{OutcomeDelivered, OutcomeSynthFailed, OutcomeTransportFailed, OutcomeTransportTimeout} {
		if !ValidOutcome(o) {
			t.Errorf("ValidOutcome(%q) = false, want true", o)
		}
	}
	for _, o := range []string{"", "ok", "failed", "DELIVERED"} {
		if ValidOutcome(o) {
			t.Errorf("ValidOutcome(%q) = true, want false", o)
		}
	}
}

// Appends accumulate in call order — the board reads newest-last.
func TestAppendIsAppendOnlyAndOrdered(t *testing.T) {
	dir := t.TempDir()
	for _, txt := range []string{"first", "second", "third"} {
		if err := AppendRecord(dir, Record{Text: txt, Voice: DefaultVoice, Outcome: OutcomeDelivered}); err != nil {
			t.Fatalf("AppendRecord(%s): %v", txt, err)
		}
	}
	got, err := ReadHistory(dir)
	if err != nil {
		t.Fatalf("ReadHistory: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d records, want 3 — an append overwrote earlier rows", len(got))
	}
	if got[0].Text != "first" || got[2].Text != "third" {
		t.Errorf("records out of order: %q ... %q", got[0].Text, got[2].Text)
	}
}

// A zero timestamp is stamped rather than written as a zero time — no row on
// the board may be undatable.
func TestAppendStampsZeroTimestamp(t *testing.T) {
	dir := t.TempDir()
	before := time.Now().UTC().Add(-time.Second)
	if err := AppendRecord(dir, Record{Text: "x", Voice: DefaultVoice, Outcome: OutcomeDelivered}); err != nil {
		t.Fatal(err)
	}
	got, _ := ReadHistory(dir)
	if len(got) != 1 || got[0].TS.IsZero() {
		t.Fatalf("timestamp not stamped: %+v", got)
	}
	if got[0].TS.Before(before) {
		t.Errorf("TS = %v, want a fresh stamp", got[0].TS)
	}
}

// First run: no history file at all. The board must get an empty slice, not an
// error, or task 3.1's empty-history case turns into a crash.
func TestReadHistoryMissingFileIsEmpty(t *testing.T) {
	got, err := ReadHistory(t.TempDir())
	if err != nil {
		t.Fatalf("ReadHistory on a fresh dir: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d records from a fresh dir, want 0", len(got))
	}
}

// Text carrying quotes/newlines must not corrupt the file — every field goes
// through encoding/json, never through string concatenation.
func TestAppendEscapesHostileText(t *testing.T) {
	dir := t.TempDir()
	nasty := "he said \"go\"\nthen {\"outcome\":\"delivered\"}"
	if err := AppendRecord(dir, Record{Text: nasty, Voice: DefaultVoice, Outcome: OutcomeSynthFailed, Reason: "x"}); err != nil {
		t.Fatal(err)
	}
	got, err := ReadHistory(dir)
	if err != nil {
		t.Fatalf("ReadHistory after hostile text: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("hostile text produced %d records, want 1", len(got))
	}
	if got[0].Text != nasty {
		t.Errorf("text did not round-trip: %q", got[0].Text)
	}
	if got[0].Outcome != OutcomeSynthFailed {
		t.Errorf("injected JSON changed the outcome: %q", got[0].Outcome)
	}
}
