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

func TestAcceptedRequestStopUsesCapturedMappedHost(t *testing.T) {
	dir := setupSendTestState(t)
	log := filepath.Join(t.TempDir(), "ssh.log")
	t.Setenv("HERALD_FAKE_SSH_LOG", log)
	fakeSSH(t, "", "0") // SSH success alone must not confirm physical stop.
	t.Setenv(PlaybackHostEnv, "static-host")
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=original-host")
	started := make(chan struct{})
	q := NewSendQueue(SendQueueOptions{Synthesize: func(ctx context.Context, _ string, _ Voice) ([]byte, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	}, Deliver: failIfCalledDeliver(t)})
	accepted := postNotify(q, `{"text":"cancel me","target":"laptop"}`)
	var response map[string]string
	if err := json.Unmarshal(accepted.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	<-started
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=replacement-host")
	rec := httptest.NewRecorder()
	handleStop(rec, httptest.NewRequest(http.MethodPost, "/notify/stop", strings.NewReader(`{"request_id":"`+response["request_id"]+`"}`)))
	if !strings.Contains(rec.Body.String(), `"stopped":false`) {
		t.Fatalf("false physical confirmation: %s", rec.Body.String())
	}
	q.Close()
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "\noriginal-host\n") || strings.Contains(string(data), "replacement-host") || strings.Contains(string(data), "static-host") {
		t.Fatalf("wrong stop destination: %s", data)
	}
	records := waitForHistoryCount(t, dir, 1)
	if records[0].Outcome != OutcomeCanceled {
		t.Fatal(records)
	}
}

func TestDefaultDeliverUsesCapturedDestination(t *testing.T) {
	log := filepath.Join(t.TempDir(), "ssh.log")
	t.Setenv("HERALD_FAKE_SSH_LOG", log)
	fakeSSH(t, "", "0")
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=new-host")
	id := "aabbccddeeff00112233445566778899"
	defaultRequests.addWithDelivery(id, DeliveryConfig{PlaybackHost: "captured-host", Timeout: time.Second})
	defer defaultRequests.remove(id)
	audio := filepath.Join(t.TempDir(), "clip")
	if err := os.WriteFile(audio, []byte("audio"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := defaultDeliver(context.Background(), audio, id, "laptop")
	if err != nil || result.Outcome != OutcomeDelivered {
		t.Fatalf("%+v %v", result, err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "\ncaptured-host\n") || strings.Contains(string(data), "new-host") {
		t.Fatalf("destination changed: %s", data)
	}
}

func TestCLIStopUsesCapturedHostAndDuplicateIsNoop(t *testing.T) {
	log := filepath.Join(t.TempDir(), "ssh.log")
	t.Setenv("HERALD_FAKE_SSH_LOG", log)
	fakeSSH(t, "", "0")
	id := "aabbccddeeff00112233445566778899"
	defaultRequests.addWithDelivery(id, DeliveryConfig{PlaybackHost: "captured-cli-host", Timeout: time.Second})
	defer defaultRequests.remove(id)
	var out, stderr strings.Builder
	if rc := runStop([]string{id}, &out, &stderr); rc != 0 {
		t.Fatalf("%d: %s", rc, stderr.String())
	}
	if !strings.Contains(out.String(), `"stopped":false`) {
		t.Fatal(out.String())
	}
	first, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(first), "\ncaptured-cli-host\n") {
		t.Fatal(string(first))
	}
	out.Reset()
	if rc := runStop([]string{id}, &out, &stderr); rc != 0 {
		t.Fatal(rc)
	}
	if !strings.Contains(out.String(), `"status":"noop"`) {
		t.Fatal(out.String())
	}
	second, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if string(first) != string(second) {
		t.Fatal("duplicate stop contacted playback host")
	}
}
