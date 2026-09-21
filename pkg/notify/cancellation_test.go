package notify

import (
	"testing"
)

func TestRequestStateStopIsIdempotent(t *testing.T) {
	r := newRequestRegistry()
	s := r.addWithDelivery("0123456789abcdef0123456789abcdef", DeliveryConfig{PlaybackHost: "mapped-host"})

	stage, changed := s.stop()
	if !changed || stage != "accepted" {
		t.Fatalf("first stop = (%q, %v), want (accepted, true)", stage, changed)
	}
	stage, changed = s.stop()
	if changed || stage != "accepted" {
		t.Fatalf("duplicate stop = (%q, %v), want (accepted, false)", stage, changed)
	}
	if got := s.deliveryConfig().PlaybackHost; got != "mapped-host" {
		t.Fatalf("captured playback host = %q, want mapped-host", got)
	}
}

func TestRequestStateStopCancelsWorkerContextButDoesNotClaimRemoteStop(t *testing.T) {
	r := newRequestRegistry()
	s := r.addWithDelivery("0123456789abcdef0123456789abcdef", DeliveryConfig{PlaybackHost: "mapped-host"})
	if _, changed := s.stop(); !changed {
		t.Fatal("stop did not claim local cancellation")
	}
	select {
	case <-s.ctx.Done():
	default:
		t.Fatal("stop did not cancel worker context")
	}
	if _, changed := s.stop(); changed {
		t.Fatal("second stop claimed a remote or local stop")
	}
}
