package main

import (
	"net/http"
	"strconv"
	"strings"
)

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"name":        "PulsHealth Product API",
		"version":     "v1",
		"docs":        "/docs",
		"openapi":     "/openapi.json",
		"health":      "/healthz",
		"auth":        "Authorization: Bearer $PULS_API_TOKEN",
		"user":        "Optional ?user=<uuid> on every /v1 route selects the user (default PULS_USER_ID; others need PULS_MULTI_USER=true); GET /v1/users lists them.",
		"description": "Read-only API for downstream products that use PulsHealth data.",
	})
}

func (s *Server) handleDocs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(productAPIDocsHTML))
}

func (s *Server) handleOpenAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/openapi+json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(openAPIDocument(requestOrigin(r, s.trustProxyHeaders))))
}

// openAPIOriginPlaceholder is the servers[0].url the stored document
// carries; every request fills it in with the base URL that request
// arrived on. Importers that build a client from the document — ChatGPT
// Actions above all — refuse a document whose servers entry is not a real
// URL, and a deployment cannot know its own public name.
const openAPIOriginPlaceholder = `"{{origin}}"`

// openAPIDocument is the served OpenAPI document for a deployment reachable
// at origin.
func openAPIDocument(origin string) string {
	return strings.Replace(productAPIOpenAPIJSON, openAPIOriginPlaceholder, strconv.Quote(origin), 1)
}

// requestOrigin reconstructs the base URL this request reached the API on,
// honouring the headers a TLS-terminating proxy sets (Tailscale Serve,
// Caddy, nginx), so the document a client downloads names the host that
// client used rather than the loopback address the service binds to. A host
// that is not a plausible authority falls back to "/", the relative server
// URL every OpenAPI 3.1 tool accepts.
//
// X-Forwarded-* is believed only when trustProxy says a proxy owns it — the
// same TRUST_PROXY_HEADERS switch, and the same default of off, that ingest
// applies to the rate-limit key. /openapi.json is unauthenticated, so without
// the gate any caller could choose the host the document advertises; and
// docs/ai.md tells people to fetch that document over a public URL and hand it
// to ChatGPT together with PULS_API_TOKEN, which makes a document naming the
// wrong host a way to deliver a credential somewhere it should not go.
func requestOrigin(r *http.Request, trustProxy bool) string {
	host := r.Host
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if trustProxy {
		if forwarded := firstForwardedValue(r.Header.Get("X-Forwarded-Host")); forwarded != "" {
			host = forwarded
		}
		switch firstForwardedValue(r.Header.Get("X-Forwarded-Proto")) {
		case "https":
			scheme = "https"
		case "http":
			scheme = "http"
		}
	}
	if !isHostAuthority(host) {
		return "/"
	}
	return scheme + "://" + host
}

// firstForwardedValue takes the first entry of a comma-separated
// X-Forwarded-* header, which is the one the client actually asked for.
func firstForwardedValue(header string) string {
	first, _, _ := strings.Cut(header, ",")
	return strings.TrimSpace(first)
}

// isHostAuthority accepts the characters a host[:port] authority may hold —
// letters, digits, dot, hyphen, colon, and the brackets of an IPv6 literal —
// and nothing else, so no header can inject into the document.
func isHostAuthority(host string) bool {
	if host == "" || len(host) > 255 {
		return false
	}
	alphanumeric := false
	for i := 0; i < len(host); i++ {
		c := host[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			alphanumeric = true
		case c == '.' || c == '-' || c == ':' || c == '[' || c == ']':
		default:
			return false
		}
	}
	// Punctuation alone ("::::", "-") passes the character test but is not a
	// host; an importer would reject the resulting URL with a far more
	// confusing message than the relative "/" fallback gives.
	return alphanumeric
}

const productAPIDocsHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>PulsHealth Product API</title>
  <style>
    :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; line-height: 1.5; background: Canvas; color: CanvasText; }
    main { max-width: 940px; margin: 0 auto; padding: 40px 20px 64px; }
    h1 { margin: 0 0 8px; font-size: 2rem; }
    h2 { margin: 32px 0 12px; font-size: 1.15rem; }
    p { max-width: 760px; }
    table { border-collapse: collapse; width: 100%; margin-top: 12px; }
    th, td { border-bottom: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 10px 8px; text-align: left; vertical-align: top; }
    th { font-size: 0.85rem; text-transform: uppercase; letter-spacing: .04em; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .94em; }
    pre { overflow-x: auto; padding: 14px; border-radius: 8px; background: color-mix(in srgb, CanvasText 8%, transparent); }
    .muted { color: color-mix(in srgb, CanvasText 68%, transparent); }
  </style>
</head>
<body>
<main>
  <h1>PulsHealth Product API</h1>
  <p class="muted">Read-only API for downstream products that use PulsHealth data.</p>

  <h2>Access</h2>
  <p>Send <code>Authorization: Bearer $PULS_API_TOKEN</code> on every data request. Discovery endpoints <code>/</code>, <code>/docs</code>, <code>/openapi.json</code>, and <code>/healthz</code> are available without the token.</p>
  <pre><code>curl -H "Authorization: Bearer $PULS_API_TOKEN" "$PULS_API_BASE_URL/v1/catalog/types"</code></pre>
  <p>Every data request is answered for one user. By default that is the deployment&rsquo;s <code>PULS_USER_ID</code>; add <code>user=&lt;uuid&gt;</code> to any <code>/v1</code> query to ask about someone else. That is only allowed when the server runs with <code>PULS_MULTI_USER=true</code> &mdash; otherwise naming any other user is a <code>403</code>, never a quiet answer for the default user &mdash; and a value that is not a UUID is a <code>400</code>. Neither counts against the failed-authentication limit. <code>GET /v1/users</code> lists the users this deployment will answer for, with their upload counts.</p>

  <h2>Discovery</h2>
  <table>
    <thead><tr><th>Method</th><th>Path</th><th>Use</th></tr></thead>
    <tbody>
      <tr><td><code>GET</code></td><td><code>/</code></td><td>JSON index for the API.</td></tr>
      <tr><td><code>GET</code></td><td><code>/docs</code></td><td>This human-readable reference.</td></tr>
      <tr><td><code>GET</code></td><td><code>/openapi.json</code></td><td>Machine-readable OpenAPI 3.1 schema.</td></tr>
      <tr><td><code>GET</code></td><td><code>/healthz</code></td><td>Liveness and database ping.</td></tr>
    </tbody>
  </table>

  <h2>Data Endpoints</h2>
  <table>
    <thead><tr><th>Method</th><th>Path</th><th>Query</th><th>Returns</th></tr></thead>
    <tbody>
      <tr><td><code>GET</code></td><td><code>/v1/users</code></td><td></td><td>Who this deployment answers for: each user with name, e-mail, last sync and upload counts, plus the default user and whether <code>user=</code> may name others.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/profile</code></td><td></td><td>The user&rsquo;s profile fields.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/catalog/types</code></td><td></td><td>Available HealthKit identifiers, kind, unit, raw/aggregate row counts, earliest/latest timestamps.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/metrics/latest</code></td><td><code>types=a,b</code></td><td>Latest quantity value per requested identifier.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/metrics/daily</code></td><td><code>types=a,b&amp;start=ms&amp;end=ms</code>, <code>limit?</code>, <code>offset?</code></td><td>Local-day metric series from <code>metric_daily</code>, paged in days.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/activity/summary</code></td><td><code>start=ms&amp;end=ms</code></td><td>Activity rings by day.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/workouts</code></td><td><code>start?</code>, <code>end?</code>, <code>activityType?</code>, <code>limit?</code>, <code>offset?</code></td><td>Workout summaries and pagination offset.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/workouts/{uuid}</code></td><td></td><td>Workout detail, available metrics, statistics, events, and activities.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/workouts/{uuid}/series</code></td><td><code>types?</code>, <code>maxPoints?</code></td><td>Intra-workout streams (heart rate, power, speed, &hellip;) as <code>[t, value]</code> pairs, downsampled.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/sleep/daily</code></td><td><code>start=ms&amp;end=ms</code></td><td>One row per night, attributed to the wake-up day, with stage minutes.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/samples</code></td><td><code>type</code>, <code>start=ms&amp;end=ms</code>, <code>limit?</code>, <code>offset?</code></td><td>Raw samples of one quantity or category type.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/state-of-mind</code></td><td><code>start=ms&amp;end=ms</code></td><td>State of Mind entries: valence, labels, associations.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/summary</code></td><td><code>range?</code> (<code>7d</code>, <code>14d</code>, <code>30d</code>, <code>90d</code>), <code>format?</code> (<code>markdown</code>, <code>json</code>)</td><td>The last N days as one short markdown page &mdash; activity, heart, sleep, workouts, body, coverage &mdash; for pasting into a chat.</td></tr>
      <tr><td><code>GET</code></td><td><code>/v1/export</code></td><td><code>format</code>, <code>dataset</code>, <code>start=ms&amp;end=ms</code>, plus that dataset's filters</td><td>A whole range as a streamed CSV or JSONL download.</td></tr>
    </tbody>
  </table>

  <h2>Sleep</h2>
  <p><code>/v1/sleep/daily</code> returns one row per sleep session. A session is attributed to the local calendar day it <em>ends</em> on — the wake-up day, matching Apple Health — and samples more than three hours apart start a new session, so a nap gets its own row. All durations are minutes.</p>
  <p>An iPhone, an Apple Watch and a third-party app can all record the same night. The endpoint never sums them: <code>inBedMinutes</code> is the highest single-source in-bed total, and <code>asleepMinutes</code> plus the whole <code>stages</code> breakdown come together from the one source that recorded the most sleep (ties go to the source with more stage detail). <code>sources</code> counts how many contributed. <code>asleepMinutes</code> is core + deep + REM + unspecified; <code>stages.awake</code> is time awake during the session and is not part of it. This mirrors the web viewer's daily sleep series.</p>

  <h2>Daily metrics</h2>
  <p><code>/v1/metrics/daily</code> returns one value per local calendar day for each requested type, nested as <code>metrics[].days[]</code> in the order the types were asked for, each ascending by day. It pages in <strong>days across the requested types</strong>: <code>limit</code> (default 10000, caps at 50000) and <code>offset</code> count day rows, not metrics, and <code>nextOffset</code> is <code>offset</code> plus the rows on the page &mdash; a short page (fewer rows than <code>limit</code>) is the last. A page boundary can fall inside a metric&rsquo;s days, so the next page may open with a metric the previous one already carried; append its days. A request that names no <code>limit</code> gets the default page, which holds a year of 27 types or a decade of two; a wider request pages. Only types the phone aggregates daily appear (<code>/v1/catalog/types</code> shows <code>aggregateRows</code>), and the values are deduplicated across devices.</p>

  <h2>Raw samples</h2>
  <p><code>/v1/samples</code> serves individual HealthKit records for exactly one type, ordered by start time, at most 31 days per request (<code>limit</code> defaults to 1000, caps at 5000; page with <code>nextOffset</code>). Unlike <code>/v1/metrics/daily</code> these are <strong>not</strong> deduplicated: if an iPhone and an Apple Watch both recorded the same minutes, both rows come back. A quantity sample carries <code>value</code> in the page's canonical <code>unit</code>; a category sample carries the integer <code>value</code> and its HealthKit <code>label</code>.</p>

  <h2>Summary</h2>
  <p><code>/v1/summary</code> is the endpoint for a chat that has no MCP connection: one short markdown page (under sixty lines) covering the last <code>range</code> calendar days &mdash; <code>7d</code> (the default), <code>14d</code>, <code>30d</code> or <code>90d</code>, ending today in <code>PULS_TIME_ZONE</code> &mdash; that you fetch with <code>curl</code> and paste. It carries a header (whose data, which days, when it was generated and in which zone), then a section for each kind of data that exists: activity (steps, active energy, exercise minutes and stand hours, each as a daily mean and, where a sum means something, a total), heart (resting heart rate and HRV), sleep (time asleep per night over the longest session of each wake-up day), workouts (count, total time, distance, the most frequent activities), body (the newest weight and body-fat readings, whenever they were taken) and a coverage line (last sync, days with data, and the reminder that daily figures are already deduplicated across devices). Every figure comes from the same daily surfaces as the endpoints above &mdash; <code>metric_daily</code>, the Activity rings, <code>/v1/sleep/daily</code>, <code>/v1/workouts</code>, <code>/v1/metrics/latest</code> &mdash; so it is cheap, and nothing in it is a sum of raw samples. <code>format=json</code> returns the same numbers as a <code>Summary</code> object instead of prose.</p>
  <pre><code>curl -H "Authorization: Bearer $PULS_API_TOKEN" "$PULS_API_BASE_URL/v1/summary?range=7d"</code></pre>

  <h2>Export</h2>
  <p><code>/v1/export</code> returns a whole range as a file rather than a JSON document, for a spreadsheet, a notebook, or a chat attachment. Both parameters are required: <code>format</code> is <code>csv</code> or <code>jsonl</code>, <code>dataset</code> is one of <code>daily_metrics</code>, <code>samples</code>, <code>workouts</code>, <code>sleep</code>, <code>activity</code>, <code>state_of_mind</code>. <code>start</code> and <code>end</code> are required for every dataset; <code>daily_metrics</code> also takes <code>types</code>, <code>samples</code> takes <code>type</code>, and <code>workouts</code> takes an optional <code>activityType</code>.</p>
  <pre><code>curl -fL -H "Authorization: Bearer $PULS_API_TOKEN" -OJ \
  "$PULS_API_BASE_URL/v1/export?format=csv&amp;dataset=sleep&amp;start=1735689600000&amp;end=1738368000000"</code></pre>
  <p>The response is streamed (<code>Transfer-Encoding: chunked</code>) and arrives as an attachment called <code>puls-&lt;dataset&gt;-&lt;start&gt;-&lt;end&gt;.&lt;csv|jsonl&gt;</code>. CSV opens with a header row; JSONL writes one JSON object per line whose keys are exactly those column names. Field names are the JSON endpoints' names; where an endpoint nests, the export flattens — a metric's days become one row each carrying <code>identifier</code> and <code>unit</code>, a night's stage minutes become <code>stages.core</code>, <code>stages.deep</code> and so on, and a list (a workout's <code>availableMetrics</code>, an entry's <code>labels</code>) is comma-joined inside its CSV cell and stays an array in JSONL. Ranges are capped at 31 days for <code>samples</code>, as on <code>/v1/samples</code>, and 366 days for every other dataset — the cap <code>/v1/sleep/daily</code> and <code>/v1/state-of-mind</code> already apply, and deliberately stricter than <code>/v1/metrics/daily</code> and <code>/v1/workouts</code>, which are bounded by a page size instead, and <code>/v1/activity/summary</code>, which is one small row per day. <code>daily_metrics</code> and <code>workouts</code> return the whole range (workouts newest first); <code>limit</code> and <code>offset</code> do not apply to an export. At most two exports run at once — each holds a database connection for the length of the download — and a third gets a <code>503</code> with <code>Retry-After</code>. A failure after the first rows are on the wire aborts the connection, so a truncated file is always a visibly failed download rather than a short one.</p>

  <h2>Conventions</h2>
  <p>Every <code>/v1</code> endpoint takes the optional <code>user</code> parameter described under Access. All timestamps are epoch milliseconds (0 to 253402300799999; anything else is a <code>400</code>). Workout ranges are <code>[start, end)</code> on the workout start time. The daily endpoints (<code>/v1/metrics/daily</code>, <code>/v1/activity/summary</code>) return every local calendar day — in the server's configured zone, <code>PULS_TIME_ZONE</code> — that overlaps <code>[start, end)</code>, so a range that touches one minute of a day returns that whole day. Paged endpoints (<code>/v1/metrics/daily</code>, <code>/v1/workouts</code>, <code>/v1/samples</code>) take <code>limit</code> and <code>offset</code> and answer with <code>nextOffset</code>; a page shorter than <code>limit</code> is the last. <code>/v1/sleep/daily</code> and <code>/v1/state-of-mind</code> use those same local days and reject ranges over 366 days. Empty result sets return empty arrays.</p>
</main>
</body>
</html>
`

const productAPIOpenAPIJSON = `{
  "openapi": "3.1.0",
  "info": {
    "title": "PulsHealth Product API",
    "version": "1.0.0",
    "description": "Read-only API for downstream products that use PulsHealth data."
  },
  "servers": [{ "url": "{{origin}}", "description": "This PulsHealth deployment (the base URL this document was fetched from)." }],
  "security": [{ "bearerAuth": [] }],
  "components": {
    "securitySchemes": {
      "bearerAuth": { "type": "http", "scheme": "bearer" }
    },
    "schemas": {
      "Profile": {
        "type": "object",
        "properties": {
          "userID": { "type": "string", "format": "uuid" },
          "name": { "type": ["string", "null"] },
          "email": { "type": ["string", "null"] },
          "dateOfBirth": { "type": ["integer", "null"], "format": "int64" },
          "biologicalSex": { "type": ["string", "null"] }
        }
      },
      "User": {
        "type": "object",
        "description": "One user the deployment answers for, with what the batches log says about their uploads.",
        "properties": {
          "userID": { "type": "string", "format": "uuid" },
          "name": { "type": ["string", "null"] },
          "email": { "type": ["string", "null"] },
          "createdAt": { "type": "integer", "format": "int64" },
          "lastSync": { "type": ["integer", "null"], "format": "int64", "description": "Epoch milliseconds of the most recent batch; null when nothing has been uploaded." },
          "batches": { "type": "integer", "format": "int64" },
          "uploadedSamples": { "type": "integer", "format": "int64", "description": "Sum of the sample counts the batches declared." }
        }
      },
      "CatalogType": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" },
          "kind": { "type": "string" },
          "unit": { "type": ["string", "null"] },
          "rows": { "type": "integer", "format": "int64" },
          "rawRows": { "type": "integer", "format": "int64" },
          "aggregateRows": { "type": "integer", "format": "int64" },
          "earliest": { "type": ["integer", "null"], "format": "int64" },
          "latest": { "type": ["integer", "null"], "format": "int64" }
        }
      },
      "LatestMetric": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" },
          "unit": { "type": ["string", "null"] },
          "value": { "type": ["number", "null"] },
          "timestamp": { "type": "integer", "format": "int64" }
        }
      },
      "DailyMetric": {
        "type": "object",
        "description": "One type's local-day series, deduplicated across devices. A page boundary can fall inside days, so the same identifier may open the next page; append its days.",
        "properties": {
          "identifier": { "type": "string" },
          "unit": { "type": ["string", "null"] },
          "days": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "date": { "type": "string", "format": "date" },
                "value": { "type": ["number", "null"] }
              }
            }
          }
        }
      },
      "ActivityDay": {
        "type": "object",
        "properties": {
          "date": { "type": "string", "format": "date" },
          "moveKcal": { "type": ["number", "null"] },
          "moveGoalKcal": { "type": ["number", "null"] },
          "exerciseMin": { "type": ["number", "null"] },
          "exerciseGoalMin": { "type": ["number", "null"] },
          "standHours": { "type": ["number", "null"] },
          "standGoalHours": { "type": ["number", "null"] },
          "moveMode": { "type": ["integer", "null"] },
          "moveTimeMin": { "type": ["number", "null"] },
          "moveTimeGoalMin": { "type": ["number", "null"] }
        }
      },
      "WorkoutSummary": {
        "type": "object",
        "properties": {
          "uuid": { "type": "string", "format": "uuid" },
          "activityType": { "type": "string" },
          "start": { "type": "integer", "format": "int64" },
          "end": { "type": "integer", "format": "int64" },
          "durationS": { "type": ["number", "null"] },
          "distanceM": { "type": ["number", "null"] },
          "energyKcal": { "type": ["number", "null"] },
          "hasRoute": { "type": "boolean" },
          "availableMetrics": { "type": "array", "items": { "type": "string" } }
        }
      },
      "WorkoutDetail": {
        "allOf": [
          { "$ref": "#/components/schemas/WorkoutSummary" },
          {
            "type": "object",
            "properties": {
              "statisticsDetail": {
                "type": "object",
                "additionalProperties": {
                  "type": "object",
                  "properties": {
                    "min": { "type": "number" },
                    "avg": { "type": "number" },
                    "max": { "type": "number" },
                    "sum": { "type": "number" }
                  }
                }
              },
              "events": { "type": "array", "items": { "type": "object", "additionalProperties": true } },
              "activities": { "type": "array", "items": { "type": "object", "additionalProperties": true } }
            }
          }
        ]
      },
      "SleepStages": {
        "type": "object",
        "description": "Minutes per stage, from the single source that recorded the most sleep. asleepMinutes is core + deep + rem + unspecified; awake is time awake during the session and is not part of it.",
        "properties": {
          "core": { "type": "number" },
          "deep": { "type": "number" },
          "rem": { "type": "number" },
          "unspecified": { "type": "number" },
          "awake": { "type": "number" }
        }
      },
      "SleepNight": {
        "type": "object",
        "description": "One sleep session, attributed to the local calendar day it ended on (the wake-up day). Overlapping sources are never summed: inBedMinutes is the highest single-source total and asleepMinutes plus stages come from the source with the most sleep.",
        "properties": {
          "date": { "type": "string", "format": "date", "description": "Local wake-up day." },
          "start": { "type": "integer", "format": "int64" },
          "end": { "type": "integer", "format": "int64" },
          "inBedMinutes": { "type": "number" },
          "asleepMinutes": { "type": "number" },
          "stages": { "$ref": "#/components/schemas/SleepStages" },
          "sources": { "type": "integer", "description": "Distinct sources that contributed samples to this session." }
        }
      },
      "Sample": {
        "type": "object",
        "properties": {
          "uuid": { "type": "string", "format": "uuid" },
          "start": { "type": "integer", "format": "int64" },
          "end": { "type": "integer", "format": "int64" },
          "value": { "type": ["number", "null"], "description": "Quantity value in the page's canonical unit, or the category type's integer enum value." },
          "label": { "type": ["string", "null"], "description": "Category types only: the HealthKit name of value." },
          "source": { "type": ["string", "null"] }
        }
      },
      "SamplesPage": {
        "type": "object",
        "description": "Raw HealthKit samples of one type, ordered by start time. Not deduplicated across devices.",
        "properties": {
          "type": { "type": "string" },
          "kind": { "type": "string", "enum": ["quantity", "category"] },
          "unit": { "type": ["string", "null"] },
          "samples": { "type": "array", "items": { "$ref": "#/components/schemas/Sample" } },
          "nextOffset": { "type": "integer", "description": "Offset to pass for the next page; a short page means the end." }
        }
      },
      "WorkoutSeries": {
        "type": "object",
        "properties": {
          "type": { "type": "string" },
          "unit": { "type": ["string", "null"] },
          "totalPoints": { "type": "integer", "description": "Points recorded before downsampling." },
          "points": {
            "type": "array",
            "description": "[epoch milliseconds, value] pairs, ordered by time.",
            "items": {
              "type": "array",
              "prefixItems": [{ "type": "integer", "format": "int64" }, { "type": "number" }],
              "minItems": 2,
              "maxItems": 2
            }
          }
        }
      },
      "WorkoutSeriesResponse": {
        "type": "object",
        "properties": {
          "uuid": { "type": "string", "format": "uuid" },
          "start": { "type": "integer", "format": "int64" },
          "end": { "type": "integer", "format": "int64" },
          "maxPoints": { "type": "integer" },
          "series": { "type": "array", "items": { "$ref": "#/components/schemas/WorkoutSeries" } }
        }
      },
      "StateOfMindEntry": {
        "type": "object",
        "properties": {
          "uuid": { "type": "string", "format": "uuid" },
          "date": { "type": "string", "format": "date", "description": "Local calendar day of the entry." },
          "timestamp": { "type": "integer", "format": "int64" },
          "kind": { "type": "string", "description": "momentaryEmotion or dailyMood." },
          "valence": { "type": ["number", "null"], "description": "-1 (very unpleasant) to +1 (very pleasant)." },
          "valenceClassification": { "type": ["string", "null"], "description": "Apple's band for valence, e.g. slightlyPleasant." },
          "labels": { "type": "array", "items": { "type": "string" }, "description": "Feelings picked, e.g. calm, stressed." },
          "associations": { "type": "array", "items": { "type": "string" }, "description": "What they are about, e.g. work, family." }
        }
      },
      "SummaryStat": {
        "type": "object",
        "description": "One daily series over the summary's range: the days that had a value and the mean, minimum and maximum of those days. total is present for cumulative series only (steps, energy, exercise minutes). source names the table the values came from.",
        "properties": {
          "unit": { "type": "string" },
          "days": { "type": "integer" },
          "mean": { "type": "number" },
          "min": { "type": "number" },
          "max": { "type": "number" },
          "total": { "type": "number" },
          "source": { "type": "string", "enum": ["metric_daily", "activity_summaries"] }
        }
      },
      "SummaryReading": {
        "type": "object",
        "description": "The newest raw sample of a body metric, whenever it was taken.",
        "properties": {
          "value": { "type": "number" },
          "unit": { "type": "string" },
          "timestamp": { "type": "integer", "format": "int64" }
        }
      },
      "Summary": {
        "type": "object",
        "description": "GET /v1/summary?format=json: the numbers behind the markdown page. A section is absent when the range holds no data for it.",
        "properties": {
          "userID": { "type": "string", "format": "uuid" },
          "name": { "type": ["string", "null"] },
          "range": { "type": "string", "enum": ["7d", "14d", "30d", "90d"] },
          "days": { "type": "integer" },
          "startDate": { "type": "string", "format": "date", "description": "First local calendar day covered." },
          "endDate": { "type": "string", "format": "date", "description": "Last local calendar day covered: today in timeZone." },
          "generatedAt": { "type": "integer", "format": "int64" },
          "timeZone": { "type": "string", "description": "The IANA zone (PULS_TIME_ZONE) whose calendar cut the days." },
          "activity": {
            "type": "object",
            "properties": {
              "steps": { "$ref": "#/components/schemas/SummaryStat" },
              "activeEnergy": { "$ref": "#/components/schemas/SummaryStat" },
              "exercise": { "$ref": "#/components/schemas/SummaryStat" },
              "stand": { "$ref": "#/components/schemas/SummaryStat" }
            }
          },
          "heart": {
            "type": "object",
            "properties": {
              "restingHeartRate": { "$ref": "#/components/schemas/SummaryStat" },
              "hrvSDNN": { "$ref": "#/components/schemas/SummaryStat" }
            }
          },
          "sleep": {
            "type": "object",
            "description": "The longest sleep session of each wake-up day in the range.",
            "properties": {
              "nights": { "type": "integer" },
              "meanAsleepMinutes": { "type": "number" },
              "minAsleepMinutes": { "type": "number" },
              "maxAsleepMinutes": { "type": "number" }
            }
          },
          "workouts": {
            "type": "object",
            "properties": {
              "count": { "type": "integer" },
              "totalMinutes": { "type": "number" },
              "totalDistanceM": { "type": "number", "description": "Absent when no workout in the range recorded a distance." },
              "byActivityType": {
                "type": "array",
                "description": "Most frequent first, at most three.",
                "items": { "type": "object", "properties": { "activityType": { "type": "string" }, "count": { "type": "integer" } } }
              }
            }
          },
          "body": {
            "type": "object",
            "properties": {
              "weight": { "$ref": "#/components/schemas/SummaryReading" },
              "bodyFat": { "$ref": "#/components/schemas/SummaryReading" }
            }
          },
          "coverage": {
            "type": "object",
            "properties": {
              "lastSync": { "type": ["integer", "null"], "format": "int64", "description": "Epoch milliseconds of the most recent upload; null when nothing has been uploaded." },
              "daysWithData": { "type": "integer", "description": "Days in the range on which at least one section has a value." }
            }
          }
        }
      }
    }
  },
  "paths": {
    "/": {
      "get": {
        "operationId": "getIndex",
        "security": [],
        "summary": "API index",
        "responses": { "200": { "description": "API index" } }
      }
    },
    "/docs": {
      "get": {
        "operationId": "getDocs",
        "security": [],
        "summary": "Human-readable API docs",
        "responses": { "200": { "description": "HTML documentation" } }
      }
    },
    "/openapi.json": {
      "get": {
        "operationId": "getOpenAPI",
        "security": [],
        "summary": "OpenAPI schema",
        "responses": { "200": { "description": "OpenAPI document" } }
      }
    },
    "/healthz": {
      "get": {
        "operationId": "getHealth",
        "security": [],
        "summary": "Health check",
        "responses": { "200": { "description": "Healthy" }, "503": { "description": "Database unavailable" } }
      }
    },
    "/v1/users": {
      "get": {
        "operationId": "listUsers",
        "summary": "Users this deployment answers for",
        "description": "Every user with the gate on (PULS_MULTI_USER=true); only the default user with it off. default is the user served when a request names none (PULS_USER_ID); multiUser says whether ?user= may name anyone else.",
        "responses": { "200": { "description": "Users", "content": { "application/json": { "schema": { "type": "object", "properties": { "users": { "type": "array", "items": { "$ref": "#/components/schemas/User" } }, "default": { "type": "string", "format": "uuid" }, "multiUser": { "type": "boolean" } } } } } } }
      }
    },
    "/v1/profile": {
      "get": {
        "operationId": "getProfile",
        "summary": "User profile",
        "parameters": [{ "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." }],
        "responses": { "200": { "description": "Profile", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Profile" } } } }, "401": { "description": "Unauthorized" }, "404": { "description": "Profile not found" } }
      }
    },
    "/v1/catalog/types": {
      "get": {
        "operationId": "listCatalogTypes",
        "summary": "Available data types",
        "parameters": [{ "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." }],
        "responses": { "200": { "description": "Catalog", "content": { "application/json": { "schema": { "type": "object", "properties": { "types": { "type": "array", "items": { "$ref": "#/components/schemas/CatalogType" } } } } } } } }
      }
    },
    "/v1/metrics/latest": {
      "get": {
        "operationId": "getLatestMetrics",
        "summary": "Latest quantity metrics",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "types", "in": "query", "required": true, "schema": { "type": "string" }, "description": "Comma-separated HealthKit identifiers." }],
        "responses": { "200": { "description": "Latest metrics", "content": { "application/json": { "schema": { "type": "object", "properties": { "metrics": { "type": "array", "items": { "$ref": "#/components/schemas/LatestMetric" } } } } } } } }
      }
    },
    "/v1/metrics/daily": {
      "get": {
        "operationId": "getDailyMetrics",
        "summary": "Daily metric series",
        "description": "One value per local calendar day (in the server's PULS_TIME_ZONE) for each requested type, every day overlapping [start, end). Paged in days across the requested types: limit and offset count day rows, not metrics, in the order the response nests them (the requested types in request order, each ascending by day); nextOffset is offset plus the rows on the page and a page shorter than limit is the last. The default page holds a year of 27 types.",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "types", "in": "query", "required": true, "schema": { "type": "string" }, "description": "Comma-separated HealthKit identifiers; the response keeps this order." },
          { "name": "start", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "end", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "limit", "in": "query", "required": false, "schema": { "type": "integer", "default": 10000, "maximum": 50000 }, "description": "Day rows per page, across all requested types; larger values are clamped." },
          { "name": "offset", "in": "query", "required": false, "schema": { "type": "integer", "default": 0 }, "description": "Day rows to skip; pass the previous page's nextOffset." }
        ],
        "responses": { "200": { "description": "Daily metrics", "content": { "application/json": { "schema": { "type": "object", "properties": { "metrics": { "type": "array", "items": { "$ref": "#/components/schemas/DailyMetric" } }, "nextOffset": { "type": "integer", "description": "Offset to pass for the next page; a page with fewer day rows than limit means the end." } } } } } }, "400": { "description": "Missing types or range, or an invalid limit or offset" } }
      }
    },
    "/v1/activity/summary": {
      "get": {
        "operationId": "getActivitySummary",
        "summary": "Activity ring summaries",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "start", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "end", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } }
        ],
        "responses": { "200": { "description": "Activity days", "content": { "application/json": { "schema": { "type": "object", "properties": { "days": { "type": "array", "items": { "$ref": "#/components/schemas/ActivityDay" } } } } } } } }
      }
    },
    "/v1/workouts": {
      "get": {
        "operationId": "listWorkouts",
        "summary": "Workout summaries",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "start", "in": "query", "required": false, "schema": { "type": "integer", "format": "int64" } },
          { "name": "end", "in": "query", "required": false, "schema": { "type": "integer", "format": "int64" } },
          { "name": "activityType", "in": "query", "required": false, "schema": { "type": "string" } },
          { "name": "limit", "in": "query", "required": false, "schema": { "type": "integer", "default": 50, "maximum": 200 } },
          { "name": "offset", "in": "query", "required": false, "schema": { "type": "integer", "default": 0 } }
        ],
        "responses": { "200": { "description": "Workouts", "content": { "application/json": { "schema": { "type": "object", "properties": { "workouts": { "type": "array", "items": { "$ref": "#/components/schemas/WorkoutSummary" } }, "nextOffset": { "type": "integer" } } } } } } }
      }
    },
    "/v1/workouts/{uuid}": {
      "get": {
        "operationId": "getWorkout",
        "summary": "Workout detail",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "uuid", "in": "path", "required": true, "schema": { "type": "string", "format": "uuid" } }],
        "responses": { "200": { "description": "Workout detail", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/WorkoutDetail" } } } }, "400": { "description": "Invalid UUID" }, "404": { "description": "Workout not found" } }
      }
    },
    "/v1/workouts/{uuid}/series": {
      "get": {
        "operationId": "getWorkoutSeries",
        "summary": "Intra-workout streams",
        "description": "Per-second curves recorded during the workout, each downsampled to at most maxPoints points by bucket-averaging while keeping the first and last point.",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "uuid", "in": "path", "required": true, "schema": { "type": "string", "format": "uuid" } },
          { "name": "types", "in": "query", "required": false, "schema": { "type": "string" }, "description": "Comma-separated HealthKit identifiers; omit for every recorded stream." },
          { "name": "maxPoints", "in": "query", "required": false, "schema": { "type": "integer", "default": 500, "maximum": 5000 } }
        ],
        "responses": { "200": { "description": "Workout series", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/WorkoutSeriesResponse" } } } }, "400": { "description": "Invalid UUID or parameters" }, "404": { "description": "Workout not found" } }
      }
    },
    "/v1/sleep/daily": {
      "get": {
        "operationId": "getSleepNights",
        "summary": "Sleep nights",
        "description": "One row per sleep session, attributed to the local calendar day it ended on. Sessions are split on gaps over three hours, and every local day overlapping [start, end) is covered.",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "start", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "end", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } }
        ],
        "responses": { "200": { "description": "Sleep nights", "content": { "application/json": { "schema": { "type": "object", "properties": { "nights": { "type": "array", "items": { "$ref": "#/components/schemas/SleepNight" } } } } } } }, "400": { "description": "Invalid range, or a range over 366 days" } }
      }
    },
    "/v1/samples": {
      "get": {
        "operationId": "getSamples",
        "summary": "Raw samples of one type",
        "description": "Individual HealthKit records, ordered by start time, not deduplicated across devices. The range is [start, end) on the sample start time and may not exceed 31 days.",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "type", "in": "query", "required": true, "schema": { "type": "string" }, "description": "Exactly one HealthKit identifier (see /v1/catalog/types)." },
          { "name": "start", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "end", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "limit", "in": "query", "required": false, "schema": { "type": "integer", "default": 1000, "maximum": 5000 } },
          { "name": "offset", "in": "query", "required": false, "schema": { "type": "integer", "default": 0 } }
        ],
        "responses": { "200": { "description": "Samples", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/SamplesPage" } } } }, "400": { "description": "Unknown type, a non-sample type, or a range over 31 days" } }
      }
    },
    "/v1/state-of-mind": {
      "get": {
        "operationId": "getStateOfMind",
        "summary": "State of Mind entries",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "start", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "end", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } }
        ],
        "responses": { "200": { "description": "Entries", "content": { "application/json": { "schema": { "type": "object", "properties": { "entries": { "type": "array", "items": { "$ref": "#/components/schemas/StateOfMindEntry" } } } } } } }, "400": { "description": "Invalid range, or a range over 366 days" } }
      }
    },
    "/v1/summary": {
      "get": {
        "operationId": "getSummary",
        "summary": "A short markdown summary of recent data",
        "description": "The last range calendar days (7d by default; ending today in the server's PULS_TIME_ZONE) as one markdown page of under sixty lines, meant to be pasted into a chat that has no MCP connection: a header naming the user, the days and the zone, then a section for each kind of data that exists — activity (steps, active energy, exercise minutes, stand hours as daily means and totals), heart (resting heart rate, HRV), sleep (time asleep per night), workouts (count, total time, distance, most frequent activities), body (newest weight and body fat) — and a coverage line (last sync, days with data, and the reminder that daily figures are already deduplicated across devices). Every figure comes from the daily surfaces the other endpoints serve, never from raw samples. format=json returns the same numbers as a Summary object.",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "range", "in": "query", "required": false, "schema": { "type": "string", "enum": ["7d", "14d", "30d", "90d"], "default": "7d" }, "description": "How many calendar days, ending today, the summary covers." },
          { "name": "format", "in": "query", "required": false, "schema": { "type": "string", "enum": ["markdown", "json"], "default": "markdown" }, "description": "markdown for the page (text/markdown), json for the Summary object it is rendered from." }
        ],
        "responses": {
          "200": {
            "description": "The summary",
            "content": {
              "text/markdown": { "schema": { "type": "string" } },
              "application/json": { "schema": { "$ref": "#/components/schemas/Summary" } }
            }
          },
          "400": { "description": "A range or format outside the accepted values" },
          "401": { "description": "Unauthorized" }
        }
      }
    },
    "/v1/export": {
      "get": {
        "operationId": "exportDataset",
        "summary": "Bulk export one dataset as CSV or JSONL",
        "description": "Streams a whole range as a file (Transfer-Encoding: chunked, Content-Disposition: attachment) instead of a JSON document. CSV opens the file with a header row; JSONL writes one JSON object per line whose keys are the same column names. Field names match the JSON endpoints; where an endpoint nests (a metric's days, a night's stages) the export flattens, repeating the identifying fields on every row and naming a nested field by its path. Ranges are capped at 31 days for samples (as /v1/samples is) and 366 days for every other dataset — the same cap /v1/sleep/daily and /v1/state-of-mind apply, and deliberately stricter than /v1/metrics/daily and /v1/workouts, which are bounded by a page size rather than by their range, and /v1/activity/summary, which is one small row per day. The daily_metrics and workouts datasets return the whole range (workouts newest first); limit and offset are not used here. At most 2 exports run at once, because each holds a database connection for the length of the download; over that is a 503 with Retry-After.",
        "parameters": [
          { "name": "user", "in": "query", "required": false, "schema": { "type": "string", "format": "uuid" }, "description": "The user to answer for; defaults to the deployment's PULS_USER_ID. Any other user needs PULS_MULTI_USER=true, else 403. /v1/users lists them." },
          { "name": "format", "in": "query", "required": true, "schema": { "type": "string", "enum": ["csv", "jsonl"] } },
          { "name": "dataset", "in": "query", "required": true, "schema": { "type": "string", "enum": ["daily_metrics", "samples", "workouts", "sleep", "activity", "state_of_mind"] } },
          { "name": "start", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "end", "in": "query", "required": true, "schema": { "type": "integer", "format": "int64" } },
          { "name": "types", "in": "query", "required": false, "schema": { "type": "string" }, "description": "daily_metrics only, and required there: comma-separated HealthKit identifiers." },
          { "name": "type", "in": "query", "required": false, "schema": { "type": "string" }, "description": "samples only, and required there: exactly one HealthKit identifier." },
          { "name": "activityType", "in": "query", "required": false, "schema": { "type": "string" }, "description": "workouts only: keep one activity type." }
        ],
        "responses": {
          "200": {
            "description": "The dataset, streamed as an attachment named puls-<dataset>-<start>-<end>.<csv|jsonl>",
            "content": {
              "text/csv": { "schema": { "type": "string" } },
              "application/x-ndjson": { "schema": { "type": "string" } }
            }
          },
          "400": { "description": "Missing or invalid format or dataset, a missing dataset parameter, an unknown type, or a range over the dataset's cap" },
          "401": { "description": "Unauthorized" },
          "503": { "description": "Too many exports already in progress; retry after the Retry-After interval" }
        }
      }
    }
  }
}
`
