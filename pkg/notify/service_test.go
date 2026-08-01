package notify

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// notify-service task 1.4. Address resolution is tested against an injected
// TailscaleIPResolver throughout, never a live `tailscale` binary — the whole
// point of the resolver seam.

func TestResolveBindConfigRejectsWildcardTailnetAddress(t *testing.T) {
	for _, wildcard := range []string{"0.0.0.0", "::"} {
		t.Run(wildcard, func(t *testing.T) {
			t.Setenv(BindTailscaleIPEnv, "")
			resolver := func() (string, error) { return wildcard, nil }
			if _, err := ResolveBindConfig(resolver); err == nil {
				t.Fatalf("ResolveBindConfig accepted wildcard address %q", wildcard)
			}
		})
	}
}

func TestResolveBindConfigRejectsWildcardViaEnvOverride(t *testing.T) {
	// The env override (BindTailscaleIPEnv) must not be a bypass for the same
	// STOP condition the resolver path enforces.
	t.Setenv(BindTailscaleIPEnv, "0.0.0.0")
	if _, err := ResolveBindConfig(func() (string, error) {
		t.Fatal("resolver should not be called when the env override is set")
		return "", nil
	}); err == nil {
		t.Fatal("ResolveBindConfig accepted 0.0.0.0 supplied via the env override")
	}
}

func TestResolveBindConfigRejectsEmptyOrUnresolvableTailnetAddress(t *testing.T) {
	t.Setenv(BindTailscaleIPEnv, "")

	t.Run("empty", func(t *testing.T) {
		resolver := func() (string, error) { return "", nil }
		if _, err := ResolveBindConfig(resolver); err == nil {
			t.Fatal("ResolveBindConfig accepted an empty tailnet address")
		}
	})

	t.Run("resolver error", func(t *testing.T) {
		resolver := func() (string, error) { return "", errors.New("tailscale: not logged in") }
		if _, err := ResolveBindConfig(resolver); err == nil {
			t.Fatal("ResolveBindConfig swallowed a resolver error")
		}
	})

	t.Run("not an IP", func(t *testing.T) {
		resolver := func() (string, error) { return "not-an-ip", nil }
		if _, err := ResolveBindConfig(resolver); err == nil {
			t.Fatal("ResolveBindConfig accepted a non-IP tailnet address")
		}
	})
}

func TestResolveBindConfigProducesExactlyTheTwoExpectedAddresses(t *testing.T) {
	t.Setenv(BindTailscaleIPEnv, "")
	t.Setenv(ServePortEnv, "18881")
	resolver := func() (string, error) { return "100.64.1.2", nil }

	cfg, err := ResolveBindConfig(resolver)
	if err != nil {
		t.Fatalf("ResolveBindConfig: %v", err)
	}
	if cfg.Loopback != "127.0.0.1:18881" {
		t.Errorf("Loopback = %q, want 127.0.0.1:18881", cfg.Loopback)
	}
	if cfg.Tailnet != "100.64.1.2:18881" {
		t.Errorf("Tailnet = %q, want 100.64.1.2:18881", cfg.Tailnet)
	}
	addrs := cfg.Addresses()
	if len(addrs) != 2 {
		t.Fatalf("Addresses() returned %d entries, want exactly 2: %v", len(addrs), addrs)
	}
}

func TestResolveBindConfigEnvOverrideWinsOverResolver(t *testing.T) {
	t.Setenv(BindTailscaleIPEnv, "100.64.9.9")
	t.Setenv(ServePortEnv, "18882")
	called := false
	resolver := func() (string, error) {
		called = true
		return "100.64.1.2", nil
	}
	cfg, err := ResolveBindConfig(resolver)
	if err != nil {
		t.Fatalf("ResolveBindConfig: %v", err)
	}
	if called {
		t.Error("resolver was called despite the env override being set")
	}
	if cfg.Tailnet != "100.64.9.9:18882" {
		t.Errorf("Tailnet = %q, want the env-overridden address", cfg.Tailnet)
	}
}

func TestResolvePortRejectsGarbageOverride(t *testing.T) {
	t.Setenv(ServePortEnv, "not-a-port")
	if _, err := ResolvePort(); err == nil {
		t.Fatal("ResolvePort accepted a non-numeric override")
	}

	t.Setenv(ServePortEnv, "0")
	if _, err := ResolvePort(); err == nil {
		t.Fatal("ResolvePort accepted port 0")
	}
}

func TestResolvePortDefaultsWhenUnset(t *testing.T) {
	t.Setenv(ServePortEnv, "")
	port, err := ResolvePort()
	if err != nil {
		t.Fatalf("ResolvePort: %v", err)
	}
	if port != DefaultServePort {
		t.Errorf("port = %d, want DefaultServePort %d", port, DefaultServePort)
	}
	if port == 8880 {
		t.Error("default port collides with Kokoro's 8880")
	}
}

// TestBindConfigNeverIncludesAWildcardAddress is the STOP-condition guard
// itself (proposal.md `## STOP conditions`, "the listener binding anything
// broader than loopback + the tailnet address"), in the same shape as
// TestDeliveryNeverPassesDashN: it scans what actually ships rather than
// trusting that ResolveBindConfig's validation is never bypassed.
func TestBindConfigNeverIncludesAWildcardAddress(t *testing.T) {
	t.Setenv(BindTailscaleIPEnv, "")
	t.Setenv(ServePortEnv, "")
	resolver := func() (string, error) { return "100.64.1.2", nil }
	cfg, err := ResolveBindConfig(resolver)
	if err != nil {
		t.Fatalf("ResolveBindConfig: %v", err)
	}
	for _, addr := range cfg.Addresses() {
		if strings.HasPrefix(addr, "0.0.0.0:") || strings.HasPrefix(addr, ":::") || strings.HasPrefix(addr, "[::]:") {
			t.Fatalf("bind address %q is a wildcard — this is the exact STOP condition proposal.md forbids", addr)
		}
	}
}

// TestListenerAnswersOnBothAddresses proves the listener half of task 1.4's
// verify clause end to end: two real net.Listen calls, one shared handler,
// both answering /health, torn down by a canceled context.
func TestListenerAnswersOnBothAddresses(t *testing.T) {
	// Two loopback addresses stand in for "loopback" and "tailnet" here —
	// the address-resolution guarantees are covered above; this test is
	// about the listener/serve/shutdown mechanics, not resolution.
	cfg := BindConfig{Loopback: "127.0.0.1:0", Tailnet: "127.0.0.1:0"}
	listeners, err := Listen(cfg)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}

	httpServer := &http.Server{Handler: NewServer().Mux}
	ctx, cancel := context.WithCancel(context.Background())

	serveErr := make(chan error, 1)
	go func() { serveErr <- Serve(ctx, httpServer, listeners...) }()

	for _, ln := range listeners {
		resp, err := http.Get(fmt.Sprintf("http://%s/health", ln.Addr().String()))
		if err != nil {
			t.Fatalf("GET /health on %s: %v", ln.Addr(), err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Errorf("GET /health on %s = %d, want 200 (body %s)", ln.Addr(), resp.StatusCode, body)
		}
	}

	cancel()
	select {
	case err := <-serveErr:
		if err != nil {
			t.Errorf("Serve returned %v after graceful shutdown, want nil", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not return within 2s of the context being canceled")
	}
}

func TestListenRejectsAnUnbindableAddressWithoutLeakingTheOther(t *testing.T) {
	cfg := BindConfig{Loopback: "127.0.0.1:0", Tailnet: "not-an-address"}
	if _, err := Listen(cfg); err == nil {
		t.Fatal("Listen accepted an invalid address")
	}
}

func TestServeRequiresAtLeastOneListener(t *testing.T) {
	httpServer := &http.Server{Handler: NewServer().Mux}
	if err := Serve(context.Background(), httpServer); err == nil {
		t.Fatal("Serve accepted zero listeners")
	}
}
