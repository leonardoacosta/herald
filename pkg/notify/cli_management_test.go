package notify

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func runManagementCLI(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	rc := runCLI(args, &stdout, &stderr)
	return rc, stdout.String(), stderr.String()
}

func setupManagementState(t *testing.T) string {
	t.Helper()
	registry := writeRegistryFixture(t, `
[[projects]]
code = "hs"
path = "dev/personal/herdr-shepherd"
[[projects]]
code = "cc"
path = ".claude"
`)
	state := t.TempDir()
	t.Setenv(HeraldProjectsEnv, registry)
	t.Setenv(StateDirEnv, state)
	return state
}

func TestVoicesCLIReadsEffectiveStateWithoutCatalog(t *testing.T) {
	state := setupManagementState(t)
	t.Setenv(BaseURLEnv, "http://127.0.0.1:1")
	if err := WriteVoices(state, Voices{
		Default:  "kokoro:af_heart",
		Projects: map[string]string{"hs": "legacy-id"},
	}); err != nil {
		t.Fatal(err)
	}

	rc, stdout, stderr := runManagementCLI(t, "voices", "--json")
	if rc != 0 || stderr != "" {
		t.Fatalf("voices rc=%d stderr=%q", rc, stderr)
	}
	var got []EffectiveVoice
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("voices JSON %q: %v", stdout, err)
	}
	if len(got) != 2 || got[0].Project != "hs" || got[0].Effective != "elevenlabs:legacy-id" || got[0].Source != VoiceSourceProject || got[1].Source != VoiceSourceDefault {
		t.Fatalf("voices JSON = %+v", got)
	}

	rc, stdout, stderr = runManagementCLI(t, "voices")
	if rc != 0 || stderr != "" || stdout != "hs\tlegacy-id\televenlabs:legacy-id\tproject\ncc\t\tkokoro:af_heart\tdefault\n" {
		t.Fatalf("voices lines rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
}

func TestCatalogCLIEmitsStableJSONAndLines(t *testing.T) {
	setupManagementState(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"voices":[{"id":"af_heart","name":"Heart"},{"id":"af_bella","name":"Bella"}]}`))
	}))
	defer srv.Close()
	t.Setenv(BaseURLEnv, srv.URL)

	rc, stdout, stderr := runManagementCLI(t, "catalog", "--json")
	if rc != 0 || stderr != "" || stdout != "[{\"id\":\"af_heart\",\"name\":\"Heart\"},{\"id\":\"af_bella\",\"name\":\"Bella\"}]\n" {
		t.Fatalf("catalog JSON rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	rc, stdout, stderr = runManagementCLI(t, "catalog")
	if rc != 0 || stderr != "" || stdout != "af_heart\tHeart\naf_bella\tBella\n" {
		t.Fatalf("catalog lines rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
}

func TestSetAndResetVoiceCLI(t *testing.T) {
	state := setupManagementState(t)
	if err := WriteVoices(state, Voices{
		Default:  "legacy-default",
		Projects: map[string]string{"cc": "legacy-cc", "hs": "kokoro:af_heart"},
	}); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"voices":[{"id":"af_heart"},{"id":"af_bella"}]}`))
	}))
	defer srv.Close()
	t.Setenv(BaseURLEnv, srv.URL)

	rc, stdout, stderr := runManagementCLI(t, "set", "--project", "hs", "--voice", "kokoro:af_missing")
	if rc == 0 || stdout != "" || !strings.Contains(stderr, "af_missing") {
		t.Fatalf("unknown set rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	beforeValid, _ := ReadVoices(state)
	if beforeValid.Projects["hs"] != "kokoro:af_heart" {
		t.Fatalf("rejected set changed state: %+v", beforeValid)
	}

	rc, stdout, stderr = runManagementCLI(t, "set", "--project", "hs", "--voice", "kokoro:af_bella")
	if rc != 0 || stdout != "hs\tkokoro:af_bella\n" || stderr != "" {
		t.Fatalf("valid set rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	afterSet, _ := ReadVoices(state)
	if afterSet.Default != "legacy-default" || afterSet.Projects["cc"] != "legacy-cc" || afterSet.Projects["hs"] != "kokoro:af_bella" {
		t.Fatalf("valid set rewrote unrelated state: %+v", afterSet)
	}

	rc, stdout, stderr = runManagementCLI(t, "reset", "--project", "hs")
	if rc != 0 || stdout != "hs\televenlabs:legacy-default\n" || stderr != "" {
		t.Fatalf("reset rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	afterReset, _ := ReadVoices(state)
	if _, exists := afterReset.Projects["hs"]; exists || afterReset.Projects["cc"] != "legacy-cc" {
		t.Fatalf("reset changed wrong mappings: %+v", afterReset)
	}
}

func TestSetDefaultVoiceCLIWithSpeed(t *testing.T) {
	state := setupManagementState(t)
	if err := WriteVoices(state, Voices{
		Default:  "legacy-default",
		Projects: map[string]string{"cc": "legacy-cc"},
	}); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"voices":[{"id":"af_heart"},{"id":"af_bella"}]}`))
	}))
	defer srv.Close()
	t.Setenv(BaseURLEnv, srv.URL)

	rc, stdout, stderr := runManagementCLI(t, "set", "--default", "--voice", "kokoro:af_heart+af_bella(2)", "--speed", "0.95")
	if rc != 0 || stdout != "default\tkokoro:af_heart+af_bella(2)\n" || stderr != "" {
		t.Fatalf("set default rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	afterSet, err := ReadVoices(state)
	if err != nil {
		t.Fatal(err)
	}
	if afterSet.Default != "kokoro:af_heart+af_bella(2)" || afterSet.DefaultSpeed != 0.95 || afterSet.Projects["cc"] != "legacy-cc" {
		t.Fatalf("set default rewrote unrelated state or lost prosody: %+v", afterSet)
	}
	info, err := os.Stat(VoicesPath(state))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("voices.json mode = %v err=%v, want 0600", info.Mode().Perm(), err)
	}
}

func TestAuditionCLIIsFixedTextAndDoesNotWriteHistory(t *testing.T) {
	state := setupManagementState(t)
	var spoken string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case catalogPath:
			_, _ = w.Write([]byte(`{"voices":[{"id":"af_bella"}]}`))
		case speechPath:
			var request speechRequest
			_ = json.NewDecoder(r.Body).Decode(&request)
			spoken = request.Input
			_, _ = w.Write([]byte("audio"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	t.Setenv(BaseURLEnv, srv.URL)

	rc, stdout, stderr := runManagementCLI(t, "audition", "--voice", "kokoro:af_bella")
	if rc != 0 || stdout != "kokoro:af_bella\n" || stderr != "" || spoken != AuditionText {
		t.Fatalf("audition rc=%d stdout=%q stderr=%q spoken=%q", rc, stdout, stderr, spoken)
	}
	if _, err := os.Stat(HistoryPath(state)); !os.IsNotExist(err) {
		t.Fatalf("audition created history: %v", err)
	}
	rc, _, _ = runManagementCLI(t, "audition", "--voice", "kokoro:af_bella", "--text", "private words")
	if rc == 0 {
		t.Fatal("audition accepted arbitrary text")
	}
}

func TestManagementCLIValidatesArgumentsAndCanonicalProjects(t *testing.T) {
	setupManagementState(t)
	client := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"voices":[{"id":"af_heart"}]}`))
	}))
	defer client.Close()
	t.Setenv(BaseURLEnv, client.URL)

	for _, args := range [][]string{
		{"set", "--project", "hs"},
		{"set", "--voice", DefaultVoice},
		{"set", "--default", "--project", "hs", "--voice", DefaultVoice},
		{"set", "--default", "--voice", DefaultVoice, "--speed", "0.49"},
		{"set", "--default", "--voice", DefaultVoice, "--speed", "2.01"},
		{"set", "--project", "unknown", "--voice", DefaultVoice},
		{"reset"},
		{"reset", "--project", "unknown"},
		{"audition"},
		{"voices", "extra"},
		{"catalog", "extra"},
	} {
		rc, _, _ := runManagementCLI(t, args...)
		if rc == 0 {
			t.Errorf("runCLI(%v) succeeded, want argument error", args)
		}
	}
}

func TestCatalogClientTimeoutRemainsBoundedThroughCLI(t *testing.T) {
	setupManagementState(t)
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { <-block }))
	defer srv.Close()
	defer close(block)
	t.Setenv(BaseURLEnv, srv.URL)

	start := time.Now()
	rc, _, _ := runManagementCLI(t, "catalog", "--timeout", "0.05")
	if rc == 0 || time.Since(start) > 5*time.Second {
		t.Fatalf("bounded catalog rc=%d elapsed=%v", rc, time.Since(start))
	}
}

func TestSynthAndRecordCLICarryEffectiveSpeedIntoHistory(t *testing.T) {
	state := t.TempDir()
	t.Setenv(StateDirEnv, state)
	if err := os.WriteFile(VoicesPath(state), []byte(`{
  "default": "kokoro:af_heart",
  "projects": {"hs": {"voice": "kokoro:af_bella", "speed": 0.95}}
}
`), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("audio"))
	}))
	defer srv.Close()
	t.Setenv(BaseURLEnv, srv.URL)
	audioPath := filepath.Join(t.TempDir(), "audio.mp3")
	speedPath := filepath.Join(t.TempDir(), "speed")

	rc, stdout, stderr := runManagementCLI(t, "synth", "--project", "hs", "--text", "hello", "--out", audioPath, "--speed-out", speedPath)
	if rc != 0 || stdout != "kokoro:af_bella\n" || stderr != "" {
		t.Fatalf("synth rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	speedBytes, err := os.ReadFile(speedPath)
	if err != nil || string(speedBytes) != "0.95\n" {
		t.Fatalf("speed metadata = %q err=%v", speedBytes, err)
	}

	rc, stdout, stderr = runManagementCLI(t, "record", "--project", "hs", "--text", "hello", "--voice", "kokoro:af_bella", "--speed", "0.95", "--outcome", OutcomeDelivered)
	if rc != 0 || stdout != "" || stderr != "" {
		t.Fatalf("record rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	history, err := ReadHistory(state)
	if err != nil || len(history) != 1 || history[0].Voice != "kokoro:af_bella" || history[0].Speed != 0.95 {
		t.Fatalf("history = %+v err=%v", history, err)
	}
}
