package notify

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestShutdownCancelsAndRecordsAcceptedBacklog(t *testing.T) {
	dir := setupSendTestState(t)
	started := make(chan struct{})
	q := NewSendQueue(SendQueueOptions{Synthesize: func(ctx context.Context, _ string, _ Voice) ([]byte, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	}, Deliver: failIfCalledDeliver(t)})
	postNotify(q, `{"text":"first"}`)
	<-started
	postNotify(q, `{"text":"second"}`)
	if err := q.shutdownWithin(20*time.Millisecond, time.Second); err != nil {
		t.Fatal(err)
	}
	records := waitForHistoryCount(t, dir, 2)
	for _, r := range records {
		if r.Outcome != OutcomeCanceled || r.RequestID == "" {
			t.Fatalf("bad terminal record: %+v", r)
		}
	}
	if q.Stats().Completed != 2 {
		t.Fatal(q.Stats())
	}
	if postNotify(q, `{"text":"late"}`).Code != 503 {
		t.Fatal("accepted after shutdown")
	}
}

func TestHistoryWriteFailuresAreObservableAndDoNotStopWorker(t *testing.T) {
	dir := setupSendTestState(t)
	// A directory at the file path fails even when tests run as root.
	if err := os.Mkdir(filepath.Join(dir, historyFile), 0700); err != nil {
		t.Fatal(err)
	}
	q := NewSendQueue(SendQueueOptions{Synthesize: func(context.Context, string, Voice) ([]byte, error) { return nil, errors.New("synthetic failure") }})
	postNotify(q, `{"text":"private notification"}`)
	deadline := time.Now().Add(time.Second)
	for q.Stats().Completed != 1 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if q.Stats().HistoryWriteFailures != 1 {
		t.Fatalf("missing history failure: %+v", q.Stats())
	}
	if err := os.Remove(filepath.Join(dir, historyFile)); err != nil {
		t.Fatal(err)
	}
	postNotify(q, `{"text":"next"}`)
	q.Close()
	records := waitForHistoryCount(t, dir, 1)
	if records[0].Text != "next" || q.Stats().Completed != 2 {
		t.Fatalf("worker did not recover: %+v", records)
	}
}

func TestRejectedHistoryFailureIsReportedInHealth(t *testing.T) {
	dir := setupSendTestState(t)
	if err := os.Mkdir(filepath.Join(dir, historyFile), 0700); err != nil {
		t.Fatal(err)
	}
	q := NewSendQueue(SendQueueOptions{})
	q.Close()
	if got := postNotify(q, `{"text":"secret content must not appear in health"}`).Code; got != 503 {
		t.Fatal(got)
	}
	rec := httptest.NewRecorder()
	handleHealth(rec, httptest.NewRequest(http.MethodGet, "/health", nil), q)
	var body struct {
		Queue QueueStats `json:"queue"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Queue.HistoryWriteFailures != 1 || body.Queue.Rejected != 1 {
		t.Fatalf("health=%s", rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "secret content") || strings.Contains(rec.Body.String(), dir) {
		t.Fatal("health leaked record/state details")
	}
}
