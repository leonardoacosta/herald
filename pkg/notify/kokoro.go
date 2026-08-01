package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// BaseURLEnv names the environment variable carrying the kokoro service's base
// URL, e.g. "http://127.0.0.1:8880".
//
// There is deliberately NO default here. The service address is deployment
// configuration, and the one thing this package must never do is bake in a host
// address: the compose module binds loopback plus a tailnet address whose value
// is resolved per-host by bin/kokoro-sync.sh, and a Go-side literal would be a
// second place for that to drift. bin/lib.sh's NOTIFY_KOKORO_BASE_URL owns the
// default (loopback — synth and pipe share the execution host), where the
// operator can see and override it in $CONFIG_DIR/config alongside every other
// board's configuration.
const BaseURLEnv = "HERALD_KOKORO_BASE_URL"

// Wire contract. Mirrored from NexusShared/Synthesis/KokoroClient.swift rather
// than re-derived, so the strings on the wire stay identical either side of the
// nexus-agent retirement (task 2.1). Kokoro-FastAPI speaks an OpenAI-shaped
// speech endpoint: no auth of any kind, `model` fixed, `voice` the BARE voice
// name (never the provider-qualified form this package stores on disk).
//
// Verified live against ghcr.io/remsky/kokoro-fastapi-cpu:v0.6.0 on the
// execution host 2026-07-25: POST /v1/audio/speech returned HTTP 200 and 36909
// bytes of "Audio file with ID3 version 2.4.0 ... MPEG ADTS, layer III" — which
// afplay plays natively, so nothing downstream transcodes.
const (
	speechPath    = "/v1/audio/speech"
	speechModel   = "kokoro"
	speechFormat  = "mp3"
	contentTypeJS = "application/json"
)

// DefaultTimeout bounds one synthesis request.
//
// Sized off measured CPU synthesis, not guessed: the first request after a
// container start took 7.9s (the voice pack loads lazily on first use), and
// warm requests are a fraction of that. 30s leaves room for a cold first call
// plus a long phrase without ever letting a wedged service hold the pipe open
// indefinitely — bin/notify.sh's whole contract is that a caller is never
// blocked past a bound.
const DefaultTimeout = 30 * time.Second

// ErrNoBaseURL is returned when the service address is unconfigured. It is a
// distinct error because it is an operator-fixable configuration fault, not a
// service outage, and the history record's reason should say so.
var ErrNoBaseURL = errors.New("notify: kokoro base URL is not configured (set " + BaseURLEnv + ")")

// ResolveBaseURL reads the configured base URL, trailing slash trimmed so
// joining speechPath cannot produce a double slash. Returns "" when unset —
// NewClient turns that into ErrNoBaseURL.
func ResolveBaseURL() string {
	return strings.TrimRight(strings.TrimSpace(os.Getenv(BaseURLEnv)), "/")
}

// Client is a kokoro synthesis client. Zero external dependencies: this speaks
// plain HTTP against a service with no auth, so net/http is the whole client.
type Client struct {
	BaseURL string
	HTTP    *http.Client
}

// NewClient builds a client bound to baseURL with a bounded timeout.
//
// The timeout lands on the http.Client rather than only on a per-call context
// so that a caller who passes context.Background() still cannot hang — the
// bound is a property of the client, not something each call site must
// remember. A non-positive timeout falls back to DefaultTimeout for the same
// reason: there is no way to construct an unbounded client.
func NewClient(baseURL string, timeout time.Duration) (*Client, error) {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" {
		return nil, ErrNoBaseURL
	}
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	return &Client{BaseURL: baseURL, HTTP: &http.Client{Timeout: timeout}}, nil
}

// speechRequest is the POST body. Field names are the wire's, not ours.
type speechRequest struct {
	Model          string `json:"model"`
	Input          string `json:"input"`
	Voice          string `json:"voice"`
	ResponseFormat string `json:"response_format"`
}

// Synthesize returns the audio bytes for text spoken in v.
//
// v is the resolved, provider-qualified voice; only ProviderKokoro is
// synthesizable here. A legacy (ElevenLabs) voice is rejected up front with a
// reason naming the offending value, because the alternative — silently
// handing an ElevenLabs voice id to kokoro — produces either a confusing 400 or
// a wrong-voice success. The speak-only scope decision (proposal.md
// § Decisions) deliberately did not rebuild an ElevenLabs path.
//
// An HTTP 200 carrying zero bytes is an error too: a caller that shipped an
// empty file to the playback host would see afplay fail and record a transport
// failure for what is really a synthesis failure.
func (c *Client) Synthesize(ctx context.Context, text string, v Voice) ([]byte, error) {
	if strings.TrimSpace(text) == "" {
		return nil, errors.New("notify: nothing to synthesize (empty text)")
	}
	if v.Provider != ProviderKokoro {
		return nil, fmt.Errorf("notify: voice %q is a %s voice; this pipe synthesizes %s only",
			v.String(), v.Provider, ProviderKokoro)
	}

	body, err := json.Marshal(speechRequest{
		Model:          speechModel,
		Input:          text,
		Voice:          v.Voice,
		ResponseFormat: speechFormat,
	})
	if err != nil {
		return nil, fmt.Errorf("notify: encode speech request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+speechPath, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("notify: build speech request: %w", err)
	}
	req.Header.Set("Content-Type", contentTypeJS)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("notify: kokoro request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Include a slice of the body: kokoro reports an unknown voice as a
		// JSON error payload, and that text is what makes the history
		// record's reason actionable rather than a bare "400".
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("notify: kokoro returned %s: %s",
			resp.Status, strings.TrimSpace(string(snippet)))
	}

	audio, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("notify: read kokoro audio: %w", err)
	}
	if len(audio) == 0 {
		return nil, errors.New("notify: kokoro returned 200 with no audio")
	}
	return audio, nil
}
