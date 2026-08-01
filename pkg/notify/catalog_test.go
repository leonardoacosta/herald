package notify

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCatalogParsesVoices(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/audio/voices" {
			t.Errorf("catalog request = %s %s, want GET /v1/audio/voices", r.Method, r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"voices":[{"id":"af_heart","name":"Heart"},{"id":"af_bella","name":"Bella"}]}`))
	}))
	defer srv.Close()

	client, err := NewClient(srv.URL, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	got, err := client.Catalog(context.Background())
	if err != nil {
		t.Fatalf("Catalog: %v", err)
	}
	if len(got) != 2 || got[0].ID != "af_heart" || got[0].Name != "Heart" || got[1].ID != "af_bella" {
		t.Fatalf("Catalog = %+v, want the response voices in order", got)
	}
}

func TestCatalogRejectsInvalidResponses(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   string
	}{
		{name: "malformed", status: http.StatusOK, body: `{"voices":`, want: "decode"},
		{name: "non-200", status: http.StatusServiceUnavailable, body: `catalog offline`, want: "catalog offline"},
		{name: "empty id", status: http.StatusOK, body: `{"voices":[{"id":"","name":"empty"}]}`, want: "empty"},
		{name: "duplicate id", status: http.StatusOK, body: `{"voices":[{"id":"af_heart"},{"id":"af_heart"}]}`, want: "duplicate"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			client, _ := NewClient(srv.URL, time.Second)
			_, err := client.Catalog(context.Background())
			if err == nil || !strings.Contains(strings.ToLower(err.Error()), strings.ToLower(tc.want)) {
				t.Fatalf("Catalog error = %v, want it to contain %q", err, tc.want)
			}
		})
	}
}

func TestCatalogReportsUnreachableEndpoint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close()
	client, _ := NewClient(url, 100*time.Millisecond)
	if _, err := client.Catalog(context.Background()); err == nil {
		t.Fatal("Catalog accepted an unreachable endpoint")
	}
}

func TestValidateKokoroSelectionChecksEveryBlendComponent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"voices":[{"id":"af_heart"},{"id":"af_bella"}]}`))
	}))
	defer srv.Close()
	client, _ := NewClient(srv.URL, time.Second)

	for _, value := range []string{"kokoro:af_heart", "kokoro:af_heart+af_bella(2)"} {
		if err := client.ValidateVoice(context.Background(), ParseQualified(value)); err != nil {
			t.Errorf("ValidateVoice(%q): %v", value, err)
		}
	}
	if err := client.ValidateVoice(context.Background(), ParseQualified("kokoro:af_heart+af_missing(2)")); err == nil || !strings.Contains(err.Error(), "af_missing") {
		t.Fatalf("unknown blend component error = %v, want af_missing", err)
	}
	if err := client.ValidateVoice(context.Background(), ParseQualified("legacy-id")); err == nil {
		t.Fatal("ValidateVoice accepted a non-Kokoro selection")
	}
}

func TestAuditionUsesFixedTextWithoutMutatingStateOrHistory(t *testing.T) {
	var request speechRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != speechPath {
			t.Errorf("audition path = %q, want %q", r.URL.Path, speechPath)
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode audition request: %v", err)
		}
		_, _ = w.Write([]byte("audition-audio"))
	}))
	defer srv.Close()

	stateDir := t.TempDir()
	voicesBefore := []byte("{\n  \"default\": \"kokoro:af_heart\"\n}\n")
	historyBefore := []byte("{\"outcome\":\"delivered\"}\n")
	if err := os.WriteFile(VoicesPath(stateDir), voicesBefore, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(HistoryPath(stateDir), historyBefore, 0o600); err != nil {
		t.Fatal(err)
	}

	client, _ := NewClient(srv.URL, time.Second)
	if err := client.Audition(context.Background(), ParseQualified("kokoro:af_bella")); err != nil {
		t.Fatalf("Audition: %v", err)
	}
	if request.Input != AuditionText || request.Voice != "af_bella" {
		t.Fatalf("audition request = %+v, want fixed text and af_bella", request)
	}
	voicesAfter, _ := os.ReadFile(filepath.Join(stateDir, voicesFile))
	historyAfter, _ := os.ReadFile(filepath.Join(stateDir, historyFile))
	if string(voicesAfter) != string(voicesBefore) || string(historyAfter) != string(historyBefore) {
		t.Fatalf("audition mutated state: voices=%q history=%q", voicesAfter, historyAfter)
	}
}

func TestAuditionRejectsServerFailureAndEmptyAudio(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{name: "server failure", status: http.StatusInternalServerError, body: "synthesis failed"},
		{name: "empty audio", status: http.StatusOK, body: ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			client, _ := NewClient(srv.URL, time.Second)
			if err := client.Audition(context.Background(), ParseQualified(DefaultVoice)); err == nil {
				t.Fatalf("Audition accepted %s", tc.name)
			}
		})
	}
}
