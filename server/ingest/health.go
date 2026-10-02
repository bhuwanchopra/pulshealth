package main

import (
	"context"
	"sync"
	"time"
)

// Cached liveness.
//
// /healthz is deliberately unauthenticated — the container health check and
// scripts/bootstrap.sh poll it — and it used to acquire a pool connection and
// ping the database on every request. The pool is pgxpool's default of
// max(4, NumCPU) and the ingest role has no connection limit, so under the
// documented INGEST_BIND_ADDR=0.0.0.0 LAN mode anyone who could reach the port
// could hold every connection open and stall uploads, unauthenticated, with a
// loop of GETs.
//
// So the probe is cached: at most one runs per healthTTL however fast the
// endpoint is polled, and callers that arrive while one is in flight are
// served the previous answer rather than queueing behind it. The TTL is short
// enough that a health check still notices a database that has gone away
// within one interval.
const (
	healthTTL = 2 * time.Second
	// Ceiling on a single probe, so a hung database cannot pin the prober.
	healthProbeTimeout = 2 * time.Second
)

type pinger interface {
	Ping(context.Context) error
}

// healthCache holds the last known database status and the instant it was
// taken. A zero value is usable: the first call probes.
type healthCache struct {
	mu        sync.Mutex
	ok        bool
	checkedAt time.Time
	probing   bool
}

// status reports whether the database answered recently, probing at most once
// per healthTTL. now is passed in so the behaviour is testable without
// sleeping.
func (h *healthCache) status(ctx context.Context, p pinger, now time.Time) bool {
	h.mu.Lock()
	fresh := !h.checkedAt.IsZero() && now.Sub(h.checkedAt) < healthTTL
	if fresh || h.probing {
		// Fresh, or someone else is already asking: answer from what we have.
		// Before the very first probe completes that is `false`, which is the
		// safe direction for a liveness endpoint.
		ok := h.ok
		h.mu.Unlock()
		return ok
	}
	h.probing = true
	h.mu.Unlock()

	probeCtx, cancel := context.WithTimeout(ctx, healthProbeTimeout)
	defer cancel()
	err := p.Ping(probeCtx)

	h.mu.Lock()
	h.ok = err == nil
	h.checkedAt = now
	h.probing = false
	ok := h.ok
	h.mu.Unlock()
	return ok
}
