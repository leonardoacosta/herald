package notify

import (
	"context"
	"testing"
	"time"
)

func TestSendQueueShutdownDrainsAndRejects(t *testing.T) {
	q := NewSendQueue(SendQueueOptions{Capacity: 1, Synthesize: func(context.Context, string, Voice) ([]byte, error) { return []byte("audio"), nil }, Deliver: func(context.Context, string, ...string) (DeliveryResult, error) {
		return DeliveryResult{Outcome: OutcomeDelivered}, nil
	}})
	if err := q.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
	if q.enqueue(sendJob{ID: "after-close"}) {
		t.Fatal("queue accepted work after shutdown")
	}
	select {
	case <-q.workerDone:
	default:
		t.Fatal("shutdown returned before worker stopped")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := q.Shutdown(ctx); err != nil {
		t.Fatalf("second shutdown: %v", err)
	}
}
