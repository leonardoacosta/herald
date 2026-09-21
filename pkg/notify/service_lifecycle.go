package notify

import (
	"context"
	"errors"
	"net"
	"net/http"
	"time"
)

// serveManaged stops HTTP admission before draining or canceling accepted jobs.
// Its 5s HTTP + 1s drain + 2s cancellation budgets fit the unit's 10s stop bound.
func serveManaged(ctx context.Context, server *Server, httpServer *http.Server, listeners ...net.Listener) error {
	serveErr := Serve(ctx, httpServer, listeners...)
	queueErr := server.Queue.shutdownWithin(time.Second, 2*time.Second)
	return errors.Join(serveErr, queueErr)
}
