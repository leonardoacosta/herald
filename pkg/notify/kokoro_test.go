package notify

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The wire contract task 2.1 pins: POST /v1/audio/speech, model "kokoro",
// response_format "mp3", the BARE voice name, and no auth header. Asserted
// against a stub rather than the live service so the contract is checked on
// every run, including on a host with no kokoro container.
func TestSynthesizeSpeaksTheKokoroWireContract(t *testing.T) {
	var (
		gotPath   string
		gotMethod string
		gotAuth   string
		gotType   string
		gotBody   speechRequest
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotMethod = r.URL.Path, r.Method
		gotAuth = r.Header.Get("Authorization")
		gotType = r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		_, _ = w.Write([]byte("ID3-ish-audio-bytes"))
	}))
	defer srv.Close()

	c, err := NewClient(srv.URL, time.Second)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	audio, err := c.Synthesize(context.Background(), "wave one landed", ParseQualified("kokoro:af_bella"))
	if err != nil {
		t.Fatalf("Synthesize: %v", err)
	}

	if gotPath != "/v1/audio/speech" {
		t.Errorf("path = %q, want /v1/audio/speech", gotPath)
	}
	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotAuth != "" {
		t.Errorf("sent an Authorization header (%q) to a service with no auth", gotAuth)
	}
	if gotType != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotType)
	}
	if gotBody.Model != "kokoro" || gotBody.ResponseFormat != "mp3" || gotBody.Input != "wave one landed" {
		t.Errorf("body = %+v, want model=kokoro response_format=mp3 with the input text", gotBody)
	}
	// The provider prefix is a local storage convention — it must never reach
	// the wire, where kokoro expects a bare voice name.
	if gotBody.Voice != "af_bella" {
		t.Errorf("voice on the wire = %q, want the bare name af_bella", gotBody.Voice)
	}
	if string(audio) != "ID3-ish-audio-bytes" {
		t.Errorf("audio = %q, want the response body verbatim", audio)
	}
}

// Task 4.5's named seam: the client's timeout actually bounds a call. A server
// that never answers must produce an error QUICKLY, not hang — this is the
// property that makes bin/notify.sh's "never blocks the caller" contract true
// on the synthesis leg.
func TestSynthesizeIsBoundedByItsTimeout(t *testing.T) {
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-block // never answers until the test releases it
	}))
	defer srv.Close()
	defer close(block)

	c, err := NewClient(srv.URL, 150*time.Millisecond)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}

	start := time.Now()
	_, err = c.Synthesize(context.Background(), "hello", ParseQualified(DefaultVoice))
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Synthesize returned nil error against a server that never answered")
	}
	// Generous ceiling — the assertion is "bounded", not "precise to the ms".
	if elapsed > 5*time.Second {
		t.Errorf("Synthesize took %v against a 150ms timeout — the bound did not hold", elapsed)
	}
}

// A non-positive timeout must not construct an unbounded client — there is no
// way to opt out of the bound.
func TestNewClientRejectsAnUnboundedTimeout(t *testing.T) {
	c, err := NewClient("http://127.0.0.1:8880", 0)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if c.HTTP.Timeout != DefaultTimeout {
		t.Errorf("timeout = %v, want the %v default rather than unbounded", c.HTTP.Timeout, DefaultTimeout)
	}
}

// No base URL is a configuration fault with its own error, so the history
// record's reason can name it instead of reporting a connection failure.
func TestNewClientRequiresABaseURL(t *testing.T) {
	for _, in := range []string{"", "   "} {
		if _, err := NewClient(in, time.Second); !errors.Is(err, ErrNoBaseURL) {
			t.Errorf("NewClient(%q) error = %v, want ErrNoBaseURL", in, err)
		}
	}
}

// ResolveBaseURL has NO built-in default (the loopback default lives in
// bin/lib.sh) and trims a trailing slash so the joined path stays well-formed.
func TestResolveBaseURLHasNoBakedInDefault(t *testing.T) {
	t.Setenv(BaseURLEnv, "")
	if got := ResolveBaseURL(); got != "" {
		t.Errorf("ResolveBaseURL() = %q with the env unset, want \"\" — no address may be baked into Go", got)
	}
	t.Setenv(BaseURLEnv, "http://127.0.0.1:8880/")
	if got := ResolveBaseURL(); got != "http://127.0.0.1:8880" {
		t.Errorf("ResolveBaseURL() = %q, want the trailing slash trimmed", got)
	}
}

// A legacy/ElevenLabs voice is rejected before any request goes out — the
// speak-only scope never rebuilt that provider, and silently sending an
// ElevenLabs voice id to kokoro is the confusing failure this prevents.
func TestSynthesizeRejectsANonKokoroVoice(t *testing.T) {
	reached := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, time.Second)
	// A bare, unqualified value resolves to the legacy provider (voice.go).
	_, err := c.Synthesize(context.Background(), "hello", ParseQualified("21m00Tcm4TlvDq8ikWAM"))
	if err == nil {
		t.Fatal("Synthesize accepted an elevenlabs voice")
	}
	if !strings.Contains(err.Error(), ProviderLegacy) {
		t.Errorf("error = %v, want it to name the offending provider", err)
	}
	if reached {
		t.Error("a rejected voice still produced an HTTP request")
	}
}

// A non-200 carries the server's own message into the error, which is what
// makes the resulting history record actionable ("voice not found") rather
// than a bare status code.
func TestSynthesizeSurfacesTheServerMessage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"detail":"Voice 'af_nope' not found"}`))
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, time.Second)
	_, err := c.Synthesize(context.Background(), "hello", ParseQualified("kokoro:af_nope"))
	if err == nil {
		t.Fatal("Synthesize returned nil error on a 400")
	}
	if !strings.Contains(err.Error(), "af_nope") {
		t.Errorf("error = %v, want the server's own message included", err)
	}
}

// A 200 with an empty body is a synthesis failure, not a delivery of silence:
// shipping zero bytes would make afplay fail and mis-record the outcome as a
// transport problem.
func TestSynthesizeRejectsAnEmptyBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c, _ := NewClient(srv.URL, time.Second)
	if _, err := c.Synthesize(context.Background(), "hello", ParseQualified(DefaultVoice)); err == nil {
		t.Fatal("Synthesize accepted a 200 carrying no audio")
	}
}

func TestSynthesizeRejectsEmptyText(t *testing.T) {
	c, _ := NewClient("http://127.0.0.1:8880", time.Second)
	if _, err := c.Synthesize(context.Background(), "   ", ParseQualified(DefaultVoice)); err == nil {
		t.Fatal("Synthesize accepted empty text")
	}
}
