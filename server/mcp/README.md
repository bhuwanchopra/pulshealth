# PulsHealth MCP server

A read-only [Model Context Protocol](https://modelcontextprotocol.io) server
that lets AI assistants — Claude Desktop, Claude Code, Cursor, and any client
that speaks MCP — answer questions from your Apple Health data. It is one Go
binary that talks **only to the product API** (`server/api`): it never opens
a database connection, so the API's bearer token and read-only database role
remain the whole trust boundary, and the API's deduplicated daily surfaces
are what the model sees.

For the client-side setup (config snippets, the remote-connector recipe, demo
prompts) see [`docs/ai.md`](../../docs/ai.md).

## What it exposes

| Tool | Answers |
|---|---|
| `list_users` | Everyone with data on the server, which one is the API's default, whether `multi_user` reads are on, and which user this instance is pinned to (if any). |
| `get_summary(range?)` | `GET /v1/summary` as markdown text: the last 7d (default), 14d, 30d or 90d in under sixty lines — activity, heart, sleep, workouts, body, coverage. The cheapest first call for a broad question. |
| `list_available_types` | Every HealthKit type with data: unit, row counts, earliest/latest, plus today's date and the time zone. The natural first call for anything specific. |
| `get_profile` | Name, email, date of birth, age, biological sex. |
| `get_latest_metrics(types)` | Newest raw sample per quantity type. |
| `get_daily_metrics(types, start_date, end_date)` | One deduplicated value per local day: sums for cumulative types, averages for discrete ones. |
| `get_activity_rings(start_date, end_date)` | Move / Exercise / Stand values and goals per day. |
| `list_workouts(start_date?, end_date?, activity_type?, limit?, offset?)` | Workout summaries, newest first. |
| `get_workout(uuid)` | Per-type statistics, events, and multi-sport parts of one workout. |
| `get_workout_series(uuid, types?, max_points?)` | The second-by-second streams inside one workout, downsampled. |
| `get_sleep(start_date, end_date)` | One row per night — asleep, in bed and stage minutes — dated by the day of waking. |
| `get_samples(type, start_date, end_date, limit?, offset?)` | Individual records of one type, raw and undeduplicated. At most 31 days. |
| `get_state_of_mind(start_date, end_date)` | Logged moods: valence, classification, labels, associations. |

Resources: `pulshealth://guide` (the embedded [`guide.md`](guide.md), written
for the model: data model, units, the iPhone + Watch double-counting rule,
question→tool recipes) and `pulshealth://types` (the live catalog). Prompts:
`weekly_summary` and `compare_workouts`.

Every tool but `list_users` takes an optional `user` — a `user_id` from
`list_users` — and passes it to the product API as `user=`; omitted, the API
answers for its own `PULS_USER_ID`. Naming anyone else needs the API's
`PULS_MULTI_USER` on; otherwise the API's 403 reaches the model as a tool
error. Per-user answers carry `user_id` whenever a user was named or the
instance is pinned. Every tool is annotated read-only and idempotent.
`get_summary` is the one tool whose answer is markdown rather than JSON: the
product API renders the page and the tool passes it on verbatim.

Tool inputs and outputs use `YYYY-MM-DD` calendar days and ISO 8601 instants
in the server's time zone. The server translates them to the product API's
epoch-millisecond, half-open ranges: an inclusive `start_date`…`end_date`
becomes `[start of start_date, start of the day after end_date)` in that
zone, DST included. API errors surface as tool errors carrying the HTTP
status.

## Running it

Two modes, one binary:

```bash
# stdio (default): for Claude Desktop, Claude Code, Cursor, ...
PULS_API_URL=https://<api-host>:8444 PULS_API_TOKEN=... PULS_TIME_ZONE=Europe/Berlin ./pulshealth-mcp

# streamable HTTP at /mcp, for remote connectors; refuses to start without PULS_MCP_TOKEN
PULS_API_URL=http://127.0.0.1:8081 PULS_API_TOKEN=... PULS_MCP_TOKEN=... ./pulshealth-mcp --http 127.0.0.1:8082
```

Build it from a checkout (`go build -o pulshealth-mcp ./server/mcp`) or
install the latest commit on `main` with `go install
github.com/PulsHealth/pulshealth/server/mcp@latest` (the binary is then
named `mcp` in `$(go env GOPATH)/bin`; rename it if you like). Go 1.26 or
newer. `--version` prints the build.

The Compose stack runs it as the `mcp` service on `127.0.0.1:8082` in HTTP
mode, pointed at `http://api:8081` over the internal network.

### Environment

| Variable | Meaning |
|---|---|
| `PULS_API_URL` | Base URL of the product API. Default `http://127.0.0.1:8081`; Compose sets `http://api:8081`. |
| `PULS_API_TOKEN` | The product API's bearer token (`PULS_API_TOKEN` in `server/.env`). Required. |
| `PULS_MCP_TOKEN` | The bearer token MCP clients must present to `/mcp` in `--http` mode. Required in that mode; ignored in stdio mode. |
| `PULS_TIME_ZONE` | IANA zone every date is expressed in. Must equal the stack's `PULS_TIME_ZONE` — the product API does not report its zone, so this is how the two agree. Default `UTC`. |
| `PULS_USER_ID` | Optional. Pins this instance to one person: every API request names that user, and a tool call naming anyone else is refused without asking the API. Empty (the default) leaves the choice to each call, falling back to the API's own default user. Compose sets it from `PULS_MCP_USER_ID`. |

### HTTP endpoints (`--http`)

- `POST/GET/DELETE /mcp` — the streamable HTTP transport, behind
  `Authorization: Bearer $PULS_MCP_TOKEN`. Sessions idle for 30 minutes are
  dropped.
- `GET /healthz` — unauthenticated; `{"ok":true,"api":true}` when the
  product API's own `/healthz` (which pings its database) answers, else 503.

The SDK's DNS-rebinding guard (reject a loopback listener seeing a
non-loopback `Host`) is switched off on purpose: a TLS reverse proxy on the
same host — Tailscale Serve, Caddy, nginx — forwards exactly that shape to
`127.0.0.1:8082`, and the bearer token, which a rebinding page cannot
present, is the access control.

## Security notes

- **The tokens grant read access to health data**, including name, email
  and date of birth from the profile. `PULS_API_TOKEN` and `PULS_MCP_TOKEN`
  are separate secrets so the MCP-facing one can be rotated without touching
  other API consumers; generate each with `openssl rand -hex 32`.
- **Never expose `--http` mode without TLS and the token.** The compose
  service binds to loopback; publish it only through an HTTPS-terminating
  proxy (`tailscale serve --bg --https=8445 http://localhost:8082`, or your
  reverse proxy). Plain HTTP puts the token on the wire.
- In stdio mode the client launches the binary; the token lives in the
  client's config file. Treat that file like `.env`.
- The server is read-only by construction: there is no code path that
  issues anything but `GET` to the product API, and no database credential
  is ever present.
- stdout is the stdio transport; all logging goes to stderr as JSON.

## Development

```bash
cd server/mcp
go vet ./... && go test -race ./...
go build -o pulshealth-mcp . && PULS_API_TOKEN=x ./pulshealth-mcp --version
```

Tests run against an `httptest` fake of the product API built from the
OpenAPI shapes in `server/api/docs.go` (date mapping across DST, error
propagation, limits) plus an end-to-end pass over the SDK's in-memory
transport and the HTTP transport with the token. This module deliberately
takes one dependency beyond the standard library, the official
`github.com/modelcontextprotocol/go-sdk`.

When the product API's shapes change (`server/api/docs.go`), update
`api.go`, the tool descriptions in `tools.go`, and `guide.md` in the same
change. Where the API pages, the client either passes the page through
(`list_workouts`, `get_samples` expose `limit`/`offset`) or follows it to
the end itself: `get_daily_metrics` walks `/v1/metrics/daily`'s
`nextOffset` (`APIClient.DailyMetrics`, page size `dailyPageSize`) and
returns the whole range as one answer, merging a metric split across two
pages.
