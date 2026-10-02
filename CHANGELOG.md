# Changelog

What changed in each release of the **server stack** — the four images
`ghcr.io/pulshealth/{ingest,api,mcp,web}`, which share one version that
`PULS_VERSION` in `.env` selects. Upgrading is: bump it, bring the checkout
to the same release (`git pull`, or `git checkout vX.Y.Z` — the compose file
and the schema migrations come from it, not from the images), then
`make pull up`.

Two things are versioned separately and are not in this file:

- **The iOS app**, which ships on its own schedule through the App Store. Its
  record is [`docs/appstore/README.md`](docs/appstore/README.md) § Release
  record.
- **The Puls Sync Protocol**, whose `schemaVersion` (and `X-Puls-Protocol`
  header) moves only for a change a v1 receiver would reject. A server release
  that adds an optional field or a new read endpoint keeps the protocol number
  where it is; [`docs/protocol/README.md`](docs/protocol/README.md) is the
  contract.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases are [semver](https://semver.org/spec/v2.0.0.html) over the stack:
a major for a change that needs operator action (a breaking config or schema
change), a minor for features, a patch for fixes. While the stack is on 0.x
that promise is weaker by convention — a minor may carry a change that needs
operator action, and when it does this file says so at the top of the entry.

## Unreleased

No operator action is required, but there is a schema migration: take
`make backup` before upgrading, as for any. `015_web_accounts.sql` adds two
schemas (`auth`, `web`), two functions and a set of views, and alters no
existing table, so Grafana, the product API and ingest read and write exactly
as before. `ingest` gains a subcommand and one Go dependency; `web` gains an
opt-in accounts mode. Nothing new is required in `.env`; `WEB_DB_PASSWORD`
(which `scripts/bootstrap.sh` now generates) creates the `web_app` role that
accounts mode connects as.

### Added

- **Accounts mode for the web viewer** (`WEB_ACCOUNTS=true`): invite-only
  accounts (`make web-invite`), each person signing in with their own email
  and password and seeing only their own records. The database enforces it:
  the viewer connects as the new `web_app` role, which reads health data
  only through per-user security-barrier views (schema `web`), filtered on
  the user that every health query's transaction now sets. Sessions in a
  `__Host-` cookie with only a hash stored, scrypt passwords, an `Origin`
  check on every state change, failed sign-ins throttled like ingest's, an
  account page to change the password and sign browsers out, and plain HTTP
  refused. Needs HTTPS in front, `WEB_DATABASE_URL` and
  `TRUST_PROXY_HEADERS=true`; see `web/README.md`, "Access control". Basic
  and open mode are unchanged.
- An optional `tunnel` Compose profile: a Cloudflare Tunnel that serves the
  viewer on a domain of yours with no open port (`CLOUDFLARE_TUNNEL_TOKEN`,
  `COMPOSE_PROFILES=tunnel`); `server/README.md`, "Exposing the server".
- Every viewer response, in every mode, carries a Content-Security-Policy with
  a per-request script nonce, and HSTS, `Referrer-Policy: same-origin`,
  `X-Content-Type-Options`, `X-Frame-Options: DENY` and a
  `Permissions-Policy`; pages are `noindex`.

- **Every pairing path ends in a QR code, and none needs `qrencode`.**
  `ingest qr` renders a terminal QR code in pure Go from a payload on stdin
  (never argv — the payload carries the token). `scripts/bootstrap.sh` falls
  back to it through the running ingest container when the host has no
  `qrencode`, and still never fails a bootstrap over a QR code.
- `devices issue` prints the Server URL, the pairing QR code and the
  `puls://pair?…` payload for the token it minted, where it used to print a
  token and a user ID and nothing to scan. The URL comes from the new `--url`,
  else from `PULS_PUBLIC_URL`, which Compose now passes to the ingest service;
  a URL the app would refuse stops the command before a token is minted.
  `--no-qr` prints the text alone.
- `scripts/bootstrap.sh --issue-device <label> [--user <uuid>] [--url <URL>]`,
  wrapped as `make issue-device NAME='My iPhone'`: one command that mints a
  per-device token, derives the URL by the pairing block's own rules (`--lan`
  included) and ends in a scannable code. `--print-url` prints just that URL.
- One new Go module in `server/ingest`: `github.com/skip2/go-qrcode` (stdlib
  only). The other three images and both CLIs are unchanged.

### Changed

- With the shared token disabled (`PULS_ALLOW_SHARED_TOKEN=false`, or an empty
  `PULS_TOKEN`) the pairing block names the `--issue-device` command to run
  instead of printing no code at all.
- The host `qrencode` call gets its payload on stdin too, so the token no
  longer appears in the process list while the code is drawn.

### Fixed

- `make devices ARGS='issue --name "My iPhone"'` no longer dies in `test` on
  the quoted label.
- `make restore` drops the viewer's `auth` and `web` schemas along with
  `public`: left in place, `pg_restore` stopped at `schema "auth" already
  exists` with `public` already gone.
- The viewer's return-path check refuses control characters and backslashes.
  Browsers strip tabs and newlines from a URL, so the user switcher's `next`
  field could be pointed off-site as `/<tab>/example.com`.

## [0.2.0] - 2026-09-18

**Upgrading:** move the checkout to `v0.2.0` (`git pull`, or
`git checkout v0.2.0`), set `PULS_VERSION=0.2.0` (or track `latest`), then
`make pull up`; `migrate` applies `014_device_tokens.sql` and re-runs
`099_read_roles.sh`. No `.env` changes are required — the shared
`PULS_TOKEN` keeps working exactly as before, and `PULS_MULTI_USER` defaults
to off. The checkout step is not optional: 0.2.0's ingest records
`device_token_id` on every batch, a column only `014` adds, so the new
images on a 0.1.0 checkout answer every upload with a 500 (the app keeps its
anchors and retries, so nothing is lost, but nothing syncs either).

### Added

- **Per-device tokens** (`make devices ARGS='issue --user <uuid> --name
  <label>'`, `list`, `rename`, `revoke`; SRV-8). Each is stored only as its
  SHA-256, bound to one user, revocable on its own and stamped with its last
  use. A request that presents one acts as that user: `X-User-ID` may be
  absent or equal, anything else is **403** before the body is read. Every
  `batches` row now records which device wrote it (`device_token_id`, NULL
  for the shared token) and the per-batch log line carries `token_id`.
  Migration `014_device_tokens.sql`.
- **Per-request user scoping on the product API** (SRV-11, the API side;
  the web viewer's switcher and the MCP server's `user` argument below
  ride on it). Every
  `/v1` route takes an optional `user=<uuid>` query parameter; absent, the
  request is answered for `PULS_USER_ID` exactly as before. `GET /v1/users`
  lists the users the deployment answers for — name, e-mail, `createdAt`,
  `lastSync`, `batches`, `uploadedSamples` from the `batches` log — plus
  `default` and `multiUser`. `/openapi.json` describes the parameter on
  every scoped operation.
- `PULS_MULTI_USER` (`.env`, default `false`) decides whether `user=` may
  name anyone but the default. **Off, another user is 403 `multi-user reads
  are disabled`**, never a quiet answer for the default user; a value that
  is not a UUID is 400; neither charges the auth-failure limiter. Turning it
  on means the one static `PULS_API_TOKEN` — the token `docs/ai.md` says to
  hand to a ChatGPT Action — reads every user on the server, so it stays
  off until you want that.
- `puls-export --user <uuid>` (default `$PULS_USER_ID`, else none) picks
  whose data to export, and a 403 is explained the way a 401 is.
- web: a user switcher when the database holds more than one user;
  `?user=<uuid>` picks one (SRV-11).
- MCP: `list_users`, and a `user` argument on every tool; `PULS_USER_ID`
  pins an instance to one person (`PULS_MCP_USER_ID` for the Compose
  service). Needs the product API's `user` parameter and `/v1/users` (SRV-11).
- `GET /v1/summary?range=7d|14d|30d|90d` on the product API: the last N
  calendar days as one short markdown page (activity, heart, sleep,
  workouts, body, coverage) for pasting into a chat that has no MCP
  connection; `format=json` for the numbers. The MCP server exposes it as
  `get_summary` (AI-6).

### Changed

- `PULS_TOKEN` is optional. `PULS_ALLOW_SHARED_TOKEN` (default `true`) turns
  the shared token off once every phone has its own; empty `PULS_TOKEN` does
  the same. Ingest logs its auth mode at startup and warns when nothing at
  all could authenticate. `scripts/bootstrap.sh` and `make pairing` accept
  that mode instead of dying on an empty token.
- A device-token lookup that fails because the database is unreachable is
  **503 `authentication unavailable`**, never 401, and is not charged to the
  auth-failure limiter; neither is a 403 user mismatch.
- The `grafana` role loses SELECT on `device_tokens` (revoked by
  `099_read_roles.sh` on every run).
- The `api_reader` role gains SELECT on `batches` (for `/v1/users`; the
  table holds no credential). No operator action: `099_read_roles.sh`
  re-runs on the next `docker compose up -d`.
- web: Next.js 16.3.5 (from 16.3.4).

## [0.1.0] - 2026-09-14

The first tagged release, and the one that first publishes
`ghcr.io/pulshealth/{ingest,api,mcp,web}` — before it, a compose install had
nothing to pull and had to build from the checkout. Everything below shipped
together; there is no earlier release to diff against.

### Added

- **The Puls Sync Protocol, v1.** One gzipped NDJSON `POST` plus optional read
  endpoints, specified in `docs/protocol/` with JSON Schemas, a fixture corpus
  with expected outcomes, an offline schema checker (`tools/protocol-check`)
  and a Python reference receiver. The receiver's smoke test doubles as a
  conformance runner against any implementation:
  `smoke_test.py --url <url> --token <token>`.
- **The reference backend.** Go ingest and product API over PostgreSQL 17 /
  TimescaleDB, with Grafana dashboards for the data and for ingest health.
  Ingest is idempotent per sample UUID, upserts aggregates and activity rings,
  and connects as a scoped DML-only role rather than the superuser.
- **Schema migrations that apply themselves.** The `migrate` service runs
  before every app service on `docker compose up -d`, records each file in
  `schema_migrations` with a checksum, refuses an edited or missing applied
  file, and requires an explicit `baseline` for a database that predates it.
- **A one-command quickstart.** `scripts/bootstrap.sh` generates the secrets,
  starts the stack and prints the pairing QR; `make` wraps the rest. `--lan`
  trades TLS for a phone on the same Wi-Fi, on request only.
- **Read-only MCP server** (`server/mcp`), 11 tools over the product API in
  stdio and streamable-HTTP modes, so Claude Desktop, Claude Code, Cursor and
  ChatGPT can answer questions from the data. It never touches Postgres.
- **Export.** `GET /v1/export` streams CSV or JSONL; `tools/puls-export` is a
  dependency-free CLI over it.
- **Product API endpoints an analyst asks for first:** daily sleep, bounded raw
  samples, workout series, state of mind, activity rings, daily metrics that
  resolve the iPhone/Watch double-count.
- **One type vocabulary.** `docs/protocol/catalog.json` is rendered from the
  Swift `HealthTypeCatalog`, and the web catalog is generated from the JSON, so
  the two published lists cannot drift.
- **Self-hosting safety rails.** Auth-failure rate limiting on both ingest and
  the product API (failed attempts only, never successful ones), a `/healthz`
  on each that answers from a two-second cache rather than the pool, an
  optional password on the web viewer, loopback binds by default, and an
  opt-in backup service with a documented restore drill.
- **Open-source hygiene.** Apache-2.0 with `NOTICE` and `TRADEMARK.md`,
  `SECURITY.md`, `CONTRIBUTING.md` with DCO sign-off, a code of conduct, issue
  and PR templates, `AGENTS.md`, `llms.txt`, and a CI gate that fails on
  owner-specific content in tracked files.
