package notify

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestExecutableDigestChangesForDifferentArtifacts(t *testing.T) {
	dir := t.TempDir()
	first := dir + "/first"
	second := dir + "/second"
	if err := os.WriteFile(first, []byte("artifact one"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte("artifact two"), 0o700); err != nil {
		t.Fatal(err)
	}
	one, err := executableDigest(first)
	if err != nil {
		t.Fatal(err)
	}
	two, err := executableDigest(second)
	if err != nil {
		t.Fatal(err)
	}
	if one == two {
		t.Fatalf("different artifacts have the same identity %q", one)
	}
	again, err := executableDigest(first)
	if err != nil {
		t.Fatal(err)
	}
	if again != one {
		t.Fatalf("unchanged artifact identity changed: %q then %q", one, again)
	}
}

func TestArtifactDigestOnceIgnoresReplacementAtSamePath(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/herald"
	if err := os.WriteFile(path, []byte("old dirty build"), 0o700); err != nil {
		t.Fatal(err)
	}
	identity := artifactDigestOnce(func() string { return path })
	old := identity()
	if old == "" {
		t.Fatal("initial artifact identity is empty")
	}
	if err := os.WriteFile(path, []byte("new dirty build"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := identity(); got != old {
		t.Fatalf("cached identity changed after replacement: %q then %q", old, got)
	}
}

func TestBuiltArtifactsReportDistinctPublicVersions(t *testing.T) {
	if testing.Short() {
		t.Skip("builds real CLI artifacts")
	}
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	first := filepath.Join(dir, "herald-default")
	second := filepath.Join(dir, "herald-trimpath")
	build := func(output string, args ...string) {
		buildArgs := append([]string{"build", "-o", output}, args...)
		buildArgs = append(buildArgs, "./cmd/herald")
		cmd := exec.Command("go", buildArgs...)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("go %v: %v\n%s", buildArgs, err, out)
		}
	}
	build(first)
	build(second, "-trimpath")
	status := func(binary string) Status {
		state := filepath.Join(dir, filepath.Base(binary)+"-state")
		cmd := exec.Command(binary, "notify", "status", "--json")
		cmd.Dir = root
		cmd.Env = append(os.Environ(), StateDirEnv+"="+state)
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%s notify status --json: %v", binary, err)
		}
		var got Status
		if err := json.Unmarshal(out, &got); err != nil {
			t.Fatalf("decode %s status: %v (%s)", binary, err, out)
		}
		return got
	}
	one := status(first)
	two := status(second)
	if one.Version == "" || two.Version == "" {
		t.Fatalf("built artifacts reported empty versions: %q, %q", one.Version, two.Version)
	}
	if one.Version == two.Version {
		t.Fatalf("distinct built artifacts reported the same public version %q", one.Version)
	}
	if stable := status(first); stable.Version != one.Version {
		t.Fatalf("unchanged artifact version changed: %q then %q", one.Version, stable.Version)
	}
}

func TestBuildVersionRetainsSourceContextAndArtifactIdentity(t *testing.T) {
	if got := buildVersion("abc123"); got != "devel-abc123" {
		t.Errorf("buildVersion = %q, want devel-abc123", got)
	}
	if got := withDigest("deadbee-dirty", "abc123"); got != "deadbee-dirty-abc123" {
		t.Errorf("withDigest = %q, want source revision plus artifact identity", got)
	}
}

func TestVersionIsStableForTheRunningArtifact(t *testing.T) {
	first := Version()
	second := Version()
	if first == "" {
		t.Fatal("Version returned an empty identity")
	}
	if second != first {
		t.Fatalf("Version changed without an artifact change: %q then %q", first, second)
	}
}

// notify-service task 2.1 gap-fill. status.go (ReadStatus, TailHistory) had
// no direct unit test anywhere in the package — every existing exercise of
// these two functions was transitive, through either the CLI (cli.go's
// runStatus/runHistory) or the HTTP handlers (control.go). This file tests
// the functions themselves, plus the two literal CLI Verify clauses task 1.2
// names ("herald notify status --json" and "herald notify history --json -n
// 5" each emit parseable JSON) that nothing in the suite exercised at the
// CLI layer.

func setupStatusTestState(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv(StateDirEnv, dir)
	return dir
}

// --- ReadStatus ---

func TestReadStatusAssemblesEveryField(t *testing.T) {
	dir := setupStatusTestState(t)
	t.Setenv(BaseURLEnv, "http://127.0.0.1:8880")

	until, err := SetMute(dir, time.Hour)
	if err != nil {
		t.Fatalf("SetMute: %v", err)
	}
	for i := 0; i < 3; i++ {
		if err := AppendRecord(dir, Record{Text: "seed", Voice: DefaultVoice, Outcome: OutcomeDelivered}); err != nil {
			t.Fatalf("AppendRecord: %v", err)
		}
	}
	if err := WriteVoices(dir, Voices{Default: "kokoro:af_bella"}); err != nil {
		t.Fatalf("WriteVoices: %v", err)
	}

	st, err := ReadStatus(dir)
	if err != nil {
		t.Fatalf("ReadStatus: %v", err)
	}
	if st.Version == "" {
		t.Error("Version is empty")
	}
	if st.StateDir != dir {
		t.Errorf("StateDir = %q, want %q", st.StateDir, dir)
	}
	if st.KokoroURL != "http://127.0.0.1:8880" {
		t.Errorf("KokoroURL = %q, want the resolved base URL", st.KokoroURL)
	}
	if !st.Muted {
		t.Error("Muted = false, want true")
	}
	if st.MutedUntil == nil || st.MutedUntil.Unix() != until.Unix() {
		t.Errorf("MutedUntil = %v, want %v", st.MutedUntil, until)
	}
	if st.HistoryCount != 3 {
		t.Errorf("HistoryCount = %d, want 3", st.HistoryCount)
	}
	if st.DefaultVoice != "kokoro:af_bella" {
		t.Errorf("DefaultVoice = %q, want kokoro:af_bella", st.DefaultVoice)
	}
}

func TestReadStatusFreshHostHasZeroValuesNotAnError(t *testing.T) {
	dir := setupStatusTestState(t)
	st, err := ReadStatus(dir)
	if err != nil {
		t.Fatalf("ReadStatus on a fresh dir: %v", err)
	}
	if st.Muted || st.MutedUntil != nil {
		t.Errorf("fresh host reports muted: %+v", st)
	}
	if st.HistoryCount != 0 {
		t.Errorf("HistoryCount = %d, want 0", st.HistoryCount)
	}
	// An unconfigured voices.json stores "" for Default; ReadStatus reports
	// the EFFECTIVE resolved voice, not the blank stored value (status.go's
	// own doc comment) — this is the one field the fresh-host case must NOT
	// leave zero.
	if st.DefaultVoice == "" {
		t.Error("DefaultVoice is blank on a fresh host, want the resolved built-in default")
	}
}

// ReadStatus's fail-soft contract (status.go doc comment): every piece
// degrades to its zero value except a voices.json that exists but does not
// parse, which propagates as an error while the REST of the readout still
// comes back populated — status is the command an operator runs when
// something is already wrong.
func TestReadStatusPropagatesMalformedVoicesButStillReportsWhatItCan(t *testing.T) {
	dir := setupStatusTestState(t)
	if _, err := SetMute(dir, time.Hour); err != nil {
		t.Fatalf("SetMute: %v", err)
	}
	if err := os.WriteFile(VoicesPath(dir), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	st, err := ReadStatus(dir)
	if err == nil {
		t.Fatal("ReadStatus accepted a malformed voices.json without error")
	}
	if !st.Muted {
		t.Error("mute state was lost alongside the voices.json error, want it still reported")
	}
	if st.DefaultVoice != "" {
		t.Errorf("DefaultVoice = %q on the error path, want the zero value", st.DefaultVoice)
	}
}

// --- TailHistory ---

func seedHistoryTexts(t *testing.T, dir string, texts ...string) {
	t.Helper()
	for _, txt := range texts {
		if err := AppendRecord(dir, Record{Text: txt, Voice: DefaultVoice, Outcome: OutcomeDelivered}); err != nil {
			t.Fatalf("AppendRecord(%s): %v", txt, err)
		}
	}
}

func TestTailHistoryNSemantics(t *testing.T) {
	dir := setupStatusTestState(t)
	seedHistoryTexts(t, dir, "a", "b", "c", "d", "e")

	cases := []struct {
		name     string
		n        int
		wantLen  int
		wantLast string
	}{
		{"n less than count returns the newest tail", 2, 2, "e"},
		{"n equal to count returns everything", 5, 5, "e"},
		{"n greater than count returns everything, not an error", 100, 5, "e"},
		{"n zero returns everything", 0, 5, "e"},
		{"negative n returns everything", -3, 5, "e"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := TailHistory(dir, tc.n)
			if err != nil {
				t.Fatalf("TailHistory(%d): %v", tc.n, err)
			}
			if len(got) != tc.wantLen {
				t.Fatalf("TailHistory(%d) returned %d records, want %d", tc.n, len(got), tc.wantLen)
			}
			if got[len(got)-1].Text != tc.wantLast {
				t.Errorf("TailHistory(%d) last record = %q, want %q (newest-last order)", tc.n, got[len(got)-1].Text, tc.wantLast)
			}
		})
	}
	// n=2 must be the newest two, not the oldest two.
	tail, err := TailHistory(dir, 2)
	if err != nil {
		t.Fatalf("TailHistory(2): %v", err)
	}
	if tail[0].Text != "d" || tail[1].Text != "e" {
		t.Errorf("TailHistory(2) = %v, want the last two records [d e]", []string{tail[0].Text, tail[1].Text})
	}
}

func TestTailHistoryEmptyHistoryReturnsNilNotError(t *testing.T) {
	dir := setupStatusTestState(t)
	got, err := TailHistory(dir, 5)
	if err != nil {
		t.Fatalf("TailHistory on a fresh dir: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d records from a fresh dir, want 0", len(got))
	}
}

// --- CLI layer: task 1.2's literal Verify clause ---
//
// "herald notify status --json and herald notify history --json -n 5 emit
// parseable JSON with the pipe down." Nothing in the suite called runCLI
// with these exact subcommands outside of control_test.go's cross-path
// mute-observation checks, which assert only st.Muted/st.StateDir — not
// that the CLI's JSON encoding round-trips the full shape or that -n is
// honored through the CLI flag parser specifically (a different code path
// from the HTTP handler's query-string parsing already covered in
// control_test.go).

func TestStatusCLIJSONEmitsParseableStableShape(t *testing.T) {
	dir := setupStatusTestState(t)
	if _, err := SetMute(dir, time.Hour); err != nil {
		t.Fatalf("SetMute: %v", err)
	}

	var stdout, stderr strings.Builder
	if code := runCLI([]string{"status", "--json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("herald notify status --json exited %d, stderr: %s", code, stderr.String())
	}
	if stderr.String() != "" {
		t.Errorf("stderr = %q, want empty", stderr.String())
	}
	var st Status
	if err := json.Unmarshal([]byte(stdout.String()), &st); err != nil {
		t.Fatalf("status --json produced unparseable output %q: %v", stdout.String(), err)
	}
	if st.StateDir != dir || !st.Muted || st.Version == "" {
		t.Errorf("status --json = %+v, missing expected fields", st)
	}
}

func TestHistoryCLIJSONWithNFlagEmitsParseableJSON(t *testing.T) {
	dir := setupStatusTestState(t)
	seedHistoryTexts(t, dir, "1", "2", "3", "4", "5", "6", "7", "8")

	var stdout, stderr strings.Builder
	if code := runCLI([]string{"history", "--json", "-n", "5"}, &stdout, &stderr); code != 0 {
		t.Fatalf("herald notify history --json -n 5 exited %d, stderr: %s", code, stderr.String())
	}
	var records []Record
	if err := json.Unmarshal([]byte(stdout.String()), &records); err != nil {
		t.Fatalf("history --json -n 5 produced unparseable output %q: %v", stdout.String(), err)
	}
	if len(records) != 5 {
		t.Fatalf("got %d records, want 5", len(records))
	}
	if records[len(records)-1].Text != "8" {
		t.Errorf("last record = %q, want the newest (8)", records[len(records)-1].Text)
	}
}

func TestHistoryCLIJSONEmptyIsEmptyArrayNotNull(t *testing.T) {
	setupStatusTestState(t)
	var stdout, stderr strings.Builder
	if code := runCLI([]string{"history", "--json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("herald notify history --json exited %d, stderr: %s", code, stderr.String())
	}
	if got := strings.TrimSpace(stdout.String()); got != "[]" {
		t.Errorf("body = %q, want the literal empty array [] for first-run state", got)
	}
}
