package notify

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fakeSSH(t *testing.T, output, exit string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$HERALD_FAKE_SSH_LOG\"\n"
	if output != "" {
		script += "printf '%s' '" + output + "'\n"
	}
	script += "exit " + exit + "\n"
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return path
}

func TestDeliverUsesMappedHostWithFakeSSH(t *testing.T) {
	log := filepath.Join(t.TempDir(), "ssh.log")
	t.Setenv("HERALD_FAKE_SSH_LOG", log)
	fakeSSH(t, "", "0")
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=mapped-host")
	audio := filepath.Join(t.TempDir(), "clip")
	if err := os.WriteFile(audio, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := Deliver(context.Background(), DeliveryConfig{PlaybackHost: "fallback", Timeout: time.Second}, audio, "0123456789abcdef0123456789abcdef", "laptop")
	if err != nil || res.Outcome != OutcomeDelivered {
		t.Fatalf("deliver = %#v, %v", res, err)
	}
	data, _ := os.ReadFile(log)
	if !strings.Contains(string(data), "mapped-host") {
		t.Fatalf("fake ssh log = %q, want mapped-host", data)
	}
}

func TestDeliverRemoteFailureIsReportedWithoutFallback(t *testing.T) {
	log := filepath.Join(t.TempDir(), "ssh.log")
	t.Setenv("HERALD_FAKE_SSH_LOG", log)
	fakeSSH(t, "broken", "7")
	audio := filepath.Join(t.TempDir(), "clip")
	if err := os.WriteFile(audio, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := Deliver(context.Background(), DeliveryConfig{PlaybackHost: "mapped-host", Timeout: time.Second}, audio, "0123456789abcdef0123456789abcdef")
	if err != nil || res.Outcome != OutcomeTransportFailed {
		t.Fatalf("deliver failure = %#v, %v", res, err)
	}
}

func TestCapturedDeliveryHostSurvivesMappingChange(t *testing.T) {
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=first-host")
	captured := resolveRequestDelivery(DeliveryConfig{PlaybackHost: "fallback"}, "laptop")
	t.Setenv("HERALD_NOTIFY_CLIENT_TARGETS", "laptop=second-host")
	if captured.PlaybackHost != "first-host" {
		t.Fatalf("captured host = %q", captured.PlaybackHost)
	}
	if resolvePlaybackHost(DeliveryConfig{PlaybackHost: "fallback"}, "laptop") != "second-host" {
		t.Fatal("mapping did not change for new resolutions")
	}
}

func TestStopRemoteRequestDoesNotClaimUnrelatedRequest(t *testing.T) {
	log := filepath.Join(t.TempDir(), "ssh.log")
	t.Setenv("HERALD_FAKE_SSH_LOG", log)
	fakeSSH(t, "", "1")
	if StopRemoteRequest(context.Background(), DeliveryConfig{PlaybackHost: "mapped-host", Timeout: time.Second}, "0123456789abcdef0123456789abcdef") {
		t.Fatal("remote failure acknowledged stop")
	}
	data, _ := os.ReadFile(log)
	if strings.Contains(string(data), "unrelated") {
		t.Fatalf("unrelated request appeared in ssh log: %q", data)
	}
}
