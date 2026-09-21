package notify

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestNewHTTPServerBoundsNotificationRequests(t *testing.T) {
	s := newHTTPServer(http.NewServeMux())
	if s.ReadHeaderTimeout <= 0 || s.ReadTimeout < 10*time.Second || s.IdleTimeout < 10*time.Second {
		t.Fatalf("timeouts = header %s, read %s, idle %s", s.ReadHeaderTimeout, s.ReadTimeout, s.IdleTimeout)
	}
}

func TestHTTPServerSlowHeaderAndBodySocketsAreBounded(t *testing.T) {
	s := newHTTPServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	s.ReadHeaderTimeout = 100 * time.Millisecond
	ln := newTestListener(t)
	serveDone := make(chan error, 1)
	go func() { serveDone <- s.Serve(ln) }()
	defer func() {
		_ = s.Shutdown(context.Background())
		<-serveDone
	}()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	// Header timeout is intentionally shorter than this pause. A write can
	// succeed after the peer closes, so verify the read side observes EOF.
	time.Sleep(s.ReadHeaderTimeout + 100*time.Millisecond)
	_, _ = conn.Write([]byte("GET / HTTP/1.1\r\n"))
	buf := make([]byte, 1)
	if _, err := conn.Read(buf); err == nil {
		t.Fatal("slow header connection remained open after timeout")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatalf("slow header read hit local deadline instead of server timeout: %v", err)
	}
}

func TestHTTPServerServesConcurrentHealthWhileBodyIsSlow(t *testing.T) {
	s := newHTTPServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			_, _ = io.Copy(io.Discard, r.Body)
		}
		_, _ = w.Write([]byte("ok"))
	}))
	s.ReadHeaderTimeout = 100 * time.Millisecond
	s.ReadTimeout = 250 * time.Millisecond
	s.IdleTimeout = 100 * time.Millisecond
	ln := newTestListener(t)
	serveDone := make(chan error, 1)
	go func() { serveDone <- s.Serve(ln) }()
	defer func() {
		_ = s.Shutdown(context.Background())
		<-serveDone
	}()

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, _ = io.WriteString(conn, "POST /notify HTTP/1.1\r\nHost: test\r\nContent-Length: 100\r\n\r\npartial")

	healthErrs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() {
			resp, err := http.Get("http://" + ln.Addr().String() + "/health")
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode != http.StatusOK {
					err = fmt.Errorf("health status = %d", resp.StatusCode)
				}
			}
			healthErrs <- err
		}()
	}
	for i := 0; i < 8; i++ {
		if err := <-healthErrs; err != nil {
			t.Fatalf("concurrent health request: %v", err)
		}
	}
	conn.SetReadDeadline(time.Now().Add(time.Second))
	response, err := io.ReadAll(conn)
	if err != nil {
		t.Fatalf("read stalled body response: %v", err)
	}
	if len(response) == 0 {
		t.Fatal("stalled body connection produced no response after read timeout")
	}
}

func TestTailscaleIPv4BoundsStalledCommand(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tailscale")
	sleepPath, err := exec.LookPath("sleep")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexec "+sleepPath+" 10\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	started := time.Now()
	_, err = TailscaleIPv4()
	if err == nil {
		t.Fatal("TailscaleIPv4 succeeded for stalled command")
	}
	elapsed := time.Since(started)
	if elapsed < 1500*time.Millisecond {
		t.Fatalf("stalled tailscale returned too early in %s, fixture did not actually stall", elapsed)
	}
	if elapsed > 4*time.Second {
		t.Fatalf("stalled tailscale took %s, want bounded completion", elapsed)
	}
}

func newTestListener(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return ln
}
