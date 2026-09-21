package notify

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestManagedServiceSIGTERM(t *testing.T) {
	if os.Getenv("HERALD_TEST_SHUTDOWN_CHILD") == "1" {
		q := NewSendQueue(SendQueueOptions{Synthesize: func(ctx context.Context, _ string, _ Voice) ([]byte, error) { <-ctx.Done(); return nil, ctx.Err() }})
		s := &Server{Mux: http.NewServeMux(), Queue: q}
		s.Mux.HandleFunc("/notify", q.HandleNotify)
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
		defer stop()
		fmt.Println(ln.Addr().String())
		if err := serveManaged(ctx, s, newHTTPServer(s.Mux), ln); err != nil {
			t.Fatal(err)
		}
		return
	}
	dir := setupSendTestState(t)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestManagedServiceSIGTERM$")
	cmd.Env = append(os.Environ(), "HERALD_TEST_SHUTDOWN_CHILD=1")
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	}()
	scanner := bufio.NewScanner(out)
	if !scanner.Scan() {
		t.Fatal("child did not publish listener")
	}
	url := "http://" + scanner.Text() + "/notify"
	client := &http.Client{Timeout: time.Second}
	for _, text := range []string{"active", "queued"} {
		resp, err := client.Post(url, "application/json", strings.NewReader(`{"text":"`+text+`"}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 202 {
			t.Fatalf("status=%d", resp.StatusCode)
		}
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
	records := waitForHistoryCount(t, dir, 2)
	seen := map[string]bool{}
	for _, r := range records {
		if r.Outcome != OutcomeCanceled || r.RequestID == "" || seen[r.RequestID] {
			t.Fatalf("terminal record=%+v", r)
		}
		seen[r.RequestID] = true
	}
}
