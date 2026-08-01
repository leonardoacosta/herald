package notify

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// The resident service: `herald notify serve`.
//
// # Why a listener at all
//
// proposal.md's premise correction is the whole reason this file exists: pi
// cannot reach mute/status/history today because that surface lives in
// `plugin/commands/notify.md`, a Claude-only command file. A listener makes
// every consolidated `pkg/notify` capability (1.1-1.3) reachable by any
// tailnet caller, not just Claude.
//
// # Bind posture, copied verbatim from compose/kokoro.yml
//
// Loopback plus the Tailscale address, never 0.0.0.0. Kokoro has no auth at
// all and neither does this service (proposal.md `## Decisions`, "the bind
// address is the access control") — so the address IS the credential, and a
// wildcard bind would put an unauthenticated notification-and-control surface
// on the LAN. compose/kokoro.yml resolves its tailnet address at deploy time
// via `bin/kokoro-sync.sh`'s `tailscale ip -4`; this file does the same thing
// itself at process start, because unlike Kokoro this is a Go binary with no
// separate sync script staging an env var in ahead of it.
//
// # This file's scope
//
// Task 1.4 only: address resolution, the two listeners, the mux, graceful
// shutdown, and the `serve` subcommand. NewServer's Mux is the seam 1.5
// (POST /notify) and 1.6 (mute/unmute/status/history) hang handlers off —
// they call Mux.Handle/HandleFunc rather than editing this file.

// ServePortEnv overrides the service's listening port. No config-file layer
// here (mirrors ResolveBaseURL/ResolveStateDir: env wins outright, documented
// default otherwise) — this is a single daemon process, not a per-invocation
// CLI flag an operator retypes.
const ServePortEnv = "HERALD_NOTIFY_PORT"

// DefaultServePort is one past Kokoro's 8880, so the two Herald-owned
// listeners on the execution host sit on adjacent ports and never collide by
// coincidence with a default-only deployment.
const DefaultServePort = 8881

// BindTailscaleIPEnv is the escape hatch for a host where `tailscale ip -4`
// cannot be trusted (e.g. a test double, or a box with more than one tailnet
// interface). Named HERALD_-prefixed like every other Go-side override in
// this package (BaseURLEnv, StateDirEnv), unlike compose/kokoro.yml's
// unprefixed KOKORO_BIND_TAILSCALE_IP, which is compose-file interpolation
// syntax rather than a Go env read.
const BindTailscaleIPEnv = "HERALD_NOTIFY_BIND_TAILSCALE_IP"

// TailscaleIPResolver resolves the tailnet IPv4 address the service should
// bind. A function type, not a bare call to TailscaleIPv4, so
// ResolveBindConfig is unit-testable without a live tailscale binary — the
// address-resolution test injects a stub instead of shelling out.
type TailscaleIPResolver func() (string, error)

// TailscaleIPv4 is the default resolver: `tailscale ip -4`, exactly the
// command bin/kokoro-sync.sh runs to populate KOKORO_BIND_TAILSCALE_IP.
func TailscaleIPv4() (string, error) {
	out, err := exec.Command("tailscale", "ip", "-4").Output()
	if err != nil {
		return "", fmt.Errorf("notify: resolve tailnet address (tailscale ip -4): %w", err)
	}
	line, _, _ := strings.Cut(string(out), "\n")
	line = strings.TrimSpace(line)
	if line == "" {
		return "", errors.New("notify: tailscale ip -4 returned no address")
	}
	return line, nil
}

// BindConfig is the resolved bind posture: exactly the two addresses the
// listener answers on.
type BindConfig struct {
	Loopback string
	Tailnet  string
}

// Addresses returns the bind set in a form a test can scan for a wildcard
// without reaching into the struct fields by name.
func (c BindConfig) Addresses() []string {
	return []string{c.Loopback, c.Tailnet}
}

// ResolvePort reads ServePortEnv, falling back to DefaultServePort. An
// override that fails to parse as a valid TCP port is a startup error rather
// than a silent fallback: `serve` is opt-in infrastructure an operator
// configures deliberately, unlike the CLI/pipe path AGENTS.md requires to
// fail soft.
func ResolvePort() (int, error) {
	raw := strings.TrimSpace(os.Getenv(ServePortEnv))
	if raw == "" {
		return DefaultServePort, nil
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port <= 0 || port > 65535 {
		return 0, fmt.Errorf("notify: %s=%q is not a valid TCP port", ServePortEnv, raw)
	}
	return port, nil
}

// ResolveBindConfig resolves the two addresses `serve` binds, in the same
// env-override-first shape as ResolveBaseURL/ResolveStateDir: BindTailscaleIPEnv
// wins outright over resolver, exactly as compose/kokoro.yml's
// KOKORO_BIND_TAILSCALE_IP wins over any default. A nil resolver falls back to
// TailscaleIPv4, so callers outside tests can pass nil.
func ResolveBindConfig(resolver TailscaleIPResolver) (BindConfig, error) {
	port, err := ResolvePort()
	if err != nil {
		return BindConfig{}, err
	}

	ip := strings.TrimSpace(os.Getenv(BindTailscaleIPEnv))
	if ip == "" {
		if resolver == nil {
			resolver = TailscaleIPv4
		}
		ip, err = resolver()
		if err != nil {
			return BindConfig{}, err
		}
		ip = strings.TrimSpace(ip)
	}
	if err := rejectWildcardOrEmpty(ip); err != nil {
		return BindConfig{}, err
	}

	return BindConfig{
		Loopback: fmt.Sprintf("127.0.0.1:%d", port),
		Tailnet:  net.JoinHostPort(ip, strconv.Itoa(port)),
	}, nil
}

// rejectWildcardOrEmpty is the STOP-condition guard: proposal.md names "the
// listener binding anything broader than loopback + the tailnet address" as a
// report-don't-paper-over condition. An empty, unparseable, wildcard
// (0.0.0.0 / ::), or loopback tailnet address would each either widen the
// bind or silently collapse it onto the address already covered by
// BindConfig.Loopback.
func rejectWildcardOrEmpty(ip string) error {
	if ip == "" {
		return errors.New("notify: tailnet bind address is empty or unresolvable")
	}
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return fmt.Errorf("notify: tailnet bind address %q is not a valid IP", ip)
	}
	if parsed.IsUnspecified() {
		return fmt.Errorf("notify: tailnet bind address %q is a wildcard address, refusing to bind", ip)
	}
	if parsed.IsLoopback() {
		return fmt.Errorf("notify: tailnet bind address %q resolved to loopback, refusing to bind", ip)
	}
	return nil
}

// Listen opens both bind addresses. Two calls, not one, because a wildcard
// bind is exactly what proposal.md's STOP condition forbids — there is no
// single net.Listen invocation that reaches loopback and the tailnet address
// without also reaching everything between them.
//
// On a failure partway through, whatever already opened is closed: an
// unbalanced fd leak here would only surface much later as "why won't the
// service restart", far from this line.
func Listen(cfg BindConfig) ([]net.Listener, error) {
	opened := make([]net.Listener, 0, len(cfg.Addresses()))
	for _, addr := range cfg.Addresses() {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			for _, o := range opened {
				_ = o.Close()
			}
			return nil, fmt.Errorf("notify: listen on %s: %w", addr, err)
		}
		opened = append(opened, ln)
	}
	return opened, nil
}

// Server owns the mux 1.5 and 1.6 register handlers on. Exported and built by
// NewServer so those tasks are additive: `NewServer().Mux.HandleFunc("/notify", ...)`
// from their own file, never an edit to this one.
type Server struct {
	Mux *http.ServeMux
}

// NewServer builds the mux with only /health registered — task 1.4's own
// verification surface (task 2.3's bind-posture test needs an endpoint that
// exists before 1.5/1.6 land) and task 1.9's systemd readiness probe, mirroring
// compose/kokoro.yml's healthcheck precedent.
func NewServer() *Server {
	s := &Server{Mux: http.NewServeMux()}
	s.Mux.HandleFunc("/health", handleHealth)
	return s
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `{"status":"ok","version":%q}`+"\n", Version())
}

// shutdownGrace bounds how long Serve waits for in-flight requests to finish
// once shutdown is requested. Bounded, not indefinite, for the same reason
// every other timeout in this package is bounded: task 1.9 supervises this
// process under systemd, and an unbounded Shutdown would turn a routine
// restart into a hang systemd has to SIGKILL through.
const shutdownGrace = 5 * time.Second

// Serve runs httpServer across every listener and blocks until ctx is
// canceled, then shuts down gracefully and returns.
//
// One *http.Server serving N listeners — not N servers — so 1.5 and 1.6's
// handlers are registered exactly once and can never drift between the
// loopback and tailnet paths. http.Server supports this natively: each
// Serve(ln) call tracks its listener, and Shutdown closes all of them.
func Serve(ctx context.Context, httpServer *http.Server, listeners ...net.Listener) error {
	if len(listeners) == 0 {
		return errors.New("notify: serve requires at least one listener")
	}

	errCh := make(chan error, len(listeners))
	for _, ln := range listeners {
		ln := ln
		go func() { errCh <- httpServer.Serve(ln) }()
	}

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()
		shutdownErr := httpServer.Shutdown(shutdownCtx)
		// Drain every goroutine before returning: http.ErrServerClosed on each
		// is the expected shutdown signal, not a failure to surface.
		for range listeners {
			if err := <-errCh; err != nil && !errors.Is(err, http.ErrServerClosed) && shutdownErr == nil {
				shutdownErr = err
			}
		}
		return shutdownErr
	case err := <-errCh:
		// One listener died before shutdown was requested. Tearing the whole
		// server down rather than limping on the surviving address matters
		// here specifically: a herald notify serve stuck on ONLY its tailnet
		// listener (loopback died) or ONLY its loopback listener (tailnet
		// died) is a silent posture narrowing, not a graceful degradation.
		_ = httpServer.Close()
		for i := 1; i < len(listeners); i++ {
			<-errCh
		}
		return err
	}
}
