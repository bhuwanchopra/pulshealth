# Use PulsHealth with AI assistants

PulsHealth ships an [MCP](https://modelcontextprotocol.io) server
(`server/mcp/`) so that Claude Desktop, Claude Code, Cursor, and any other
MCP client can answer questions from your Apple Health data — "how many
steps did I average last week", "compare my runs this month to last month",
"did I close my rings yesterday" — against the server you run. It is
read-only and talks only to the product API, never to the database. This
page is the client-side setup; the server's own README is
[`server/mcp/README.md`](../server/mcp/README.md).

For an assistant reading about the project rather than your data, the
repository's [`llms.txt`](../llms.txt) indexes the documentation, and
pulshealth.com serves it at <https://pulshealth.com/llms.txt>: the same file,
rendered at build time with its links pointed at the pages the site renders
under `/docs/` (the file on GitHub where there is none), so an assistant can
follow them from either copy. [`AGENTS.md`](../AGENTS.md) is the companion
for an assistant contributing to the code.

## What is available today

| Ask about | Tool the assistant uses |
|---|---|
| Who has data on the server, if more than one person does | `list_users` |
| Which data exists, how current it is, what day it is | `list_available_types` |
| How the last week or month went, in one page | `get_summary` |
| Who the data belongs to (name, age, sex) | `get_profile` |
| Current weight, resting heart rate, HRV, VO2 max, blood oxygen, ... | `get_latest_metrics` |
| Daily steps, energy, distance, exercise minutes, heart-rate averages, weight trend, ... | `get_daily_metrics` |
| Activity rings and goals per day | `get_activity_rings` |
| Workouts, filtered by date and activity | `list_workouts` |
| One workout's heart rate / power / pace statistics, laps, pauses | `get_workout` |
| The second-by-second curves inside one workout | `get_workout_series` |
| Sleep by night: time asleep, time in bed, stages | `get_sleep` |
| The individual records of one type, raw | `get_samples` |
| Logged moods and emotions | `get_state_of_mind` |

Daily values are the deduplicated ones (no iPhone + Watch double counting),
every value carries its unit, and dates are calendar days in your
`PULS_TIME_ZONE`. Sleep follows Apple Health: a night is dated by the day you
wake up, and where several devices recorded the same night nothing is summed
across them. `get_samples` is the one tool that returns undeduplicated
records — that is what makes it useful for looking at particular readings and
useless for totals. The assistant can also read `pulshealth://guide`, a short
manual on the data model and its traps, and two ready-made prompts
(`weekly_summary`, `compare_workouts`).

When several phones sync to one server, every tool takes an optional `user`
(a `user_id` from `list_users`); without it the assistant reads the API's
default person. The API only honours another user when its `PULS_MULTI_USER`
is on, and an MCP instance can be pinned to one person with `PULS_USER_ID`
(`PULS_MCP_USER_ID` for the Compose service) so that a connector you hand
to one household member can never be asked about another.

**Not yet:** GPS routes, medication doses, ECGs and heartbeat series. They
are in the database; no tool serves them.

For a whole range as a *file* rather than an answer in a chat — a spreadsheet,
a notebook, something to attach — use `GET /v1/export` or the `puls-export`
CLI instead of a tool call: [`export.md`](export.md).

## No MCP at all: paste a summary

Any chat can read markdown. `GET /v1/summary` renders the last 7, 14, 30 or
90 days as one page of under sixty lines — activity, heart, sleep, workouts,
body and a coverage line, every figure with its unit and already
deduplicated across iPhone and Watch — so a chat with no connector at all
gets a usable picture from one `curl` and a paste:

```bash
curl -H "Authorization: Bearer $PULS_API_TOKEN" "$API/v1/summary?range=7d"
```

`range` is `7d` (the default), `14d`, `30d` or `90d`; `format=json` returns
the same numbers as a `Summary` object. The page carries averages and totals
only, and the header says which calendar days and which time zone it covers,
so the model does not have to guess either. Add `user=<uuid>` on a shared
server, under the same `PULS_MULTI_USER` rule as every other route. The MCP
server exposes the same page as `get_summary`, and
[`notebooks/healthkit_database_exploration.ipynb`](../notebooks/healthkit_database_exploration.ipynb)
renders it straight from the database at the end of its analyses, with an
optional cell that sends it to Claude.

## Two ways to connect

1. **Local binary (stdio).** The assistant launches `pulshealth-mcp` on
   your machine; it needs to reach the product API. Simplest when the API
   is published on your tailnet
   (`tailscale serve --bg --https=8444 http://localhost:8081` on the server,
   as in `server/README.md`) or through an SSH tunnel
   (`ssh -N -L 8081:127.0.0.1:8081 <user>@<host>`, then
   `PULS_API_URL=http://127.0.0.1:8081`).
2. **Remote connector (streamable HTTP).** The Compose stack's `mcp`
   service serves `/mcp` on `127.0.0.1:8082`; publish it over HTTPS and any
   client that can send a bearer header connects to it. No binary on the
   client side.

### Get the binary

```bash
# from a checkout
go build -o pulshealth-mcp ./server/mcp && sudo mv pulshealth-mcp /usr/local/bin/

# or the latest commit on main (the binary lands as $(go env GOPATH)/bin/mcp)
go install github.com/PulsHealth/pulshealth/server/mcp@latest
```

Go 1.26 or newer. Check it with `PULS_API_TOKEN=x pulshealth-mcp --version`.

Every stdio snippet below uses the same three variables: `PULS_API_URL`
(the product API), `PULS_API_TOKEN` (from `server/.env`) and
`PULS_TIME_ZONE` (the same value the stack runs with — the API does not
report its zone, so the server has to be told; it defaults to UTC).

### Claude Desktop

Edit `claude_desktop_config.json` (macOS:
`~/Library/Application Support/Claude/claude_desktop_config.json`; Windows:
`%APPDATA%\Claude\claude_desktop_config.json`), then restart Claude Desktop:

```json
{
  "mcpServers": {
    "pulshealth": {
      "command": "/usr/local/bin/pulshealth-mcp",
      "env": {
        "PULS_API_URL": "https://<machine>.<tailnet>.ts.net:8444",
        "PULS_API_TOKEN": "<PULS_API_TOKEN from server/.env>",
        "PULS_TIME_ZONE": "Europe/Berlin"
      }
    }
  }
}
```

The tools appear under the connector icon in the chat box; ask something and
approve the first tool call.

### Claude Code

Stdio, available in every project (`-s user`):

```bash
claude mcp add pulshealth -s user \
  -e PULS_API_URL=https://<machine>.<tailnet>.ts.net:8444 \
  -e PULS_API_TOKEN=<PULS_API_TOKEN from server/.env> \
  -e PULS_TIME_ZONE=Europe/Berlin \
  -- /usr/local/bin/pulshealth-mcp
```

Or the remote connector, with the MCP token as a header:

```bash
claude mcp add --transport http pulshealth https://<machine>.<tailnet>.ts.net:8445/mcp \
  --header "Authorization: Bearer <PULS_MCP_TOKEN from server/.env>"
```

`claude mcp list` shows the connection; `/mcp` inside a session shows the
tools. Try `/mcp__pulshealth__weekly_summary` for the built-in prompt.

### Cursor

`~/.cursor/mcp.json` (global) or `.cursor/mcp.json` in a project:

```json
{
  "mcpServers": {
    "pulshealth": {
      "command": "/usr/local/bin/pulshealth-mcp",
      "env": {
        "PULS_API_URL": "https://<machine>.<tailnet>.ts.net:8444",
        "PULS_API_TOKEN": "<PULS_API_TOKEN from server/.env>",
        "PULS_TIME_ZONE": "Europe/Berlin"
      }
    }
  }
}
```

Remote instead:

```json
{
  "mcpServers": {
    "pulshealth": {
      "url": "https://<machine>.<tailnet>.ts.net:8445/mcp",
      "headers": { "Authorization": "Bearer <PULS_MCP_TOKEN from server/.env>" }
    }
  }
}
```

### Remote connector: the Compose service over HTTPS

On the server:

```bash
cd server
openssl rand -hex 32            # → PULS_MCP_TOKEN in .env (scripts/bootstrap.sh generates it)
docker compose up -d mcp        # pulls ghcr.io/pulshealth/mcp; `make dev-up` builds it from the checkout
curl -s localhost:8082/healthz  # → {"api":true,"ok":true}
```

The service binds to loopback and depends on `api`. Publish it the same way
as the product API and Grafana — through a TLS-terminating proxy, never
directly:

```bash
tailscale serve --bg --https=8445 http://localhost:8082
```

The endpoint is then `https://<machine>.<tailnet>.ts.net:8445/mcp` with
`Authorization: Bearer $PULS_MCP_TOKEN`. Any reverse proxy that terminates
TLS works the same (Caddy, nginx, a cloud tunnel); keep `/healthz` reachable
for monitoring if you like, it needs no token.

Clients that take a static bearer header — Claude Code, Cursor, the MCP
Inspector, your own code — connect as shown above. The hosted connector
screens in claude.ai and ChatGPT expect an OAuth flow rather than a pasted
token; until the server speaks OAuth (or you front it with an OAuth-capable
proxy), use one of the clients above, or the stdio binary.

Quick check from a shell:

```bash
curl -s -X POST https://<machine>.<tailnet>.ts.net:8445/mcp \
  -H "Authorization: Bearer $PULS_MCP_TOKEN" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

A `401` means the token; a `503` from `/healthz` means the product API (or
its database) is down.

## ChatGPT: the product API as a custom GPT Action

ChatGPT does not speak to the MCP server with a pasted bearer token. What it
does take is an **Action**: an OpenAPI document plus a credential, from which
it calls the HTTP API itself. The product API already publishes the document.
Read the caveats first: this route works differently from everything above.

**OpenAI's servers, not your browser, fetch the document and call the
endpoints.** A tailnet-only URL (`https://<machine>.<tailnet>.ts.net:8444`),
a loopback address or an SSH tunnel **will not work**: import fails, and even
if it did not, every call would. The API has to be reachable from the public
internet for as long as the Action is in use.

### 1. Publish the API on a public HTTPS URL

Any TLS-terminating tunnel or proxy does: `tailscale funnel --bg --https=443
http://localhost:8081`, a Cloudflare Tunnel, or a reverse proxy on a VPS.
Treat this as a temporary window — see the caveats.

```bash
curl -s https://health.example.net/healthz                     # {"ok":true,"db":true}
curl -s https://health.example.net/openapi.json | python3 -m json.tool >/dev/null && echo "schema ok"
```

The document fills its `servers[0].url` in from the request it arrived on
(honouring `X-Forwarded-Host` / `X-Forwarded-Proto`), so **fetch it through
the public URL** — a copy pulled from `127.0.0.1` names the loopback address
and the Action will call the wrong host.

### 2. Import it

In ChatGPT: **Create a GPT → Configure → Create new action → Import from
URL**, and give it `https://health.example.net/openapi.json`. (Pasting the
JSON works too.) Every endpoint arrives with an `operationId` the model calls
by name — `getDailyMetrics`, `getSleepNights`, `listWorkouts`,
`exportDataset` and so on.

### 3. Configure the token

**Authentication → API Key → Auth Type: Bearer**, and paste the value of
`PULS_API_TOKEN` from `server/.env`. That single token is the whole trust
boundary; `/`, `/docs`, `/openapi.json` and `/healthz` stay open, everything
under `/v1/` needs it.

ChatGPT asks for a privacy policy URL for the Action before it will let you
share the GPT with anyone else. Don't — see the caveats.

### 4. Check it

Ask *"what health data do you have about me, and how current is it?"* — that
is one `listCatalogTypes` call, which lists every type with the row count and
the timestamps of its oldest and newest record. Approve the first call when
ChatGPT asks. (Unlike the MCP tool of the same shape, the raw endpoint does
*not* report the server's current date: `latest` is the newest **data**, so an
assistant that reads it as "today" is wrong by however far sync has lagged.)

### Caveats

- **Keep the GPT private.** The API key is stored with the Action, so anyone
  who can use the GPT can read your health data — including your name, email
  and date of birth from `/v1/profile`. Do not share or publish it.
- **Rotate the token afterwards.** It has been handed to a third party and
  travelled over a public endpoint. When you are done: generate a new one
  (`openssl rand -hex 32`), set `PULS_API_TOKEN` in `server/.env`,
  `docker compose up -d api mcp`, and update your other clients. Take the
  public endpoint down at the same time (`tailscale funnel --https=443 off`).
- **A public endpoint is a public endpoint.** The product API throttles
  failed token guesses per client IP (`server/README.md`, "Rate limiting")
  and nothing else: no IP allowlist, no limit on requests that carry the
  right token. The token is all that stands between the internet and the
  data. Keep the window short.
- **Actions time out (tens of seconds) and truncate large answers.** Ask for
  narrow ranges. `exportDataset` streams a CSV or JSONL *file*, which is
  exactly the wrong shape for a chat turn — use the JSON endpoints for
  questions and the `puls-export` CLI for files ([`export.md`](export.md)).
- **Dates are epoch milliseconds** and the API does not report its zone, so
  tell the GPT which zone the server runs in (`PULS_TIME_ZONE`) in its
  instructions, or it will guess.
- **The Action can name a user.** Every `/v1/*` operation takes an optional
  `user` query parameter and `listUsers` names everyone with data, so a GPT
  built on a shared server can read another household member's records if
  the API's `PULS_MULTI_USER` is on — one more reason to keep the GPT
  private. Leave `PULS_MULTI_USER` off unless you mean it.
- The MCP server remains the better route wherever the client supports it:
  it speaks calendar days, keeps the model honest about units and
  double counting, and never needs a public endpoint.

## Try these

- **"What data do you have about me, and how current is it?"** — one
  `list_available_types` call; a good first question, it also tells the
  assistant today's date.
- **"How have I been doing this month?"** — one `get_summary` call with
  `range: 30d`; the same page `GET /v1/summary` serves, so it is also the
  thing to paste into a chat that has no connector.
- **"How did I sleep last week?"** — one `get_sleep` call for the seven
  days; each row is a night, dated by the morning you woke up, with time
  asleep, time in bed and the core / deep / REM split in minutes. The
  `weekly_summary` prompt includes it.
- **"When exactly did my heart rate spike during yesterday's meeting?"** —
  `get_samples` with `HKQuantityTypeIdentifierHeartRate` for that day; the
  individual readings, not a daily average.
- **"Show me how my heart rate moved through Saturday's run."** —
  `list_workouts` for the day, then `get_workout_series` with the uuid.
- **"Compare my runs this month to last month."** — two `list_workouts`
  calls with `activity_type: running`, then totals, averages and pace;
  `get_workout` on a few for heart rate. The `compare_workouts` prompt does
  exactly this.
- **"Did I close my rings yesterday?"** — `get_activity_rings` for one day;
  closed means value ≥ goal.
- **"What's my resting heart rate trend over the last 90 days?"** —
  `get_daily_metrics` with `HKQuantityTypeIdentifierRestingHeartRate` and
  `HKQuantityTypeIdentifierHeartRateVariabilitySDNN`.
- **"How much did I weigh at the start of the year versus now?"** —
  `get_latest_metrics` for now, `get_daily_metrics` for January.

## How the server keeps the model honest

- **Units travel with every value** (`count/min`, `kg`, `m`, `kcal`, ...),
  and the descriptions warn that `%` is a fraction (blood oxygen 0.97).
- **Days, not milliseconds.** The API speaks epoch milliseconds and
  half-open ranges; the tools speak `YYYY-MM-DD` in your time zone and map
  an inclusive range to exactly those days, DST included.
- **No double counting.** Daily values come from HealthKit's own daily
  aggregate when the phone synced one, otherwise from a single-source rollup;
  the guide tells the model never to total raw samples itself.
- **Cumulative versus discrete.** Steps are daily sums; heart rate is a
  daily average; the latest raw sample of a cumulative type is an increment,
  not a total — spelled out in the tool descriptions.
- **Errors are readable.** A bad date, an unknown workout, a rejected token
  or an unreachable API come back as tool errors with the reason and the
  HTTP status, so the assistant can explain instead of guessing.

## Security

- **The tokens grant read access to your health data**, including the
  profile (name, email, date of birth). `PULS_API_TOKEN` (used by the stdio
  binary) and `PULS_MCP_TOKEN` (presented by remote clients) are separate
  secrets; rotate either without touching the other.
- **Client config files hold the token.** `claude_desktop_config.json`,
  `.cursor/mcp.json` and Claude Code's settings are as sensitive as
  `server/.env`; keep them out of version control.
- **HTTP mode only behind TLS.** The compose service binds to loopback;
  never publish port 8082 directly or over plain HTTP. See the security
  notes in `server/mcp/README.md`.
- With the API's `PULS_MULTI_USER` off (the default) the assistant sees one
  person only. With it on, pin each connector to its person (`PULS_USER_ID`;
  see the multi-user note above). Nothing here can write to the database or
  to Apple Health.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| The tool returns `product API returned 401 ...` | `PULS_API_TOKEN` given to the MCP server differs from the API's. |
| `product API unreachable at ...` | Wrong `PULS_API_URL`, tunnel not up, or the API container is down (`docker compose ps`). |
| `PULS_MCP_TOKEN must be set to serve --http` at startup | HTTP mode refuses to run without its token — set it in `.env`. |
| Daily figures are off by a day, or a day splits in two | `PULS_TIME_ZONE` on the MCP server does not match the stack's. |
| Client shows the server as failed to start | Run it by hand with the same env: errors go to stderr as JSON. `pulshealth-mcp --version` checks the binary. |
