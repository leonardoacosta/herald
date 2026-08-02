package notify

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// notify-service task 1.6. Every test here points HERALD_STATE_DIR at
// t.TempDir() — Leo's real state dir carries ~465 live history records, and
// a test that sets a real mute against it is a defect.

func setupControlTestState(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv(StateDirEnv, dir)
	return dir
}

func doControl(handler http.HandlerFunc, method, target, body string) *httptest.ResponseRecorder {
	var req *http.Request
	if body == "" {
		req = httptest.NewRequest(method, target, nil)
	} else {
		req = httptest.NewRequest(method, target, strings.NewReader(body))
	}
	rec := httptest.NewRecorder()
	handler(rec, req)
	return rec
}

func decodeJSON(t *testing.T, rec *httptest.ResponseRecorder, v any) {
	t.Helper()
	if err := json.Unmarshal(rec.Body.Bytes(), v); err != nil {
		t.Fatalf("decode response body %s: %v", rec.Body.String(), err)
	}
}

// --- POST /mute ---

func TestHandleMuteAcceptsCLIVocabulary(t *testing.T) {
	dir := setupControlTestState(t)
	rec := doControl(handleMute, http.MethodPost, "/mute", `{"duration":"30s"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}

	var resp struct {
		Muted bool      `json:"muted"`
		Until time.Time `json:"until"`
	}
	decodeJSON(t, rec, &resp)
	if !resp.Muted {
		t.Fatal("response reports muted = false after a successful POST /mute")
	}
	wantUntil := time.Now().Add(30 * time.Second)
	if resp.Until.Before(wantUntil.Add(-5*time.Second)) || resp.Until.After(wantUntil.Add(5*time.Second)) {
		t.Errorf("until = %s, want close to %s", resp.Until, wantUntil)
	}

	muted, _, err := MuteState(dir)
	if err != nil {
		t.Fatalf("MuteState: %v", err)
	}
	if !muted {
		t.Error("mute file on disk does not reflect the HTTP mute call")
	}
}

func TestHandleMuteDefaultsDurationWhenBodyOmitted(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleMute, http.MethodPost, "/mute", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Muted bool      `json:"muted"`
		Until time.Time `json:"until"`
	}
	decodeJSON(t, rec, &resp)
	if !resp.Muted {
		t.Fatal("empty-body POST /mute did not mute")
	}
	// defaultMuteSpec is "1h" — assert the expiry landed near now+1h, not
	// near now+0 (which would mean the default silently became a no-op).
	wantUntil := time.Now().Add(time.Hour)
	if resp.Until.Before(wantUntil.Add(-5*time.Second)) || resp.Until.After(wantUntil.Add(5*time.Second)) {
		t.Errorf("until = %s, want close to the 1h default %s", resp.Until, wantUntil)
	}
}

func TestHandleMuteRejectsMalformedDuration(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleMute, http.MethodPost, "/mute", `{"duration":"500ms"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 for a duration ParseMuteDuration rejects (body %s)", rec.Code, rec.Body.String())
	}
	muted, _, err := MuteState(ResolveStateDir())
	if err != nil {
		t.Fatalf("MuteState: %v", err)
	}
	if muted {
		t.Error("a rejected duration must not leave the service muted")
	}
}

func TestHandleMuteRejectsMalformedBody(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleMute, http.MethodPost, "/mute", `{not json`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 for malformed JSON (body %s)", rec.Code, rec.Body.String())
	}
}

func TestHandleMuteMethodNotAllowed(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleMute, http.MethodGet, "/mute", "")
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405 for GET /mute", rec.Code)
	}
}

// --- POST /unmute ---

func TestHandleUnmuteClearsAnActiveMute(t *testing.T) {
	dir := setupControlTestState(t)
	if _, err := SetMute(dir, time.Hour); err != nil {
		t.Fatalf("SetMute: %v", err)
	}

	rec := doControl(handleUnmute, http.MethodPost, "/unmute", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Muted bool `json:"muted"`
	}
	decodeJSON(t, rec, &resp)
	if resp.Muted {
		t.Fatal("response reports muted = true after a successful POST /unmute")
	}

	muted, _, err := MuteState(dir)
	if err != nil {
		t.Fatalf("MuteState: %v", err)
	}
	if muted {
		t.Error("mute file on disk still reports muted after the HTTP unmute call")
	}
}

func TestHandleUnmuteWhenNotMutedIsANoOp(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleUnmute, http.MethodPost, "/unmute", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 for unmuting an already-unmuted service", rec.Code)
	}
}

func TestHandleUnmuteMethodNotAllowed(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleUnmute, http.MethodGet, "/unmute", "")
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405 for GET /unmute", rec.Code)
	}
}

// --- GET /status ---

func TestHandleStatusEmitsTheSameShapeAsCLIJSON(t *testing.T) {
	dir := setupControlTestState(t)
	if _, err := SetMute(dir, time.Hour); err != nil {
		t.Fatalf("SetMute: %v", err)
	}

	rec := doControl(handleStatus, http.MethodGet, "/status", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var st Status
	decodeJSON(t, rec, &st)
	if st.StateDir != dir {
		t.Errorf("StateDir = %q, want %q", st.StateDir, dir)
	}
	if !st.Muted {
		t.Error("Status.Muted = false, want true after SetMute")
	}
	if st.Version == "" {
		t.Error("Status.Version is empty")
	}
}

func TestHandleStatusMethodNotAllowed(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleStatus, http.MethodPost, "/status", "")
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405 for POST /status", rec.Code)
	}
}

// --- GET /history ---

func seedHistory(t *testing.T, dir string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if err := AppendRecord(dir, Record{
			Project: "hs", Text: "seed", Voice: "af_heart", Outcome: OutcomeDelivered,
		}); err != nil {
			t.Fatalf("AppendRecord: %v", err)
		}
	}
}

func TestHandleHistoryDefaultsToTen(t *testing.T) {
	dir := setupControlTestState(t)
	seedHistory(t, dir, 15)

	rec := doControl(handleHistory, http.MethodGet, "/history", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var records []Record
	decodeJSON(t, rec, &records)
	if len(records) != 10 {
		t.Errorf("len(records) = %d, want 10 (runHistory's own -n default)", len(records))
	}
}

func TestHandleHistoryRespectsExplicitN(t *testing.T) {
	dir := setupControlTestState(t)
	seedHistory(t, dir, 5)

	rec := doControl(handleHistory, http.MethodGet, "/history?n=2", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var records []Record
	decodeJSON(t, rec, &records)
	if len(records) != 2 {
		t.Errorf("len(records) = %d, want 2", len(records))
	}
}

func TestHandleHistoryZeroNReturnsEverything(t *testing.T) {
	dir := setupControlTestState(t)
	seedHistory(t, dir, 3)

	rec := doControl(handleHistory, http.MethodGet, "/history?n=0", "")
	var records []Record
	decodeJSON(t, rec, &records)
	if len(records) != 3 {
		t.Errorf("len(records) = %d, want 3 for n=0 (TailHistory's n<=0 means \"all\")", len(records))
	}
}

func TestHandleHistoryEmptyHistoryReturnsEmptyArrayNotNull(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleHistory, http.MethodGet, "/history", "")
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("body = %s, want the literal empty array [] for first-run state", rec.Body.String())
	}
}

func TestHandleHistoryMalformedNReturns400(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleHistory, http.MethodGet, "/history?n=notanumber", "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 for a non-integer n (body %s)", rec.Code, rec.Body.String())
	}
}

func TestHandleHistoryMethodNotAllowed(t *testing.T) {
	setupControlTestState(t)
	rec := doControl(handleHistory, http.MethodPost, "/history", "")
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405 for POST /history", rec.Code)
	}
}

// --- Cross-path: the STOP-condition guard ---
//
// proposal.md `## STOP conditions`: "Mute semantics diverging between the
// API path and the fallback path — the whole point of the consolidation is
// that one implementation decides it." Task 1.6 names this explicitly:
// "mute set via HTTP is observed by the CLI path and vice versa." Both
// directions are asserted below, each going through the REAL entry point
// for its side (handleMute for HTTP, runCLI for the CLI) rather than
// calling MuteState/SetMute directly for both — that would only prove the
// shared function works, not that the two surfaces actually agree.

func TestMuteSetViaHTTPIsObservedByTheCLIPath(t *testing.T) {
	dir := setupControlTestState(t)

	rec := doControl(handleMute, http.MethodPost, "/mute", `{"duration":"1h"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST /mute status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}

	var stdout, stderr strings.Builder
	if code := runCLI([]string{"status", "--json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("herald notify status --json exited %d, stderr: %s", code, stderr.String())
	}
	var st Status
	if err := json.Unmarshal([]byte(stdout.String()), &st); err != nil {
		t.Fatalf("decode CLI status output %s: %v", stdout.String(), err)
	}
	if !st.Muted {
		t.Fatal("`herald notify status` does not observe a mute set through POST /mute — mute semantics have diverged between the API and CLI paths")
	}
	if st.StateDir != dir {
		t.Fatalf("CLI status read a different state dir than the test set up: got %q want %q", st.StateDir, dir)
	}
}

func TestMuteSetViaCLIIsObservedByHTTP(t *testing.T) {
	setupControlTestState(t)

	var stdout, stderr strings.Builder
	if code := runCLI([]string{"mute", "1h"}, &stdout, &stderr); code != 0 {
		t.Fatalf("herald notify mute 1h exited %d, stderr: %s", code, stderr.String())
	}

	rec := doControl(handleStatus, http.MethodGet, "/status", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /status status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var st Status
	decodeJSON(t, rec, &st)
	if !st.Muted {
		t.Fatal("GET /status does not observe a mute set through `herald notify mute` — mute semantics have diverged between the CLI and API paths")
	}
}
