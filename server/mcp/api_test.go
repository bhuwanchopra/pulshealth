package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAPI is an httptest stand-in for the product API, answering with the
// shapes in server/api/docs.go. Data routes need the bearer token; /healthz
// does not, like the real thing. Every request URL is recorded so tests can
// assert on the query the tools built.
type fakeAPI struct {
	srv    *httptest.Server
	token  string
	mu     sync.Mutex
	calls  []url.URL
	routes map[string]http.HandlerFunc
}

func newFakeAPI(t *testing.T) *fakeAPI {
	t.Helper()
	f := &fakeAPI{token: "api-token", routes: map[string]http.HandlerFunc{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAPI) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.calls = append(f.calls, *r.URL)
	f.mu.Unlock()

	if r.URL.Path == "/healthz" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "db": true})
		return
	}
	if r.Header.Get("Authorization") != "Bearer "+f.token {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	h, ok := f.routes[r.URL.Path]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	h(w, r)
}

// respond makes path answer with a fixed status and JSON body.
func (f *fakeAPI) respond(path string, status int, body any) {
	f.routes[path] = func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, status, body)
	}
}

// raw makes path answer with arbitrary bytes.
func (f *fakeAPI) raw(path string, status int, body string) {
	f.routes[path] = func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}
}

// callsTo returns the recorded requests for a path.
func (f *fakeAPI) callsTo(path string) []url.URL {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []url.URL
	for _, u := range f.calls {
		if u.Path == path {
			out = append(out, u)
		}
	}
	return out
}

// lastQuery returns the query of the most recent request to path, failing
// the test if there was none.
func (f *fakeAPI) lastQuery(t *testing.T, path string) url.Values {
	t.Helper()
	calls := f.callsTo(path)
	if len(calls) == 0 {
		t.Fatalf("no request reached %s; requests: %v", path, f.calls)
	}
	return calls[len(calls)-1].Query()
}

func (f *fakeAPI) client(t *testing.T) *APIClient {
	t.Helper()
	c, err := NewAPIClient(f.srv.URL, f.token, f.srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// fixedNow is "now" for every test: a Monday morning in Berlin.
var fixedNow = time.Date(2026, 9, 7, 8, 0, 0, 0, time.UTC)

func mustZone(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatal(err)
	}
	return loc
}

// service builds a service over the fake API in the given zone with a fixed
// clock.
func (f *fakeAPI) service(t *testing.T, zone string) *service {
	t.Helper()
	s := newService(f.client(t), mustZone(t, zone))
	s.now = func() time.Time { return fixedNow }
	return s
}

// Fixtures, in the product API's own JSON.

func ptr[T any](v T) *T { return &v }

var fixtureProfile = Profile{
	UserID:        "5ea4d000-0000-4000-8000-000000000001",
	Name:          ptr("Test Person"),
	Email:         ptr("test@example.com"),
	DateOfBirth:   ptr(time.Date(1990, 9, 8, 0, 0, 0, 0, time.UTC).UnixMilli()),
	BiologicalSex: ptr("female"),
}

var fixtureCatalog = map[string]any{"types": []CatalogType{
	{
		Identifier: "HKQuantityTypeIdentifierStepCount", Kind: "quantity", Unit: ptr("count"),
		Rows: 1200, RawRows: 1000, AggregateRows: 200,
		Earliest: ptr(time.Date(2024, 1, 1, 8, 0, 0, 0, time.UTC).UnixMilli()),
		Latest:   ptr(time.Date(2026, 9, 6, 22, 30, 0, 0, time.UTC).UnixMilli()),
	},
	{Identifier: "HKWorkoutTypeIdentifier", Kind: "workout", Rows: 42, RawRows: 42},
}}

var fixtureLatest = map[string]any{"metrics": []LatestMetric{
	{Identifier: "HKQuantityTypeIdentifierBodyMass", Unit: ptr("kg"), Value: ptr(82.456789),
		Timestamp: time.Date(2026, 9, 6, 6, 5, 0, 0, time.UTC).UnixMilli()},
}}

var fixtureDaily = map[string]any{"metrics": []DailyMetric{
	{Identifier: "HKQuantityTypeIdentifierStepCount", Unit: ptr("count"), Days: []DailyPoint{
		{Date: "2026-03-28", Value: ptr(8123.0)},
		{Date: "2026-03-29", Value: ptr(10456.00001)},
	}},
}}

var fixtureActivity = map[string]any{"days": []ActivityDay{
	{Date: "2026-09-06", MoveKcal: ptr(512.3), MoveGoalKcal: ptr(500.0), ExerciseMin: ptr(31.0),
		ExerciseGoalMin: ptr(30.0), StandHours: ptr(11.0), StandGoalHours: ptr(12.0), MoveMode: ptr(1)},
}}

const workoutUUID = "0a1b2c3d-4e5f-4a6b-8c7d-9e8f7a6b5c4d"

var fixtureWorkoutSummary = WorkoutSummary{
	UUID: workoutUUID, ActivityType: "running",
	Start:            time.Date(2026, 9, 6, 5, 30, 0, 0, time.UTC).UnixMilli(),
	End:              time.Date(2026, 9, 6, 6, 15, 0, 0, time.UTC).UnixMilli(),
	DurationS:        ptr(2700.0),
	DistanceM:        ptr(8012.5),
	EnergyKcal:       ptr(610.25),
	HasRoute:         true,
	AvailableMetrics: []string{"HKQuantityTypeIdentifierHeartRate"},
}

func fixtureWorkoutDetail() WorkoutDetail {
	return WorkoutDetail{
		WorkoutSummary: fixtureWorkoutSummary,
		StatisticsDetail: map[string]WorkoutStatDetail{
			"HKQuantityTypeIdentifierHeartRate": {Min: ptr(98.0), Avg: ptr(151.333333), Max: ptr(178.0)},
		},
		Events: []map[string]any{
			{"type": "pause", "start": float64(time.Date(2026, 9, 6, 5, 50, 0, 0, time.UTC).UnixMilli())},
			{"type": "lap", "start": float64(time.Date(2026, 9, 6, 5, 40, 0, 0, time.UTC).UnixMilli()), "end": float64(time.Date(2026, 9, 6, 5, 45, 0, 0, time.UTC).UnixMilli())},
		},
		Activities: []map[string]any{{"activityType": "running", "duration": 2700.0}},
	}
}

// A night from 22:40 on the 20th to 06:30 on the 21st, Berlin time, that a
// Watch and a phone both recorded.
var fixtureSleep = map[string]any{"nights": []SleepNight{{
	Date:          "2026-09-21",
	Start:         time.Date(2026, 9, 20, 20, 30, 0, 0, time.UTC).UnixMilli(), // 22:30 CEST
	End:           time.Date(2026, 9, 21, 4, 30, 0, 0, time.UTC).UnixMilli(),  // 06:30 CEST
	InBedMinutes:  480,
	AsleepMinutes: 460.000001,
	Stages:        SleepStages{Core: 340, Deep: 60, REM: 60, Awake: 10},
	Sources:       2,
}}}

var fixtureSamples = SamplesPage{
	Type: "HKCategoryTypeIdentifierSleepAnalysis", Kind: "category",
	Samples: []Sample{{
		UUID:   "11111111-1111-4111-8111-111111111111",
		Start:  time.Date(2026, 9, 20, 20, 40, 0, 0, time.UTC).UnixMilli(),
		End:    time.Date(2026, 9, 20, 23, 0, 0, 0, time.UTC).UnixMilli(),
		Value:  ptr(3.0),
		Label:  ptr("Asleep Core"),
		Source: ptr("Apple Watch"),
	}},
	NextOffset: 1,
}

// A heart-rate stream of four points, one per minute from the workout start.
func fixtureSeries() WorkoutSeriesResponse {
	start := fixtureWorkoutSummary.Start
	return WorkoutSeriesResponse{
		UUID: workoutUUID, Start: start, End: fixtureWorkoutSummary.End, MaxPoints: 500,
		Series: []WorkoutSeries{{
			Type: "HKQuantityTypeIdentifierHeartRate", Unit: ptr("count/min"), TotalPoints: 2700,
			Points: []SeriesPoint{
				{T: start, V: 98},
				{T: start + 60_000, V: 120.500001},
				{T: start + 120_000, V: 151},
				{T: start + 180_000, V: 143},
			},
		}},
	}
}

var fixtureStateOfMind = map[string]any{"entries": []StateOfMindEntry{{
	UUID:                  "22222222-2222-4222-8222-222222222222",
	Date:                  "2026-09-06",
	Timestamp:             time.Date(2026, 9, 6, 17, 0, 0, 0, time.UTC).UnixMilli(),
	Kind:                  "momentaryEmotion",
	Valence:               ptr(0.500001),
	ValenceClassification: ptr("slightlyPleasant"),
	Labels:                []string{"calm", "grateful"},
	Associations:          []string{"family"},
}}}

const (
	defaultUserID = "5ea4d000-0000-4000-8000-000000000001"
	otherUserID   = "7b2c9e10-1111-4222-8333-444455556666"
)

// Two people share the server: the seeded default, who synced, and a
// second phone that has not yet.
var fixtureUsers = UsersResponse{
	Users: []User{
		{
			UserID: defaultUserID, Name: ptr("Test Person"), Email: ptr("test@example.com"),
			CreatedAt: time.Date(2026, 1, 21, 9, 0, 0, 0, time.UTC).UnixMilli(),
			LastSync:  ptr(time.Date(2026, 9, 6, 22, 30, 0, 0, time.UTC).UnixMilli()),
			Batches:   1200, UploadedSamples: 3_400_000,
		},
		{
			UserID: otherUserID, CreatedAt: time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC).UnixMilli(),
		},
	},
	Default:   defaultUserID,
	MultiUser: false,
}

func TestNewAPIClient_ValidatesURL(t *testing.T) {
	for _, bad := range []string{"", "localhost:8081", "ftp://host", "http://", "not a url"} {
		if _, err := NewAPIClient(bad, "t", nil); err == nil {
			t.Errorf("NewAPIClient(%q) accepted an invalid URL", bad)
		}
	}
	c, err := NewAPIClient("https://host.example/api/", "t", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := c.BaseURL(); got != "https://host.example/api" {
		t.Errorf("BaseURL = %q, want trailing slash dropped", got)
	}
}

// This server hands its errors to a language model and its startup line to a
// log. A PULS_API_URL carrying userinfo used to print the password to both.
func TestNewAPIClient_DropsCredentialsFromTheURL(t *testing.T) {
	const secret = "sup3rsecret"

	c, err := NewAPIClient("http://alice:"+secret+"@host.example:8081/", "t", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := c.BaseURL(); strings.Contains(got, secret) || strings.Contains(got, "alice") {
		t.Fatalf("BaseURL = %q, want no userinfo", got)
	}
	if got, want := c.BaseURL(), "http://host.example:8081"; got != want {
		t.Fatalf("BaseURL = %q, want %q", got, want)
	}

	// The same string reaches the model on a transport error, so the request
	// path must not reintroduce it either. Point at a closed port to force one.
	closed, err := NewAPIClient("http://alice:"+secret+"@127.0.0.1:1/", "t", nil)
	if err != nil {
		t.Fatal(err)
	}
	err = closed.get(context.Background(), "/v1/profile", nil, &struct{}{})
	if err == nil {
		t.Fatal("expected a transport error from a closed port")
	}
	if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "alice") {
		t.Fatalf("the error handed to the model leaks credentials: %v", err)
	}

	// And the message for a URL that does not parse as http(s) is redacted too.
	_, err = NewAPIClient("ftp://alice:"+secret+"@host.example/", "t", nil)
	if err == nil {
		t.Fatal("expected an error for a non-http scheme")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("the validation error leaks the password: %v", err)
	}
}

func TestAPIClient_SendsBearerAndPath(t *testing.T) {
	f := newFakeAPI(t)
	f.respond("/v1/profile", http.StatusOK, fixtureProfile)
	p, err := f.client(t).Profile(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if p.UserID != fixtureProfile.UserID || *p.Name != "Test Person" {
		t.Errorf("profile = %+v", p)
	}
	// A wrong token is a 401 the client reports with the hint.
	wrong, _ := NewAPIClient(f.srv.URL, "nope", f.srv.Client())
	_, err = wrong.Profile(context.Background())
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != http.StatusUnauthorized {
		t.Fatalf("err = %v, want 401 APIError", err)
	}
	if !strings.Contains(err.Error(), "401") || !strings.Contains(err.Error(), "PULS_API_TOKEN") {
		t.Errorf("401 message lacks status or hint: %s", err)
	}
}

// A pinned client names its user on every read, an unpinned one on none —
// the API's default applies then — and /v1/users, a listing rather than a
// per-user read, never carries it.
func TestAPIClient_SendsUserWhenPinned(t *testing.T) {
	f := newFakeAPI(t)
	f.respond("/v1/profile", http.StatusOK, fixtureProfile)
	f.respond("/v1/metrics/latest", http.StatusOK, fixtureLatest)
	f.respond("/v1/users", http.StatusOK, fixtureUsers)
	ctx := context.Background()

	plain := f.client(t)
	if _, err := plain.Profile(ctx); err != nil {
		t.Fatal(err)
	}
	if q := f.lastQuery(t, "/v1/profile"); q.Has("user") {
		t.Errorf("unpinned client sent user=%q", q.Get("user"))
	}
	if plain.User() != "" {
		t.Errorf("User() = %q, want empty", plain.User())
	}

	pinned := plain.ForUser(otherUserID)
	if plain.User() != "" {
		t.Error("ForUser changed the receiver")
	}
	if pinned.User() != otherUserID {
		t.Errorf("User() = %q", pinned.User())
	}
	if _, err := pinned.Profile(ctx); err != nil {
		t.Fatal(err)
	}
	if got := f.lastQuery(t, "/v1/profile").Get("user"); got != otherUserID {
		t.Errorf("user = %q, want %q (a nil query must still carry it)", got, otherUserID)
	}
	// Alongside the call's own parameters, not instead of them.
	if _, err := pinned.LatestMetrics(ctx, []string{"HKQuantityTypeIdentifierBodyMass"}); err != nil {
		t.Fatal(err)
	}
	q := f.lastQuery(t, "/v1/metrics/latest")
	if q.Get("user") != otherUserID || q.Get("types") != "HKQuantityTypeIdentifierBodyMass" {
		t.Errorf("query = %v", q)
	}

	users, err := pinned.Users(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if q := f.lastQuery(t, "/v1/users"); q.Has("user") {
		t.Errorf("/v1/users carried user=%q", q.Get("user"))
	}
	if len(users.Users) != 2 || users.Default != defaultUserID || users.MultiUser {
		t.Errorf("users = %+v", users)
	}
	if u := users.Users[1]; u.LastSync != nil || u.Name != nil {
		t.Errorf("never-synced user = %+v, want nil lastSync and name", u)
	}
}

// The API's 403 is the multi-user gate; the model needs to be told what it
// means rather than left to retry.
func TestAPIClient_ForbiddenExplainsMultiUserGate(t *testing.T) {
	f := newFakeAPI(t)
	f.respond("/v1/profile", http.StatusForbidden, map[string]string{"error": "multi-user reads are disabled"})
	_, err := f.client(t).ForUser(otherUserID).Profile(context.Background())
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != http.StatusForbidden {
		t.Fatalf("err = %v, want 403 APIError", err)
	}
	for _, want := range []string{"403", "multi-user reads are disabled", "PULS_MULTI_USER", "list_users"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("403 message %q lacks %q", err, want)
		}
	}
}

func TestAPIClient_ErrorPropagation(t *testing.T) {
	f := newFakeAPI(t)
	f.respond("/v1/workouts/"+workoutUUID, http.StatusNotFound, map[string]string{"error": "workout not found"})
	f.raw("/v1/catalog/types", http.StatusInternalServerError, "<html>boom</html>")
	f.raw("/v1/profile", http.StatusOK, `{"userID": `)
	c := f.client(t)
	ctx := context.Background()

	_, err := c.Workout(ctx, workoutUUID)
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("err = %v, want APIError", err)
	}
	if apiErr.Status != 404 || apiErr.Message != "workout not found" || !strings.Contains(err.Error(), "404 Not Found") {
		t.Errorf("404 error = %+v (%s)", apiErr, err)
	}

	_, err = c.CatalogTypes(ctx)
	if !errors.As(err, &apiErr) || apiErr.Status != 500 || !strings.Contains(err.Error(), "boom") {
		t.Errorf("500 with a non-JSON body: %v", err)
	}

	if _, err = c.Profile(ctx); err == nil || !strings.Contains(err.Error(), "malformed JSON") {
		t.Errorf("truncated body: %v", err)
	}

	closed := httptest.NewServer(http.NotFoundHandler())
	closed.Close()
	unreachable, _ := NewAPIClient(closed.URL, "t", nil)
	if _, err = unreachable.Profile(ctx); err == nil || !strings.Contains(err.Error(), "unreachable") {
		t.Errorf("closed server: %v", err)
	}
}

func TestAPIClient_DailyMetricsFollowsPages(t *testing.T) {
	f := newFakeAPI(t)
	// Three pages of dailyPageSize day rows: the first ends inside
	// StepCount, the second opens with the rest of it and all of BodyMass,
	// the third is short.
	day := func(i int) DailyPoint {
		v := float64(i)
		return DailyPoint{Date: fmt.Sprintf("2026-%02d-%02d", 1+i/28, 1+i%28), Value: &v}
	}
	steps := make([]DailyPoint, 0, dailyPageSize+5)
	for i := 0; i < dailyPageSize+5; i++ {
		steps = append(steps, day(i))
	}
	f.routes["/v1/metrics/daily"] = func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("limit") != strconv.Itoa(dailyPageSize) {
			t.Errorf("limit = %q, want %d", r.URL.Query().Get("limit"), dailyPageSize)
		}
		var metrics []DailyMetric
		switch r.URL.Query().Get("offset") {
		case "0":
			metrics = []DailyMetric{{Identifier: "HKQuantityTypeIdentifierStepCount", Days: steps[:dailyPageSize]}}
		case strconv.Itoa(dailyPageSize):
			body := make([]DailyPoint, 0, dailyPageSize)
			body = append(body, steps[dailyPageSize:]...)
			for len(body) < dailyPageSize {
				body = append(body, day(len(body)))
			}
			metrics = []DailyMetric{
				{Identifier: "HKQuantityTypeIdentifierStepCount", Days: steps[dailyPageSize:]},
				{Identifier: "HKQuantityTypeIdentifierBodyMass", Days: body[5:]},
			}
		case strconv.Itoa(2 * dailyPageSize):
			metrics = []DailyMetric{{Identifier: "HKQuantityTypeIdentifierBodyMass", Days: []DailyPoint{day(1)}}}
		default:
			t.Errorf("unexpected offset %q", r.URL.Query().Get("offset"))
		}
		n := 0
		for _, m := range metrics {
			n += len(m.Days)
		}
		offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
		writeJSON(w, http.StatusOK, map[string]any{"metrics": metrics, "nextOffset": offset + n})
	}

	got, err := f.client(t).DailyMetrics(context.Background(), []string{"HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierBodyMass"}, 0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if calls := f.callsTo("/v1/metrics/daily"); len(calls) != 3 {
		t.Fatalf("calls = %d, want 3: %v", len(calls), calls)
	}
	if len(got) != 2 || got[0].Identifier != "HKQuantityTypeIdentifierStepCount" || got[1].Identifier != "HKQuantityTypeIdentifierBodyMass" {
		t.Fatalf("metrics = %d entries, want StepCount then BodyMass", len(got))
	}
	if len(got[0].Days) != dailyPageSize+5 {
		t.Errorf("StepCount days = %d, want %d (the second page's rows appended)", len(got[0].Days), dailyPageSize+5)
	}
	if len(got[1].Days) != dailyPageSize-5+1 {
		t.Errorf("BodyMass days = %d, want %d", len(got[1].Days), dailyPageSize-5+1)
	}
	if got[0].Days[dailyPageSize].Date != steps[dailyPageSize].Date {
		t.Errorf("the boundary row is out of order: %+v", got[0].Days[dailyPageSize])
	}

	// An API without paging (no nextOffset, the whole range) is one call.
	g := newFakeAPI(t)
	g.respond("/v1/metrics/daily", http.StatusOK, map[string]any{"metrics": []DailyMetric{{Identifier: "HKQuantityTypeIdentifierStepCount", Days: steps[:3]}}})
	got, err = g.client(t).DailyMetrics(context.Background(), []string{"HKQuantityTypeIdentifierStepCount"}, 0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(g.callsTo("/v1/metrics/daily")) != 1 || len(got) != 1 || len(got[0].Days) != 3 {
		t.Errorf("unpaged answer: %d calls, %+v", len(g.callsTo("/v1/metrics/daily")), got)
	}

	// An empty answer is an empty slice, never nil.
	h := newFakeAPI(t)
	h.respond("/v1/metrics/daily", http.StatusOK, map[string]any{"metrics": []DailyMetric{}, "nextOffset": 0})
	if got, err = h.client(t).DailyMetrics(context.Background(), []string{"HKQuantityTypeIdentifierStepCount"}, 0, 1); err != nil || got == nil || len(got) != 0 {
		t.Errorf("empty answer = %v, %v", got, err)
	}
}

func TestAPIClient_WorkoutsQuery(t *testing.T) {
	f := newFakeAPI(t)
	f.respond("/v1/workouts", http.StatusOK, WorkoutsPage{Workouts: []WorkoutSummary{}, NextOffset: 0})
	c := f.client(t)
	start, end := int64(1000), int64(2000)
	if _, err := c.Workouts(context.Background(), WorkoutFilters{StartMS: &start, EndMS: &end, ActivityType: "running", Limit: 20, Offset: 40}); err != nil {
		t.Fatal(err)
	}
	q := f.lastQuery(t, "/v1/workouts")
	for k, want := range map[string]string{"start": "1000", "end": "2000", "activityType": "running", "limit": "20", "offset": "40"} {
		if got := q.Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
	if _, err := c.Workouts(context.Background(), WorkoutFilters{Limit: 50}); err != nil {
		t.Fatal(err)
	}
	q = f.lastQuery(t, "/v1/workouts")
	if q.Has("start") || q.Has("end") || q.Has("activityType") {
		t.Errorf("absent filters were sent: %v", q)
	}
}
