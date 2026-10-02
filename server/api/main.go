package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	// Embed the IANA zone database so PULS_TIME_ZONE resolves even in an
	// image without /usr/share/zoneinfo.
	_ "time/tzdata"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	defaultUserID   = "5ea4d000-0000-4000-8000-000000000001"
	shutdownTimeout = 15 * time.Second
	// Ceiling on a single handler's database work. Generous enough for the
	// widest legitimate query, short enough that a stuck one returns its
	// pool connection. /v1/export is exempt (see routes).
	handlerTimeout = 30 * time.Second
	defaultLimit   = 50
	maxLimit       = 200
	// /v1/metrics/daily pages in days across the requested types (see
	// DailyFilters). The default holds a year of 27 types, or a decade of
	// two, so a request that never names a limit gets what it always did;
	// the cap keeps one answer well under a few megabytes.
	defaultDailyLimit = 10000
	maxDailyLimit     = 50000
	catalogTTL        = 5 * time.Minute
	// How many users' catalog answers are cached at once (see
	// storeCatalogTypes). Far more than a household; small enough that a
	// caller spraying ?user= values holds nothing worth mentioning.
	catalogCacheMaxUsers = 32
	// Accepted range for epoch-millisecond query parameters: 1970-01-01 to
	// 9999-12-31T23:59:59.999Z, the widest span the `date` casts can carry.
	minEpochMS int64 = 0
	maxEpochMS int64 = 253402300799999
)

type apiStore interface {
	Ping(context.Context) error
	// Who the database holds: the one read that is not about a single user.
	Users(context.Context) ([]User, error)
	// Every other read takes the user it is for as its second argument —
	// explicit rather than baked into the store, so a handler cannot forget
	// it and a fake can record which user it was asked about.
	Profile(context.Context, string) (*Profile, error)
	CatalogTypes(context.Context, string) ([]CatalogType, error)
	LatestMetrics(context.Context, string, []string) ([]LatestMetric, error)
	DailyMetrics(context.Context, string, DailyFilters) ([]DailyMetric, error)
	ActivitySummary(context.Context, string, time.Time, time.Time) ([]ActivityDay, error)
	Workouts(context.Context, string, WorkoutFilters) ([]WorkoutSummary, error)
	Workout(context.Context, string, string) (*WorkoutDetail, error)
	SleepDaily(context.Context, string, time.Time, time.Time) ([]SleepNight, error)
	Samples(context.Context, string, SampleFilters) (*SamplesPage, error)
	WorkoutSeries(context.Context, string, string, []string, int) (*WorkoutSeriesResponse, error)
	StateOfMind(context.Context, string, time.Time, time.Time) ([]StateOfMindEntry, error)
	// The last N calendar days as one small document (see summary.go).
	Summary(context.Context, string, int) (*SummaryData, error)
	// The export's paths: the type behind /v1/samples resolved on its own,
	// so a bad identifier is a 400 before the download starts, and the two
	// row-at-a-time scans a whole range is streamed through.
	SampleType(context.Context, string) (SampleMeta, error)
	StreamSamples(context.Context, string, SampleMeta, SampleFilters, func(Sample) error) error
	StreamWorkouts(context.Context, string, WorkoutFilters, func(WorkoutSummary) error) error
}

type Server struct {
	store apiStore
	token string
	log   *slog.Logger

	// The user a request is answered for when it names none (PULS_USER_ID;
	// empty means the seeded default), and whether ?user= may name anyone
	// else (PULS_MULTI_USER, off by default). See scopeUser.
	defaultUserID string
	multiUser     bool

	// The calendar zone (PULS_TIME_ZONE) instants are rendered in where a
	// response is prose rather than JSON — the markdown summary. The store
	// cuts its days in the same zone. Nil means UTC (a Server built as a
	// struct literal, every test).
	loc *time.Location

	// Whether X-Forwarded-* may be believed: for the rate-limit key, and for
	// the host the OpenAPI document advertises. Off unless a proxy that
	// overwrites those headers is the only thing that can reach this port.
	trustProxyHeaders bool

	// Per-client-IP auth-failure buckets, made on first use so a Server built
	// as a struct literal (every test) still has one.
	limiterOnce sync.Once
	failures    *failureLimiter

	// Last known database status for the unauthenticated /healthz, so its
	// request rate cannot drive pool acquisitions (see health.go).
	health healthCache

	// /v1/catalog/types per user (see catalogCache): the query counts every
	// row the user has, so it is cached briefly, and it is cached per user
	// because the answer is per user.
	catalogMu sync.Mutex
	catalog   map[string]catalogEntry

	// The bounded set of /v1/export slots (see maxConcurrentExports), made on
	// first use so a Server built as a struct literal still has one.
	exportOnce  sync.Once
	exportSlots chan struct{}
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("fatal", "err", err.Error())
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	token := os.Getenv("PULS_API_TOKEN")
	if token == "" {
		return errors.New("PULS_API_TOKEN must be set")
	}
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return errors.New("DATABASE_URL must be set")
	}
	// The user a request is answered for when it names none. The web viewer
	// honours the same PULS_USER_ID; the API used to bake it into the store,
	// so nothing but a second deployment could read a second user.
	userID := os.Getenv("PULS_USER_ID")
	if userID == "" {
		userID = defaultUserID
	}
	if !isUUID(userID) {
		return errors.New("PULS_USER_ID must be a UUID")
	}
	// Whether ?user= may select anyone but that user. Off by default: the
	// bearer token is one static secret that docs/ai.md tells people to hand
	// to a ChatGPT Action, and turning this on widens what it reads from one
	// person to everyone on the server.
	multiUser, err := parseBoolEnv("PULS_MULTI_USER", false)
	if err != nil {
		return err
	}
	// The calendar zone for the daily endpoints. Same value the database's
	// puls.time_zone setting holds (db/migrations/013_time_zone.sh), so the API's
	// day ranges and metric_daily's day column agree. Fail fast on a typo
	// rather than serve misaligned days.
	loc, err := loadTimeZone(os.Getenv("PULS_TIME_ZONE"))
	if err != nil {
		return err
	}
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8081"
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := connectWithRetry(ctx, dbURL, logger)
	if err != nil {
		return err
	}
	defer pool.Close()

	// Same switch, same default (off), same meaning as ingest's: only a proxy
	// that overwrites X-Forwarded-* may be believed. It decides both the
	// rate-limit key and the host the OpenAPI document advertises.
	trustProxyHeaders := os.Getenv("TRUST_PROXY_HEADERS") == "true"

	srv := &Server{
		store:             NewStore(pool, loc),
		token:             token,
		log:               logger,
		defaultUserID:     userID,
		multiUser:         multiUser,
		loc:               loc,
		trustProxyHeaders: trustProxyHeaders,
	}
	logger.Info("starting",
		"addr", addr,
		"time_zone", loc.String(),
		"default_user", userID,
		"multi_user", multiUser,
		"trust_proxy_headers", trustProxyHeaders,
	)
	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", addr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutting down")
	shCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	return httpSrv.Shutdown(shCtx)
}

// loadTimeZone resolves PULS_TIME_ZONE (an IANA name; empty means UTC).
func loadTimeZone(name string) (*time.Location, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return time.UTC, nil
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return nil, fmt.Errorf("PULS_TIME_ZONE %q is not a valid IANA time zone: %w", name, err)
	}
	return loc, nil
}

func connectWithRetry(ctx context.Context, url string, logger *slog.Logger) (*pgxpool.Pool, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	deadline := time.Now().Add(60 * time.Second)
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err = pool.Ping(pingCtx)
		cancel()
		if err == nil {
			return pool, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			pool.Close()
			return nil, fmt.Errorf("database unreachable: %w", err)
		}
		logger.Warn("waiting for database", "err", err.Error())
		select {
		case <-time.After(2 * time.Second):
		case <-ctx.Done():
			pool.Close()
			return nil, ctx.Err()
		}
	}
}

// route is one entry of the router. path is the same route as an OpenAPI
// path, which is what lets TestOpenAPIDescribesTheRouter compare the two:
// an endpoint added here but not to the document in docs.go (or the other
// way round) fails the build rather than shipping an OpenAPI document that
// lies to a generated client.
type route struct {
	// The http.ServeMux pattern, e.g. "GET /v1/samples".
	pattern string
	// The OpenAPI path, e.g. "/v1/samples".
	path    string
	handler http.HandlerFunc
	// Whether the bearer token is required; the discovery endpoints are open
	// and carry "security": [] in the document.
	auth bool
}

func (s *Server) apiRoutes() []route {
	return []route{
		{"GET /{$}", "/", s.handleIndex, false},
		{"GET /docs", "/docs", s.handleDocs, false},
		{"GET /openapi.json", "/openapi.json", s.handleOpenAPI, false},
		{"GET /healthz", "/healthz", s.handleHealthz, false},
		{"GET /v1/users", "/v1/users", s.handleUsers, true},
		{"GET /v1/profile", "/v1/profile", s.handleProfile, true},
		{"GET /v1/catalog/types", "/v1/catalog/types", s.handleCatalogTypes, true},
		{"GET /v1/metrics/latest", "/v1/metrics/latest", s.handleLatestMetrics, true},
		{"GET /v1/metrics/daily", "/v1/metrics/daily", s.handleDailyMetrics, true},
		{"GET /v1/activity/summary", "/v1/activity/summary", s.handleActivitySummary, true},
		{"GET /v1/workouts", "/v1/workouts", s.handleWorkouts, true},
		{"GET /v1/workouts/{uuid}", "/v1/workouts/{uuid}", s.handleWorkout, true},
		{"GET /v1/workouts/{uuid}/series", "/v1/workouts/{uuid}/series", s.handleWorkoutSeries, true},
		{"GET /v1/sleep/daily", "/v1/sleep/daily", s.handleSleepDaily, true},
		{"GET /v1/samples", "/v1/samples", s.handleSamples, true},
		{"GET /v1/state-of-mind", "/v1/state-of-mind", s.handleStateOfMind, true},
		{"GET /v1/summary", "/v1/summary", s.handleSummary, true},
		{"GET /v1/export", "/v1/export", s.handleExport, true},
	}
}

// limiter returns the auth-failure limiter, creating it on first use.
func (s *Server) limiter() *failureLimiter {
	s.limiterOnce.Do(func() {
		if s.failures == nil {
			s.failures = newFailureLimiter()
		}
	})
	return s.failures
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	for _, rt := range s.apiRoutes() {
		handler := rt.handler
		// The export streams for as long as the download takes; every other
		// handler is bounded so one slow query cannot hold a pool connection
		// open indefinitely.
		if rt.path != "/v1/export" {
			handler = withTimeout(handlerTimeout, handler)
		}
		if rt.auth {
			// Token first, then the user the request is about: a caller that
			// cannot authenticate never learns whether ?user= is valid.
			handler = s.auth(s.scopeUser(handler))
		}
		mux.HandleFunc(rt.pattern, handler)
	}
	return mux
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")

		// Refusal happens BEFORE the token comparison, exactly as it does in
		// ingest: charging a failure but still answering 401 would let an
		// attacker keep guessing at full speed and read the status code.
		ip := clientIP(r, s.trustProxyHeaders)
		if ok, wait := s.limiter().allow(ip, time.Now()); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())))
			s.log.Warn("auth throttled", "ip", ip, "path", r.URL.Path, "retry_after_s", int(wait.Seconds()))
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "too many failed authentications"})
			return
		}

		got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) != 1 {
			// A successful request never costs a token: a client polling this
			// API legitimately must never be throttled.
			s.limiter().recordFailure(ip, time.Now())
			// Logged so a token brute-force leaves a trace. The token itself is
			// never logged, present or absent.
			s.log.Warn("auth failed", "ip", ip, "path", r.URL.Path, "had_bearer", ok)
			w.Header().Set("WWW-Authenticate", "Bearer")
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

// withTimeout bounds a handler's database work. Without it a slow query holds
// a pooled connection until the client goes away, and the pool defaults to
// max(4, NumCPU) — so a handful of them starve every other endpoint.
//
// /v1/export is deliberately exempt: it streams for as long as the download
// takes, and is bounded instead by its own concurrency slots and range cap.
func withTimeout(d time.Duration, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next(w, r.WithContext(ctx))
	}
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	// Cached: this endpoint is unauthenticated, so request rate must not drive
	// pool acquisitions. See health.go.
	if !s.health.status(r.Context(), s.store, time.Now()) {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "db": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "db": true})
}

func (s *Server) handleProfile(w http.ResponseWriter, r *http.Request) {
	profile, err := s.store.Profile(r.Context(), s.requestUser(r))
	if err != nil {
		s.log.Error("profile query failed", "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "profile failed"})
		return
	}
	if profile == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "profile not found"})
		return
	}
	writeJSON(w, http.StatusOK, profile)
}

func (s *Server) handleCatalogTypes(w http.ResponseWriter, r *http.Request) {
	user := s.requestUser(r)
	if types, ok := s.cachedCatalogTypes(user); ok {
		writeJSON(w, http.StatusOK, map[string][]CatalogType{"types": types})
		return
	}

	types, err := s.store.CatalogTypes(r.Context(), user)
	if err != nil {
		s.log.Error("catalog types query failed", "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "catalog types failed"})
		return
	}
	types = cloneCatalogTypes(types)
	s.storeCatalogTypes(user, types)
	writeJSON(w, http.StatusOK, map[string][]CatalogType{"types": types})
}

func (s *Server) handleLatestMetrics(w http.ResponseWriter, r *http.Request) {
	types, err := parseTypesParam(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	metrics, err := s.store.LatestMetrics(r.Context(), s.requestUser(r), types)
	if err != nil {
		s.log.Error("latest metrics query failed", "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "latest metrics failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string][]LatestMetric{"metrics": metrics})
}

func (s *Server) handleDailyMetrics(w http.ResponseWriter, r *http.Request) {
	filters, err := dailyFiltersFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	metrics, err := s.store.DailyMetrics(r.Context(), s.requestUser(r), filters)
	if err != nil {
		s.log.Error("daily metrics query failed", "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "daily metrics failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"metrics":    metrics,
		"nextOffset": filters.Offset + dailyPoints(metrics),
	})
}

// dailyPoints is the number of day rows a daily-metrics answer carries — the
// unit /v1/metrics/daily pages in.
func dailyPoints(metrics []DailyMetric) int {
	n := 0
	for _, m := range metrics {
		n += m.points()
	}
	return n
}

func (s *Server) handleActivitySummary(w http.ResponseWriter, r *http.Request) {
	start, end, err := parseRange(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	days, err := s.store.ActivitySummary(r.Context(), s.requestUser(r), start, end)
	if err != nil {
		s.log.Error("activity summary query failed", "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "activity summary failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string][]ActivityDay{"days": days})
}

func (s *Server) handleWorkouts(w http.ResponseWriter, r *http.Request) {
	filters, err := workoutFiltersFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	workouts, err := s.store.Workouts(r.Context(), s.requestUser(r), filters)
	if err != nil {
		s.log.Error("workouts query failed", "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "workouts failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"workouts":   workouts,
		"nextOffset": filters.Offset + len(workouts),
	})
}

func (s *Server) handleWorkout(w http.ResponseWriter, r *http.Request) {
	uuid := r.PathValue("uuid")
	if !isUUID(uuid) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid workout uuid"})
		return
	}
	workout, err := s.store.Workout(r.Context(), s.requestUser(r), uuid)
	if err != nil {
		s.log.Error("workout query failed", "uuid", uuid, "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "workout failed"})
		return
	}
	if workout == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "workout not found"})
		return
	}
	writeJSON(w, http.StatusOK, workout)
}

func (s *Server) handleSleepDaily(w http.ResponseWriter, r *http.Request) {
	start, end, err := parseRange(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	nights, err := s.store.SleepDaily(r.Context(), s.requestUser(r), start, end)
	if err != nil {
		s.writeStoreError(w, err, "sleep")
		return
	}
	writeJSON(w, http.StatusOK, map[string][]SleepNight{"nights": nights})
}

func (s *Server) handleSamples(w http.ResponseWriter, r *http.Request) {
	filters, err := sampleFiltersFromRequest(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	page, err := s.store.Samples(r.Context(), s.requestUser(r), filters)
	if err != nil {
		s.writeStoreError(w, err, "samples")
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (s *Server) handleWorkoutSeries(w http.ResponseWriter, r *http.Request) {
	uuid := r.PathValue("uuid")
	if !isUUID(uuid) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid workout uuid"})
		return
	}
	types, maxPoints, err := workoutSeriesRequest(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	series, err := s.store.WorkoutSeries(r.Context(), s.requestUser(r), uuid, types, maxPoints)
	if err != nil {
		s.log.Error("workout series query failed", "uuid", uuid, "err", err.Error())
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "workout series failed"})
		return
	}
	if series == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "workout not found"})
		return
	}
	writeJSON(w, http.StatusOK, series)
}

func (s *Server) handleStateOfMind(w http.ResponseWriter, r *http.Request) {
	start, end, err := parseRange(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	entries, err := s.store.StateOfMind(r.Context(), s.requestUser(r), start, end)
	if err != nil {
		s.writeStoreError(w, err, "state of mind")
		return
	}
	writeJSON(w, http.StatusOK, map[string][]StateOfMindEntry{"entries": entries})
}

// writeStoreError answers a failed store call: a requestError is the
// caller's fault and comes back as a 400 with its message; anything else is
// logged and answered with a generic 500.
func (s *Server) writeStoreError(w http.ResponseWriter, err error, what string) {
	var reqErr *requestError
	if errors.As(err, &reqErr) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": reqErr.Error()})
		return
	}
	s.log.Error(what+" query failed", "err", err.Error())
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": what + " failed"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func parseTypesParam(r *http.Request) ([]string, error) {
	raw := strings.TrimSpace(r.URL.Query().Get("types"))
	if raw == "" {
		return nil, errors.New("missing types")
	}
	parts := strings.Split(raw, ",")
	types := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			return nil, errors.New("types must not contain empty values")
		}
		if _, ok := seen[part]; ok {
			continue
		}
		seen[part] = struct{}{}
		types = append(types, part)
	}
	return types, nil
}

func msParam(s, name string) (time.Time, error) {
	if s == "" {
		return time.Time{}, fmt.Errorf("missing %s", name)
	}
	ms, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("invalid %s: must be epoch milliseconds", name)
	}
	// Any int64 parses, but the day-range formatting downstream casts to a
	// Postgres `date`; a value beyond year 9999 blew up there as a 500
	// instead of a 400.
	if ms < minEpochMS || ms > maxEpochMS {
		return time.Time{}, fmt.Errorf("invalid %s: epoch milliseconds out of range", name)
	}
	return time.UnixMilli(ms).UTC(), nil
}

func parseRange(r *http.Request) (time.Time, time.Time, error) {
	q := r.URL.Query()
	start, err := msParam(q.Get("start"), "start")
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	end, err := msParam(q.Get("end"), "end")
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	if !end.After(start) {
		return time.Time{}, time.Time{}, errors.New("end must be after start")
	}
	return start, end, nil
}

func optionalMSParam(raw, name string) (*time.Time, error) {
	if raw == "" {
		return nil, nil
	}
	t, err := msParam(raw, name)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func parseLimitOffset(r *http.Request) (limit, offset int, err error) {
	return parseLimitOffsetBounds(r, defaultLimit, maxLimit)
}

// parseLimitOffsetBounds reads limit (default def, clamped to max) and
// offset (default 0) from the query.
func parseLimitOffsetBounds(r *http.Request, def, max int) (limit, offset int, err error) {
	q := r.URL.Query()
	limit = def
	offset = 0

	if raw := q.Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil {
			return 0, 0, errors.New("invalid limit: must be an integer")
		}
	}
	if limit < 1 {
		return 0, 0, errors.New("limit must be at least 1")
	}
	if limit > max {
		limit = max
	}

	if raw := q.Get("offset"); raw != "" {
		offset, err = strconv.Atoi(raw)
		if err != nil {
			return 0, 0, errors.New("invalid offset: must be an integer")
		}
	}
	if offset < 0 {
		return 0, 0, errors.New("offset must be at least 0")
	}

	return limit, offset, nil
}

// dailyTypesAndRange reads the types and range of a daily-metrics request.
// Limit and Offset are left zero, which the store reads as the whole range
// — what the export wants.
func dailyTypesAndRange(r *http.Request) (DailyFilters, error) {
	var f DailyFilters
	types, err := parseTypesParam(r)
	if err != nil {
		return f, err
	}
	start, end, err := parseRange(r)
	if err != nil {
		return f, err
	}
	f.Types, f.Start, f.End = types, start, end
	return f, nil
}

// dailyFiltersFromRequest reads GET /v1/metrics/daily: dailyTypesAndRange
// plus the endpoint's paging (limit defaults to defaultDailyLimit, caps at
// maxDailyLimit; both count days across the requested types).
func dailyFiltersFromRequest(r *http.Request) (DailyFilters, error) {
	f, err := dailyTypesAndRange(r)
	if err != nil {
		return f, err
	}
	limit, offset, err := parseLimitOffsetBounds(r, defaultDailyLimit, maxDailyLimit)
	if err != nil {
		return f, err
	}
	f.Limit, f.Offset = limit, offset
	return f, nil
}

func workoutFiltersFromRequest(r *http.Request) (WorkoutFilters, error) {
	var filters WorkoutFilters

	limit, offset, err := parseLimitOffset(r)
	if err != nil {
		return filters, err
	}
	q := r.URL.Query()
	start, err := optionalMSParam(q.Get("start"), "start")
	if err != nil {
		return filters, err
	}
	end, err := optionalMSParam(q.Get("end"), "end")
	if err != nil {
		return filters, err
	}
	if start != nil && end != nil && !end.After(*start) {
		return filters, errors.New("end must be after start")
	}

	filters.Start = start
	filters.End = end
	filters.ActivityType = q.Get("activityType")
	filters.Limit = limit
	filters.Offset = offset
	return filters, nil
}

// sampleTypeAndRange reads what GET /v1/samples and the samples export have
// in common: exactly one type, and a required [start, end) range of at most
// maxSampleRange. Limit and Offset are left zero, which the store reads as
// "every matching row".
func sampleTypeAndRange(r *http.Request) (SampleFilters, error) {
	var f SampleFilters
	q := r.URL.Query()

	f.Type = strings.TrimSpace(q.Get("type"))
	if f.Type == "" {
		return f, errors.New("missing type")
	}
	if strings.Contains(f.Type, ",") {
		return f, errors.New("type must name exactly one HealthKit identifier")
	}
	start, end, err := parseRange(r)
	if err != nil {
		return f, err
	}
	if end.Sub(start) > maxSampleRange {
		return f, fmt.Errorf("range must not exceed %d days", int(maxSampleRange.Hours()/24))
	}
	f.Start, f.End = start, end
	return f, nil
}

// sampleFiltersFromRequest reads GET /v1/samples: sampleTypeAndRange plus the
// endpoint's paging.
func sampleFiltersFromRequest(r *http.Request) (SampleFilters, error) {
	f, err := sampleTypeAndRange(r)
	if err != nil {
		return f, err
	}
	limit, offset, err := parseLimitOffsetBounds(r, defaultSampleLimit, maxSampleLimit)
	if err != nil {
		return f, err
	}
	f.Limit, f.Offset = limit, offset
	return f, nil
}

// workoutSeriesRequest reads GET /v1/workouts/{uuid}/series: an optional
// comma-separated types filter and maxPoints (default defaultSeriesPoints,
// clamped to maxSeriesPoints).
func workoutSeriesRequest(r *http.Request) ([]string, int, error) {
	var types []string
	if strings.TrimSpace(r.URL.Query().Get("types")) != "" {
		var err error
		if types, err = parseTypesParam(r); err != nil {
			return nil, 0, err
		}
	}
	maxPoints := defaultSeriesPoints
	if raw := r.URL.Query().Get("maxPoints"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil {
			return nil, 0, errors.New("invalid maxPoints: must be an integer")
		}
		if n < 1 {
			return nil, 0, errors.New("maxPoints must be at least 1")
		}
		maxPoints = n
	}
	if maxPoints > maxSeriesPoints {
		maxPoints = maxSeriesPoints
	}
	return types, maxPoints, nil
}

func isHexN(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for i := 0; i < n; i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func isUUID(s string) bool {
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return false
	}
	return isHexN(s[0:8], 8) && isHexN(s[9:13], 4) && isHexN(s[14:18], 4) &&
		isHexN(s[19:23], 4) && isHexN(s[24:36], 12)
}

// catalogEntry is one user's cached /v1/catalog/types answer.
type catalogEntry struct {
	types   []CatalogType
	expires time.Time
}

func (s *Server) cachedCatalogTypes(user string) ([]CatalogType, bool) {
	s.catalogMu.Lock()
	defer s.catalogMu.Unlock()

	if entry, ok := s.catalog[user]; ok && time.Now().Before(entry.expires) {
		return cloneCatalogTypes(entry.types), true
	}
	return nil, false
}

// storeCatalogTypes caches one user's answer. The map is bounded at
// catalogCacheMaxUsers because an authenticated caller can spray ?user=
// values (with PULS_MULTI_USER on, any UUID is a valid selector); at the
// bound, expired entries go first, then the one expiring soonest.
func (s *Server) storeCatalogTypes(user string, types []CatalogType) {
	s.catalogMu.Lock()
	defer s.catalogMu.Unlock()

	if s.catalog == nil {
		s.catalog = make(map[string]catalogEntry, 1)
	}
	now := time.Now()
	if _, ok := s.catalog[user]; !ok && len(s.catalog) >= catalogCacheMaxUsers {
		for key, entry := range s.catalog {
			if !now.Before(entry.expires) {
				delete(s.catalog, key)
			}
		}
		if len(s.catalog) >= catalogCacheMaxUsers {
			var (
				oldest   string
				soonest  time.Time
				firstKey = true
			)
			for key, entry := range s.catalog {
				if firstKey || entry.expires.Before(soonest) {
					oldest, soonest, firstKey = key, entry.expires, false
				}
			}
			delete(s.catalog, oldest)
		}
	}
	s.catalog[user] = catalogEntry{types: cloneCatalogTypes(types), expires: now.Add(catalogTTL)}
}

// catalogCacheSize is the number of users with a cached catalog (tests).
func (s *Server) catalogCacheSize() int {
	s.catalogMu.Lock()
	defer s.catalogMu.Unlock()
	return len(s.catalog)
}

func cloneCatalogTypes(types []CatalogType) []CatalogType {
	if len(types) == 0 {
		return []CatalogType{}
	}
	out := make([]CatalogType, len(types))
	copy(out, types)
	return out
}

// Per-request user scoping.
//
// Every authenticated route answers for exactly one user. Which one is
// settled here, once, before the handler runs: the ?user= query parameter
// when the request carries one, else PULS_USER_ID — so a deployment that
// never sets PULS_MULTI_USER behaves exactly as it always has. The parameter
// is a selector, not a credential: the bearer token is the same for everyone,
// which is why the gate exists. With it off, naming any other user is a 403
// rather than a quiet answer for the default user — silently substituting one
// person's data for another's is the one outcome worse than an error.
//
// Neither refusal charges the auth-failure limiter: the caller holds a valid
// token and mis-addressed a request, which is a configuration mistake, not a
// guess at the secret. There is no existence check either — an unknown id
// reads as a user with no data — because /v1/users is the discovery surface
// and a lookup per request would cost a round trip on every call.

// requestUserKey is the request-context key scopeUser stashes the user under.
type requestUserKey struct{}

func withRequestUser(ctx context.Context, user string) context.Context {
	return context.WithValue(ctx, requestUserKey{}, user)
}

// scopeUser settles the user a request is answered for (see the package
// comment above) and hands it to next through the request context.
func (s *Server) scopeUser(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user := s.defaultUser()
		if raw := strings.TrimSpace(r.URL.Query().Get("user")); raw != "" {
			if !isUUID(raw) {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid user: must be a UUID"})
				return
			}
			if !s.multiUser && !sameUser(raw, user) {
				s.log.Warn("refused a request for another user", "path", r.URL.Path, "user", raw)
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "multi-user reads are disabled"})
				return
			}
			user = strings.ToLower(raw)
		}
		next(w, r.WithContext(withRequestUser(r.Context(), user)))
	}
}

// requestUser is the user the request is answered for: what scopeUser
// settled, or — for a handler run without the middleware — the default.
func (s *Server) requestUser(r *http.Request) string {
	if user, ok := r.Context().Value(requestUserKey{}).(string); ok && user != "" {
		return user
	}
	return s.defaultUser()
}

// defaultUser is PULS_USER_ID, or the seeded default for a Server built as
// a struct literal (every test).
func (s *Server) defaultUser() string {
	if s.defaultUserID == "" {
		return defaultUserID
	}
	return strings.ToLower(s.defaultUserID)
}

// location is the zone prose responses render instants in: PULS_TIME_ZONE,
// or UTC for a Server built as a struct literal.
func (s *Server) location() *time.Location {
	if s.loc == nil {
		return time.UTC
	}
	return s.loc
}

// sameUser compares two UUIDs the way Postgres does: case does not matter.
func sameUser(a, b string) bool {
	return strings.EqualFold(a, b)
}

// parseBoolEnv reads a boolean environment variable (any spelling
// strconv.ParseBool accepts), returning def when it is unset or blank.
func parseBoolEnv(name string, def bool) (bool, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def, nil
	}
	value, err := strconv.ParseBool(raw)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false, got %q", name, raw)
	}
	return value, nil
}
