package notify

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestPostNotifyEndToEndUsesOnlyLocalDoubles exercises the complete local
// service boundary: real HTTP routing, POST /notify validation, queue worker,
// history persistence, and delivery target resolution. The synthesizer and
// delivery transport are doubles, so this test never contacts Kokoro, ssh, or
// a playback host.
func TestPostNotifyEndToEndUsesOnlyLocalDoubles(t *testing.T) {
	dir := setupSendTestState(t)
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "known=configured-playback")

	var mu sync.Mutex
	var deliveredHosts []string
	q := NewSendQueue(SendQueueOptions{
		Synthesize: func(context.Context, string, Voice) ([]byte, error) {
			return []byte("fake-audio"), nil
		},
		Deliver: func(_ context.Context, _ string, requestIDs ...string) (DeliveryResult, error) {
			client := ""
			if len(requestIDs) > 1 {
				client = requestIDs[1]
			}
			host := resolvePlaybackHost(DeliveryConfig{PlaybackHost: "fallback-playback"}, client)
			mu.Lock()
			deliveredHosts = append(deliveredHosts, host)
			mu.Unlock()
			return DeliveryResult{Outcome: OutcomeDelivered}, nil
		},
	})
	defer q.Close()

	srv := httptest.NewServer(qHandler(q))
	defer srv.Close()

	post := func(body string) *http.Response {
		r, err := http.Post(srv.URL+"/notify", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatalf("POST /notify: %v", err)
		}
		return r
	}

	resp := post(`{"text":"known target","project":"hs","target":"known"}`)
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("known target status = %d, want 202", resp.StatusCode)
	}
	resp.Body.Close()

	resp = post(`{"text":"fallback target","project":"hs","target":"unconfigured-client"}`)
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("fallback target status = %d, want 202", resp.StatusCode)
	}
	resp.Body.Close()

	records := waitForHistoryCount(t, dir, 2)
	mu.Lock()
	hosts := append([]string(nil), deliveredHosts...)
	mu.Unlock()
	if len(hosts) != 2 || hosts[0] != "configured-playback" || hosts[1] != "fallback-playback" {
		t.Fatalf("resolved delivery hosts = %v, want configured then fallback", hosts)
	}
	if records[0].Target != "known" || records[1].Target != "unconfigured-client" {
		t.Fatalf("history targets = %q, %q; want request identities preserved", records[0].Target, records[1].Target)
	}

	for _, body := range []string{
		`{"text":"unknown target","project":"hs","target":"bad/target"}`,
		`{"text":"host injection","project":"hs","target":"attacker;rm -rf /"}`,
		`{"text":"host injection","project":"hs","target":"ssh://attacker"}`,
	} {
		resp = post(body)
		if resp.StatusCode != http.StatusBadRequest {
			var got any
			_ = json.NewDecoder(resp.Body).Decode(&got)
			resp.Body.Close()
			t.Fatalf("unsafe/unknown target %s status = %d, want 400", body, resp.StatusCode)
		}
		resp.Body.Close()
	}

	// Rejected requests must not reach either worker double or append history.
	time.Sleep(25 * time.Millisecond)
	if got, err := ReadHistory(dir); err != nil {
		t.Fatal(err)
	} else if len(got) != 2 {
		t.Fatalf("rejected requests changed history: got %d records", len(got))
	}
}

func qHandler(q *SendQueue) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/notify", q.HandleNotify)
	return mux
}
