package notify

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"regexp"
	"sync"
)

var requestIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

func newRequestID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("notify: generate request id: %w", err)
	}
	return hex.EncodeToString(b), nil
}

func validRequestID(id string) bool { return requestIDPattern.MatchString(id) }

type requestState struct {
	id       string
	cancel   chan struct{}
	mu       sync.Mutex
	stage    string
	terminal bool
}

func (s *requestState) setStage(stage string) {
	s.mu.Lock()
	if !s.terminal {
		s.stage = stage
	}
	s.mu.Unlock()
}
func (s *requestState) snapshot() (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stage, s.terminal
}
func (s *requestState) stop() (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.terminal {
		return s.stage, false
	}
	s.terminal = true
	close(s.cancel)
	return s.stage, true
}

// requestRegistry owns accepted request cancellation signals for the daemon lifetime.
type requestRegistry struct {
	mu    sync.Mutex
	items map[string]*requestState
}

func newRequestRegistry() *requestRegistry {
	return &requestRegistry{items: map[string]*requestState{}}
}
func (r *requestRegistry) add(id string) *requestState {
	s := &requestState{id: id, cancel: make(chan struct{}), stage: "accepted"}
	r.mu.Lock()
	r.items[id] = s
	r.mu.Unlock()
	return s
}
func (r *requestRegistry) get(id string) (*requestState, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.items[id]
	return s, ok
}
