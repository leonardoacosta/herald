package notify

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHandleStopDuplicateIsNoopWithoutRemoteStop(t *testing.T) {
	id := "0123456789abcdef0123456789abcdef"
	old := defaultRequests
	defaultRequests = newRequestRegistry()
	t.Cleanup(func() { defaultRequests = old })
	state := defaultRequests.addWithDelivery(id, DeliveryConfig{PlaybackHost: "invalid-unused-host"})
	if _, changed := state.stop(); !changed {
		t.Fatal("failed to establish terminal state")
	}

	req := httptest.NewRequest(http.MethodPost, "/notify/stop", strings.NewReader(`{"request_id":"`+id+`"}`))
	rec := httptest.NewRecorder()
	handleStop(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, `"status":"noop"`) || !strings.Contains(body, `"stopped":false`) {
		t.Fatalf("duplicate stop response = %s, want noop/stopped false", body)
	}
}
