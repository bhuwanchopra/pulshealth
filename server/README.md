# PulsHealth Server

Self-hosted ingestion stack for Apple HealthKit data exported by the
PulsHealth iOS app. Four published app images plus Grafana, PostgreSQL and a
one-shot schema migrator via Docker Compose:

| Service | Image | Port | Purpose |
|---|---|---|---|
| `db` | `timescale/timescaledb-ha:pg17.11-ts2.29.2` (pinned — see "Upgrading the database image") | 127.0.0.1:5432 | PostgreSQL 17 + TimescaleDB |
| `migrate` | same pinned image as `db` (one-shot) | — | Applies `db/migrations/` before the app services start (see "Schema migrations") |
| `ingest` | `ghcr.io/pulshealth/ingest:${PULS_VERSION:-latest}` (Go, distroless; `ingest/`) | `${INGEST_BIND_ADDR:-127.0.0.1}:8080` | HTTP ingest API the phone syncs to (see "Exposing the server"); connects as the DML-only `ingest` role |
| `api` | `ghcr.io/pulshealth/api:${PULS_VERSION:-latest}` (Go, distroless; `api/`) | 127.0.0.1:8081 | Product read API for downstream apps |
| `mcp` | `ghcr.io/pulshealth/mcp:${PULS_VERSION:-latest}` (Go, distroless; `mcp/`) | 127.0.0.1:8082 | Read-only MCP server for AI assistants over the product API (`docs/ai.md`) |
| `grafana` | `grafana/grafana:13.0.2` (pinned — 13.x provisioning is version-sensitive) | 127.0.0.1:3000 | Dashboards (reach them through a TLS proxy, e.g. Tailscale Serve on `:8443`) |
| `web` | `ghcr.io/pulshealth/web:${PULS_VERSION:-latest}` (Next.js standalone; `../web/`) | `${WEB_BIND_ADDR:-127.0.0.1}:3001` | Web health viewer — reads the DB directly as the read-only `grafana` role |

The four app images are pulled from `ghcr.io/pulshealth`; the
`compose.build.yml` overlay builds them from the checkout instead (see
"Images and versions"). `web` builds from the sibling `../web/`, so that
needs a checkout with both `server/` and `web/`.

```
server/
├── docker-compose.yml    # the stack: pulls the published images
├── compose.build.yml     # developer overlay: build the app images from here
├── .env.example          # copy to .env, fill in secrets (scripts/bootstrap.sh does it)
├── api/                  # Go product read API + Dockerfile
├── ingest/               # Go ingest server + Dockerfile
├── mcp/                  # Go MCP server + Dockerfile
├── db/migrate.sh         # schema migrator, run by the `migrate` service
├── db/migrations/        # numbered schema files it applies, in order
├── grafana/              # provisioned datasource + dashboard
```

## Setup

The fast path is the bootstrap script at the repository root: it creates
`.env` with every secret generated, starts the stack, waits for ingest and
prints the pairing block for the app (URL, token, user ID and a QR code,
drawn by `qrencode` if the host has it and by the ingest container
otherwise). It is safe to re-run; `--print-pairing` (`make pairing`)
re-prints the block, and `--issue-device <label>` prints one for a
per-device token (see "Tokens").

```bash
scripts/bootstrap.sh --time-zone Europe/Berlin    # the root README's "Quickstart" has the rest
```

By hand, it is:

```bash
cd server
cp .env.example .env
# Generate secrets (run once per variable):
openssl rand -hex 32
# Edit .env: POSTGRES_PASSWORD, PULS_TOKEN, PULS_API_TOKEN, PULS_MCP_TOKEN,
# GRAFANA_PASSWORD, GRAFANA_DB_PASSWORD, API_DB_PASSWORD, INGEST_DB_PASSWORD —
# and PULS_TIME_ZONE (see "Configuration" below).

docker compose up -d                 # pulls the images; db → migrate (schema) → ingest, api, mcp, web, grafana
docker compose logs migrate          # one line per schema file: applied / skipped / rerun
curl -s localhost:8080/healthz       # → {"db":true,"ok":true}
curl -s localhost:8081/healthz       # → {"db":true,"ok":true}
```

The `migrate` service creates the schema on an empty volume and every app
service waits for it. The same command upgrades a running install later
(see "Deploying and upgrading"); `make dev-up` runs the checkout's code
instead of the published images (see "Images and versions").

### Configuration

Everything is read from `.env`; `.env.example` lists every variable with
comments. Beyond the passwords and tokens:

- **`PULS_TIME_ZONE`** — the IANA zone your phone lives in (e.g.
  `Europe/Berlin`); default `UTC`. Every daily view buckets by it
  (`metric_daily`, Grafana's daily panels, the product API, the web viewer),
  and it must match the phone: the daily aggregates HealthKit computes are
  already in the phone's calendar, and a mismatch splits days between two
  rows. On every start `db/migrations/013_time_zone.sh` validates it against
  `pg_timezone_names` (an unknown name stops the stack) and stores it with
  `ALTER DATABASE … SET puls.time_zone`, read by `puls_time_zone()`. Compose
  also hands it to `api` (which refuses an invalid name), `mcp` and `web`. To
  change it, edit `.env` and:

  ```bash
  docker compose up -d     # migrate re-stores it; api/mcp/web are recreated
  docker compose exec db psql -U postgres -d postgres -tAc "SELECT puls_time_zone()"
  ```

  The database setting applies to new connections only: ingest and Grafana
  pick it up as their pools reconnect (`docker compose restart ingest
  grafana` forces it). Stored rows are never rewritten; the daily views
  re-bucket on read.
- **`GRAFANA_ALERT_EMAIL`** — the recipient of every Grafana alert. Compose
  defaults it to `alerts@example.com` so the contact point always has an
  address; set your own. Mail is sent only once SMTP is configured (see
  "Alerting").
- `WEB_AUTH_PASSWORD` — the web viewer's HTTP Basic password (any username;
  `/api/healthz` stays open for health checks). Empty, the viewer has no
  login and says so in `docker compose logs web`. `scripts/bootstrap.sh`
  generates one on a fresh install and prints it. See `web/README.md`,
  "Access control".
- `WEB_BIND_ADDR` — where the viewer's port is published; default loopback.
  Basic auth is not TLS: to reach the viewer from other machines, bind it to
  a private interface (a VPN/tailnet address), never `0.0.0.0`.
- `INGEST_BIND_ADDR` — where ingest's port 8080 is published; default
  loopback, for a TLS proxy in front. `0.0.0.0` (what `scripts/bootstrap.sh
  --lan` writes) lets a phone on the same Wi-Fi sync to plain
  `http://<LAN IP>:8080`. See "Exposing the server".
- `PULS_ALLOW_SHARED_TOKEN` — whether ingest accepts the shared `PULS_TOKEN`;
  default `true`. `false` (or an empty `PULS_TOKEN`) leaves only per-device
  tokens. See "Tokens".
- `TRUST_PROXY_HEADERS` — whether ingest and the product API believe
  `X-Forwarded-*`: which client a failed authentication is charged to, and
  which host `GET /openapi.json` advertises in `servers[0].url`. Default
  `false`, which answers from the request's own `Host`. Turn it on only
  behind a proxy that owns those headers (see "Rate limiting").
- `PULS_USER_ID`, `PULS_MULTI_USER` — whose data the product API and viewer
  answer for, and whether a request may name someone else (see "Product
  API").
- `PULS_VERSION` — the image tag the four app services run (default
  `latest`; see "Images and versions").
- `PULS_PUBLIC_URL` — the URL the pairing block and device-token QR codes
  carry instead of the LAN address. Pairing only; the running server never
  reads it (see "Exposing the server").

## Deploying and upgrading

The reference stack is plain Docker Compose; there is no deploy tooling in the
repo. **Take a backup first** (`make backup` — see "Backup & restore"), then:

```bash
git pull                                         # newer compose file and migrations
cd server
# optional: pin the release in .env, e.g. PULS_VERSION=0.2.0 (default: latest)
docker compose pull && docker compose up -d      # or, at the repository root: make pull up
docker compose logs migrate                      # what the schema step did
curl -s localhost:8080/healthz && curl -s localhost:8081/healthz
```

`migrate` runs before `ingest`, `api`, `mcp`, `web` and `grafana` start, so
new schema files are applied before the code that needs them. If a migration
fails, the app services are not started (`dependency failed to start`) and
the previous containers keep running; fix the cause and `docker compose up
-d` again. Re-applying the schema from scratch means dropping the volume
(`docker compose down -v && docker compose up -d`), which **destroys all
data**.

### Images and versions

The four app services run images published from this repository:

| Service | Image | Reports its build as |
|---|---|---|
| `ingest` | `ghcr.io/pulshealth/ingest` | `version` in `GET /v1/capabilities` |
| `api` | `ghcr.io/pulshealth/api` | — |
| `mcp` | `ghcr.io/pulshealth/mcp` | `--version`, and `serverInfo` on MCP `initialize` |
| `web` | `ghcr.io/pulshealth/web` | — |

`.github/workflows/release.yml` builds all four for `linux/amd64` and
`linux/arm64` (one native runner per architecture, merged into one manifest
list); each image carries its commit as the
`org.opencontainers.image.revision` label. The tags:

- On a git tag `vX.Y.Z`: the exact version (`X.Y.Z`), a floating `X.Y`,
  and `latest` (`v0.2.0` → `0.2.0`, `0.2`, `latest`). `latest`
  and `X.Y` move only for non-prerelease tags, so `vX.Y.Z-rc1` publishes
  `X.Y.Z-rc1` alone.
- On a manual run (`workflow_dispatch`, e.g. to try a branch's images): the
  tag given as input, or the short commit SHA. Never `latest`.

`PULS_VERSION` in `.env` selects the tag (default `latest`). To upgrade a
pinned install, bump it, check out the same release (`git checkout
v<version>`) and `make pull up`. The checkout matters: the compose file and
`db/migrations/` (which `migrate` mounts) come from it, and an image newer
than its checkout meets a schema that lacks what it expects. Migrations are
forward-only — going back to an older image after a release that migrated
the schema is not supported. The database image is versioned separately
(see "Upgrading the database image").

To run what is in the checkout — a local change, or a branch under
review — add the developer overlay, which puts the `build:` blocks back and
tags the results `pulshealth-<service>:dev` so they never pass for a
published version:

```bash
cd server && docker compose -f docker-compose.yml -f compose.build.yml up -d --build
# or, at the repository root:
make dev-up                                      # sets DEPLOY_COMMIT from git
scripts/bootstrap.sh --build                     # the bootstrap flow, building instead of pulling
```

A plain `docker compose up -d` afterwards switches back to the
`ghcr.io/pulshealth` images. CI's `images` job builds all four for
`linux/amd64` on every pull request, so a broken Dockerfile fails there.

### Schema migrations

`db/migrate.sh`, run by the `migrate` Compose service (on the same pinned
image as `db`, so nothing is built), applies the files in `db/migrations/`
in lexical order and records each in a `schema_migrations` table
(`filename`, `applied_at`, `checksum`). It runs on every `docker compose up
-d`, or by hand with `docker compose run --rm migrate` (`make migrate`), and
logs one line per file — `applied`, `skipped`, `rerun` or `ran` — plus a
summary.

| File | Behaviour |
|---|---|
| `NNN_name.sql` | One-shot: applied once, in one transaction with its `schema_migrations` row (`psql --single-transaction`, `ON_ERROR_STOP`), so a failed file leaves nothing behind and is retried next run. Applied files are immutable: the migrator stops if a recorded file's checksum changed (put the change in a new file) or a recorded file is missing (never rename or delete one). |
| `-- puls:rerun` on the first line | Re-applied whenever its checksum changes. For `CREATE OR REPLACE`/upsert files edited in place: `009_metric_daily.sql` (the view and `puls_time_zone()`) and `010_category_labels.sql` (the label seed). |
| `-- puls:no-transaction` on the first line | Applied statement by statement, for a statement that cannot run in a transaction block (`008_quantity_rollups.sql`: `refresh_continuous_aggregate`). Must be idempotent: a mid-file failure is retried from the top. |
| `NNN_name.sh` | Run on every invocation, never recorded: `013_time_zone.sh` (stores `PULS_TIME_ZONE`) and `099_read_roles.sh` (creates the `grafana`, `api_reader` and `ingest` roles and sets their passwords from `GRAFANA_DB_PASSWORD`, `API_DB_PASSWORD` and `INGEST_DB_PASSWORD`; and, when `WEB_DB_PASSWORD` is set, `web_app`, the web viewer's accounts-mode role). |

**Adding a migration.** Create the next `NNN_name.sql` (three digits, an
underscore, a name) with plain DDL/DML — no `BEGIN`/`COMMIT`, the migrator
wraps it; `IF NOT EXISTS` is still welcome — and `docker compose up -d`.
Fresh and existing installs take the same path. New tables are readable by
`grafana` and writable by `ingest` at once through the default privileges
`099_read_roles.sh` sets (the script then revokes `grafana`'s SELECT on
`device_tokens` on every run — credential hashes are not dashboard
material). `api_reader` has an exact grant list instead: extend that script
and its assertion when the product API reads a new table. So does `web_app`,
the web viewer's role in accounts mode, which reads health data only through
the per-user, security-barrier views in schema `web`
(`015_web_accounts.sql`, filtered on the `puls.user_id` setting the viewer
puts in each transaction). The views are rebuilt on every run by
`puls_create_web_views()`, so a CASCADE or a column change heals itself on
the next `docker compose up -d`; a table the viewer newly reads needs a new
migration replacing that function, a `GRANT` and an expected row in the
script, whose assertion fails the run on any other relation in `web` and if
`web_app` could read any table with a `user_id` directly. (Views, not row-level security: TimescaleDB refuses
`ENABLE ROW LEVEL SECURITY` on a hypertable with columnstore enabled.) Because `migrate`
applies every pending file before `ingest` starts, a table `InsertBatch`
writes unconditionally is always there before the code that writes it.

**Existing databases (created before the migrate service): baseline once.**
A database that has the schema but no `schema_migrations` table stops the
migrator with exit 1 rather than have it guess which files it contains, and
the app services do not start. If every file in `db/migrations/` has
already been applied to it, record that:

```bash
git pull
# add INGEST_DB_PASSWORD=<openssl rand -hex 32> to .env (see "The scoped ingest role")
cd server
docker compose run --rm migrate baseline     # or `make baseline` at the root
docker compose up -d
```

`baseline` records every `*.sql` file as applied, with its checksum,
**without running any of them**, runs the `*.sh` files (so the `ingest` role
exists before ingest starts), and prints what it recorded. Re-runnable files
are recorded without a checksum, so the next `docker compose up -d` applies
`009_metric_daily.sql` and `010_category_labels.sql` once — safe, since both
are `CREATE OR REPLACE`/upsert. If a one-shot file has *not* been applied to
your database, apply it by hand first, then baseline:

```bash
docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < db/migrations/NNN_name.sql
```

A database created from the old floating `pg17` tag now runs under the
pinned, possibly newer TimescaleDB binary (the data volume is untouched):
read "Upgrading the database image" before or right after adopting it.

### Upgrading the database image

`docker-compose.yml` pins PostgreSQL + TimescaleDB to one exact tag
(`x-db-image`, shared by `db` and `migrate` so they cannot drift; currently
`timescale/timescaledb-ha:pg17.11-ts2.29.2`). A floating tag would move
TimescaleDB minor versions underneath a running install, and those change
its internal catalog, so bumping the tag is a deliberate step:

- **The image does not upgrade the extension by itself.** It ships every
  versioned `timescaledb-*.so` back to 2.17 and only runs `CREATE EXTENSION`
  on a brand-new volume, so an existing database keeps working on its old
  extension version. `migrate` prints a NOTE whenever the installed
  extension differs from the one the image ships.
- **Upgrade the extension yourself, deliberately** — after a `make backup`
  (extension updates are one-way), with no app service connected, as the
  first statement of a fresh session (`psql -X`):

  ```bash
  docker compose stop ingest api web grafana
  docker compose exec db psql -X -U postgres -d postgres -c "ALTER EXTENSION timescaledb UPDATE"
  docker compose up -d
  ```

  From 2.27 to 2.29 the update keeps existing compressed chunks, and their
  grants, under their old `compress_hyper_N_M_chunk` names alongside new
  `<chunk>_compressed` ones; `migrate` runs clean either side of it.
- Bump the tag in `docker-compose.yml` only: CI's `db-migrate` job and
  `tests/test_healthkit_notebook.py` read the image from there.

### The scoped `ingest` role

Ingest is the only internet-facing service, so it does not hold the
superuser password: Compose connects it as the `ingest` role
(`INGEST_DB_USER`, default `ingest`; `INGEST_DB_PASSWORD` is required),
which `099_read_roles.sh` creates on every migrate run with exactly what
`ingest/store.go` needs: `CONNECT`, `USAGE` on `public`,
`SELECT/INSERT/UPDATE/DELETE` on every table and view in `public`,
`USAGE/SELECT` on its sequences, and default privileges covering future
tables and sequences. It has no `CREATE` on the schema, no `TRUNCATE`, and
none of `SUPERUSER`, `CREATEROLE`, `CREATEDB`, `REPLICATION` or
`BYPASSRLS`, so an ingest bug or a leaked token cannot drop tables, alter
roles, or `COPY TO PROGRAM`. Before it commits, the script checks the exact
role attributes and ACL set, that the grants reach hypertable chunks, and
that the role may issue the `SET LOCAL
timescaledb.max_tuples_decompressed_per_dml_transaction` that `InsertBatch`
uses.

To run ingest as the superuser instead (not recommended), set
`INGEST_DB_USER=postgres` and `INGEST_DB_PASSWORD` to the value of
`POSTGRES_PASSWORD` in `.env`, then `docker compose up -d ingest`. Either
way, verify who is connected:

```bash
docker compose exec db psql -U postgres -d postgres -tAc \
  "SELECT DISTINCT usename FROM pg_stat_activity WHERE client_addr IS NOT NULL"
# → api_reader, grafana, ingest
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS -H "Authorization: Bearer $PULS_TOKEN" http://127.0.0.1:8080/v1/stats
```

`010_category_labels.sql` adds the `category_labels` lookup table for joining
raw `category_samples.value` integers to their HealthKit meanings:

```sql
SELECT c.*, cl.label, cl.enum_name
FROM category_samples c
JOIN sample_types st USING (type_id)
LEFT JOIN category_labels cl
  ON cl.type_identifier = st.identifier
 AND cl.value = c.value;
```

The seed comes from Xcode's HealthKit headers (`HKTypeIdentifiers.h` maps
each category type to its value enum, `HKCategoryValues.h` defines the
values). Refresh it after major SDK updates or when adding a category type;
`docker compose up -d` re-applies the edited `-- puls:rerun` file. Then
check the seed's shape:

```bash
docker compose exec db psql -U postgres -d postgres -tA \
  -c "SELECT count(*), count(DISTINCT type_identifier) FROM category_labels;"
# iPhoneOS 26.5 SDK seed: 257|70
```

`000_users.sql` adds the `users` table, which every data table's `user_id`
foreign key and the profile line reference, and seeds the default user.
Storing a second person's data therefore needs nothing: point another phone
at the same ingest URL with its own user ID and `ensureUser` creates the row
before the first insert. Reading it back is per request — the product API's
`?user=<uuid>`, gated by `PULS_MULTI_USER` (see "Product API"), which the
MCP server and the web viewer use too; Grafana's dashboard has a `user`
variable. Whether an ingest token is bound to a user depends on its kind
(see "Tokens").

### Tokens

Ingest accepts two kinds of bearer token, and a request may present either.

**The shared token.** `PULS_TOKEN` is one static value known to the server
and every phone, generated by `scripts/bootstrap.sh` (or `openssl rand -hex
32`) and shown in the pairing block (`make pairing`) next to the URL and
user ID. It is compared in memory, in constant time, and carries no user:
`X-User-ID` picks the user, so anyone holding it can write as anyone.

**Per-device tokens.** Each is issued from the CLI for one user, stored only
as its SHA-256 (the plaintext has the same shape as the shared token: 32
random bytes, hex-encoded), bound to that user, revocable on its own, and
stamped with when it was last used.

Pairing a phone with one is a single command. It prints the same block the
shared token gets — URL, token, user ID and a QR code, which the app scans
with Scan Pairing Code on its Database screen (**Sync → Set Up** before a
database is configured, **Sync → Database** after):

```bash
scripts/bootstrap.sh --issue-device "My iPhone"                  # the default user
scripts/bootstrap.sh --issue-device "Her iPhone" --user <uuid>   # someone else; a new UUID creates the user
#   (or: make issue-device NAME='My iPhone' ARGS='--user <uuid>')
#   The token is shown ONCE — only its hash is stored; a lost token is revoked and reissued.
```

The URL in the code is the pairing block's — `PULS_PUBLIC_URL`, else this
host's LAN address under `--lan`; with neither, the command says so and
issues nothing. `--url <URL>` sets one for that code alone. A URL the app
would refuse (plain `http://` beyond the local network) is rejected before
any token is minted. The stack must be running: `ingest devices issue`,
inside the ingest container, mints the token and draws the code.

The rest of the lifecycle is that CLI — the distroless `ingest` binary with
`devices` as its first argument, which `make devices` wraps (`docker compose
run --rm --no-deps ingest devices …`, handed the same URL):

```bash
make devices ARGS='issue --user 5ea4d000-0000-4000-8000-000000000001 --name "My iPhone"'
#   [--url <URL>] overrides the URL in the code; [--no-qr] prints the payload as text only
make devices ARGS='list'            # id, prefix, status, user, name, created, last seen
make devices ARGS='list --all'      # revoked ones too
make devices ARGS='rename 3 "Old phone"'
make devices ARGS='revoke 3'        # refused from the next request on; nothing to restart
```

Run directly with `docker compose run`, `issue` knows only `PULS_PUBLIC_URL`
or `--url` (a container cannot see the proxy in front of it or the host's
LAN address); with neither it prints the token and user ID without a code.
`ingest qr` draws a code on its own from a payload on stdin (never an
argument, which would show the token in `ps`); `scripts/bootstrap.sh` uses
it on a host without `qrencode`.

`issue` creates the `users` row if it does not exist, so a household member
can have a token before their phone has synced — and a mistyped `--user`
quietly creates a new user; check `list` after. A request with a device
token acts as that token's user: `X-User-ID` must be absent or equal to it,
or the request is refused with 403 before the body is read. The app sends
the user ID set on it (by the pairing code, or under Settings → User), so
that must match the token's.

**Order and failure modes.** The shared token is checked first, in memory;
only then is the presented value hashed and looked up in `device_tokens`
(one indexed probe, which also advances `last_seen_at` at most once a minute
per token). If the database cannot answer, the response is **503
`authentication unavailable`**, not 401: the app retries 5xx but treats 401
as terminal, so a 401 would stall syncing until the user retyped a token
that was never wrong. Only wrong credentials (a missing bearer, an unknown
value, a revoked token) draw from the failure budget (see "Rate limiting");
a user mismatch, a database error and every success cost nothing. Every
`batches` row records the device that wrote it (`device_token_id`, NULL for
the shared token), and the per-batch log line carries it as `token_id`.

**Turning the shared token off.** It is enabled by default. Once every phone
has its own token, set `PULS_ALLOW_SHARED_TOKEN=false` in `.env` (or empty
`PULS_TOKEN`) and `docker compose up -d ingest`: from then on no credential
can write as a user it was not issued for. `docker compose logs ingest`
prints the auth mode at startup and warns (never fails) when the shared
token is off and no device token is active. In that mode `make pairing` and
`scripts/bootstrap.sh` have no token to show (only hashes are stored), so
they print the `--issue-device` command instead.

### Rate limiting

**Ingest and the product API** both throttle **failed authentications** per
client IP: each address gets a token bucket of **10 failures**, refilling at
**10 per minute**. While the bucket has tokens a wrong token answers `401`;
once it is empty every attempt from that address answers

```
HTTP/1.1 429 Too Many Requests
Retry-After: 7

{"error":"too many failed authentications"}
```

and the server logs the address, the path and the wait. The product API also
logs every failed authentication (`auth failed`, with address and path, never
the token).

- **A correct token is never throttled.** Only failures draw from the bucket,
  so a backfill — thousands of authenticated uploads in a row — never
  touches it.
- **An exhausted address is refused *before* the token is compared.**
  Otherwise the limit would only change the status code an attacker sees,
  not their guessing rate. A client sharing an address with an attacker
  waits too; buckets refill in a minute.
- **Memory is bounded.** Only failures create an entry, entries refilled and
  idle for ten minutes are forgotten, and a cap of 10,000 addresses drops
  the least recently seen first, so rotating IPv6 addresses cannot grow it.

The limit is keyed on the TCP peer address. Behind a proxy every request
comes from the proxy, and one attacker exhausts the bucket for everyone;
**`TRUST_PROXY_HEADERS=true`** keys it on the first `X-Forwarded-For` entry
instead. Only set it when the proxy is the *only* route to the port and
overwrites the header (reverse proxies and Tailscale Serve/Funnel do);
otherwise the sender sets it, and one attacker looks like unlimited clients.
Leave it `false` for `INGEST_BIND_ADDR=0.0.0.0` on a LAN. If every throttled
client is logged as the same `172.x.x.1`, Docker's userland proxy is
rewriting the source address; the fix is the same — a proxy that sets
`X-Forwarded-For`, and `TRUST_PROXY_HEADERS` on.

The limit is no substitute for a good token: `openssl rand -hex 32` is 256
bits.

### Rotating secrets

`scripts/bootstrap.sh` never regenerates an existing `.env`: the app holds
`PULS_TOKEN` and the database volume holds `POSTGRES_PASSWORD`, so a fresh
set of secrets would strand both. Rotate one value at a time instead:

| Secret | How |
|---|---|
| `PULS_TOKEN` | Edit `.env`, `docker compose up -d ingest`, then re-pair each phone from `make pairing`. |
| A device token | `make devices ARGS='revoke <id>'`, then `scripts/bootstrap.sh --issue-device <label> [--user <uuid>]` and scan the new code on that phone. Effective on the next request; nothing restarts, and no other phone is affected. |
| `PULS_API_TOKEN`, `PULS_MCP_TOKEN` | Edit `.env`, `docker compose up -d api mcp`, update the API consumers and AI clients (`docs/ai.md`). |
| `GRAFANA_DB_PASSWORD`, `API_DB_PASSWORD`, `INGEST_DB_PASSWORD` | Edit `.env`, `docker compose up -d`: `migrate` re-runs `099_read_roles.sh`, which sets the new passwords, and the containers restart with them. |
| `POSTGRES_PASSWORD` | The superuser password lives in the database, not in `.env`: `docker compose exec db psql -U postgres -c "ALTER USER postgres PASSWORD '<new>'"` first, then edit `.env` and `docker compose up -d`. |
| `GRAFANA_PASSWORD` | Read at Grafana's first start only; change it in Grafana's own UI (or `docker compose exec grafana grafana cli admin reset-admin-password <new>`), then update `.env` to match. |

## Exposing the server

The phone has to reach ingest's port 8080. There are two supported ways, and
`scripts/bootstrap.sh` builds the pairing block for either:

- **On your own LAN, in plain HTTP.** `scripts/bootstrap.sh --lan` (or
  `INGEST_BIND_ADDR=0.0.0.0` and `docker compose up -d`); the phone uses
  `http://<LAN IP>:8080`. The app accepts plain `http://` only for
  local-network hosts (`localhost`, `*.local`, `10.x`, `172.16–31.x`,
  `192.168.x`), so this works on the same Wi-Fi and nowhere else. Anything
  on that network can read the traffic, and the bearer token is all that
  stands between it and your health data: use it only on a network you
  control.
- **From anywhere, over HTTPS.** Keep ingest on loopback (the default)
  behind a TLS-terminating proxy. **Never open port 8080 to the internet or
  serve it in plaintext beyond your LAN**: the token is a second layer
  behind TLS, not a substitute for it. `scripts/bootstrap.sh --url
  https://<host>` stores the proxy's URL as `PULS_PUBLIC_URL`, and the
  pairing block and every device token's QR code carry it.

Any reverse proxy that terminates TLS works (Caddy, nginx, Traefik, a cloud
tunnel). The easiest is Tailscale, on the server and the iPhone:

```bash
tailscale serve --bg --https=443  http://localhost:8080   # ingest — the app's URL
tailscale serve --bg --https=8443 http://localhost:3000   # Grafana
tailscale serve --bg --https=8444 http://localhost:8081   # product API
tailscale serve --bg --https=8445 http://localhost:8082   # MCP server
```

Point the app at `https://<machine-name>.<tailnet>.ts.net`. `tailscale
funnel` publishes the same listener to the public internet for a phone that
cannot join the tailnet; the token is then the only gate, so rotate it if it
leaks. Grafana, the product API and the MCP server stay on loopback and are
reached only this way (or through your own proxy with its own
authentication).

### The web viewer on your own domain: Cloudflare Tunnel

To let people outside your tailnet use the web viewer — family on their own
phones, say — run it in **accounts mode** (each person signs in and sees only
their own records; `web/README.md`, "Access control") and publish it through
the optional `tunnel` service, a Cloudflare Tunnel. It needs a domain whose
DNS is on Cloudflare, and no open port: `cloudflared` dials out and reaches
the viewer as `http://web:3000` on the Compose network, so `WEB_BIND_ADDR`
stays on loopback. Cloudflare terminates TLS, so it sees the traffic — say so
to the people you invite.

1. In the Cloudflare dashboard, create a tunnel (Networks → Tunnels), add a
   published application route for your hostname (`viewer.example.com`) with
   the service `http://web:3000`, and copy the tunnel's token.
2. In `.env`:

   ```bash
   CLOUDFLARE_TUNNEL_TOKEN=<token>
   COMPOSE_PROFILES=tunnel              # start the tunnel on every `up -d`
   WEB_ACCOUNTS=true
   WEB_DATABASE_URL=postgres://web_app:${WEB_DB_PASSWORD}@db:5432/postgres?sslmode=disable
   TRUST_PROXY_HEADERS=true             # the tunnel is the only way in
   WEB_CLIENT_IP_HEADER=cf-connecting-ip
   WEB_PUBLIC_URL=https://viewer.example.com
   ```

   `CF-Connecting-IP` is the header to key throttling on: Cloudflare sets it
   itself, whereas it appends to a client's `X-Forwarded-For`.
   `TRUST_PROXY_HEADERS` is shared with ingest and the API; if ingest is
   reached some other way that does not overwrite `X-Forwarded-For`, read
   "Rate limiting" before turning it on.
3. `docker compose up -d` (or `make dev-up`), then invite people:
   `make issue-device NAME='…' ARGS='--user <uuid>'` for their phone, and
   `make web-invite ARGS='--user <uuid> --email <address>'` for the viewer.

While the viewer is invite-only, a second lock costs nothing: put Cloudflare
Access (a one-time PIN to the invited addresses, or your identity provider) in
front of the hostname, and add a Cloudflare rate-limiting rule on `/login`,
`/invite/*` and `/api/auth/*` on top of the viewer's own throttling. Check
from outside that `http://` is redirected to `https://` (Cloudflare's "Always
Use HTTPS"), that `/workouts` sends you to `/login`, and that the viewer's log
says `mode=accounts`.

## API

Ingest speaks the Puls Sync Protocol, version **1**. The specification —
every line type and field, the header, responses and the retry contract — is
[`docs/protocol/README.md`](../docs/protocol/README.md); this section is the
summary an operator needs.

A client may declare the version as `"schemaVersion": 1` in the batch header
and as the `X-Puls-Protocol: 1` request header; a request with neither is
read as version 1. Any other version, or two declarations that disagree, is
refused before decompression or any database work with HTTP 400
`{"error":"unsupported protocol version","supportedVersions":[1]}` and
recorded in `ingest_rejections` (stage `protocol`). The app never retries a
4xx, so it shows this as a protocol mismatch instead of stalling silently.

Every endpoint but `/healthz` needs `Authorization: Bearer <token>` (see
"Tokens") and takes an optional `X-User-ID` UUID — the user rows are written
as or read for, defaulting to the seeded default user.

- `POST /v1/batches` — a gzipped NDJSON batch: a header line, then samples,
  deletions, workout-route lines, workout-series lines, aggregate lines,
  activity-summary lines and an optional profile line, each counted in the
  header. Sample `kind` is `quantity`, `category`, `workout`,
  `heartbeatSeries`, `ecg`, `stateOfMind` or `medicationDose`, each in its
  own table. Samples are keyed on UUID and never overwritten, so a retry is
  idempotent. Aggregate buckets and daily activity summaries are recomputed
  on the phone and **upserted**, and an explicit `null` value overwrites a
  stored one. The profile line replaces the user's whole profile (null or
  omitted fields clear stored values; no profile line leaves it unchanged).
  A header-only batch (every count 0) is valid; the app sends one as its
  connection probe to receivers without `/v1/capabilities`. Optional
  `X-Wake-ID` (a UUID; malformed is a 400) and `X-Wake-Trigger` headers are
  recorded on the `batches` row (see "Analysing background wakes"). Returns
  `{"accepted":N,"deleted":M,"duplicates":K,"routePoints":P,"seriesPoints":S,"aggregateSamples":A,"activitySummaries":U}`.
  Limits: compressed body ≤ 256 MB, decompressed NDJSON ≤ 128 MB, each
  declared count ≤ 100,000, all declared lines ≤ 200,000, route and series
  points ≤ 100,000 each per batch, one NDJSON line ≤ 4 MB (real lines peak
  around 400 KB).
- `GET /v1/stats` — per-type row counts and bounds, plus batch bookkeeping.
- `GET /v1/digest?type=&from=&to=` — per-UTC-month `{window, rows, digest}`,
  the digest being the XOR of all sample UUID bytes; the app uses it to
  detect drift.
- `GET /v1/uuids?type=&from=&to=` — sample UUIDs for one window (at most 35
  days).
- `GET /v1/routes` — route-backed workout summaries for external route
  consumers; optional `start`, `end`, `activityType`, `minDistanceM`,
  `maxDistanceM`, `limit` and `offset`.
- `GET /v1/routes/{uuid}` — one route-backed workout with its ordered GPS
  points; `GET /v1/routes/{uuid}/metrics` — its intra-workout metric
  streams.
- `GET /v1/capabilities` — what this receiver speaks. The app's Test
  Connection calls it, so URL and token are checked together before the
  first upload. `version` is the image's `BUILD_COMMIT` build arg (Compose
  passes `DEPLOY_COMMIT`; a plain `go run` reports `dev`).
- `GET /healthz` — liveness and DB ping (no auth).

## Product API

The product read API is a separate Go service on loopback port 8081; expose
it only through an authenticated HTTPS proxy (see "Exposing the server").
Clients send `Authorization: Bearer $PULS_API_TOKEN` — not the phone's
ingest token — and the service connects to Postgres as the read-only
`api_reader` role (schema usage plus `SELECT` grants).

**Whose data.** Every `/v1` request is answered for one user: `PULS_USER_ID`
unless the query carries `user=<uuid>`. Naming anyone else needs
`PULS_MULTI_USER=true` (default `false`); otherwise it is a `403
{"error":"multi-user reads are disabled"}`, never a quiet answer for the
default user. A non-UUID value is a `400`. Neither counts against the
failed-authentication limit, and an unknown id reads as a user with no
data. `GET /v1/users` lists every user (only the default with the gate off)
with name, e-mail, `createdAt`, `lastSync`, `batches` and
`uploadedSamples`, plus `default` and `multiUser` flags. **Turning the gate
on widens what the one `PULS_API_TOKEN` reads from one person to everyone
on the server** — and to any ChatGPT Action built from `/openapi.json`.

```bash
curl -s -H "Authorization: Bearer $PULS_API_TOKEN" http://localhost:8081/v1/users
curl -s -H "Authorization: Bearer $PULS_API_TOKEN" \
  "http://localhost:8081/v1/metrics/latest?types=HKQuantityTypeIdentifierHeartRate&user=<uuid>"
```

Timestamps are epoch milliseconds, ranges are `[start, end)`, and a valid
query with no matching rows returns an empty array.

**Daily metrics need an aggregate, not just raw rows.** `metric_daily` — and
so `/v1/metrics/daily`, Grafana's daily panels and the web viewer's daily
charts — takes a type's cumulative/discrete semantics from
`aggregate_series` (`db/migrations/009_metric_daily.sql`), which only
aggregate lines write. A type with raw samples and no aggregate configured
has latest readings and intraday values but no daily row. That is why the
phone uploads a recent window of aggregates before its raw sweep on a first
backfill.

The service describes itself at `GET /` (a JSON index), `GET /docs` (a
browser-readable reference) and `GET /openapi.json` (OpenAPI 3.1). Other
services should store the base URL as `PULS_API_BASE_URL` and the token as
`PULS_API_TOKEN`. Every `/v1` route but `/v1/users` takes the optional
`user` parameter above:

- `GET /v1/users`, `GET /v1/profile`
- `GET /v1/catalog/types` — every type with data, aggregate-only ones
  included: `rawRows`, `aggregateRows` and `rows` (their sum). Cached
  briefly, since it counts rows.
- `GET /v1/metrics/latest?types=...`
- `GET /v1/metrics/daily?types=...&start=...&end=...&limit=10000&offset=0` —
  one value per local day per type, paged in **days across the requested
  types** (`limit` caps at 50000; page with `nextOffset`, a short page is
  the last). The default page holds a year of 27 types, so a request that
  names no `limit` gets what it always did; a page boundary can fall inside
  a metric's days, so the next page may open with the same identifier.
- `GET /v1/activity/summary?start=...&end=...`
- `GET /v1/workouts?start=...&end=...&limit=50&offset=0`, `GET /v1/workouts/{uuid}`
- `GET /v1/workouts/{uuid}/series?types=...&maxPoints=500` — each stream
  downsampled by bucket-averaging, keeping the true first and last point
  (`maxPoints` caps at 5000); `totalPoints` is the recorded count.
- `GET /v1/sleep/daily?start=...&end=...` — one row per sleep session,
  attributed to the local day it **ends** on (the wake-up day, as Apple
  Health does it); samples more than three hours apart start a new session,
  so a nap is its own row. Durations are minutes. Overlapping sources are
  never summed: `inBedMinutes` is the highest single-source total, and
  `asleepMinutes` and the `stages` breakdown come from the source that
  recorded the most sleep (the web viewer's rule too). Stages are decoded
  through `category_labels`.
- `GET /v1/samples?type=...&start=...&end=...&limit=1000&offset=0` — the raw
  records of one quantity or category type, at most 31 days per request
  (`limit` caps at 5000; page with `nextOffset`). **Not** deduplicated across
  devices — `/v1/metrics/daily` is. An unknown identifier, a non-sample kind
  or a longer range is a `400`.
- `GET /v1/state-of-mind?start=...&end=...` — at most 366 days per request.
- `GET /v1/summary?range=7d|14d|30d|90d&format=markdown|json` — the last
  `range` days (default `7d`, ending today in `PULS_TIME_ZONE`) as one
  **markdown page** of under sixty lines for pasting into a chat without an
  MCP connection ([`docs/ai.md`](../docs/ai.md)), or the same numbers as
  JSON. It reads only daily surfaces, never a raw hypertable, so it is cheap.
- `GET /v1/export?format=csv|jsonl&dataset=...&start=...&end=...` — a whole
  range streamed as a **file**. `dataset` is `daily_metrics`, `samples`,
  `workouts`, `sleep`, `activity` or `state_of_mind`, each with its source
  endpoint's filters; at most 31 days for `samples`, 366 for the rest.
  Nothing is buffered, but each download holds a database connection
  throughout, so at most two run at once and a third gets a `503` with
  `Retry-After`. `tools/puls-export` is a CLI for it; columns and failure
  modes are in [`docs/export.md`](../docs/export.md).
- `GET /healthz` — liveness and DB ping (no auth).

```bash
curl -fL -H "Authorization: Bearer $PULS_API_TOKEN" -OJ \
  "http://localhost:8081/v1/export?format=csv&dataset=sleep&start=1767225600000&end=1798761600000"
```

Besides the sample tables, `/v1/samples` and `/v1/sleep/daily` read
`sources` and `category_labels`, and `/v1/users` reads `batches` (which holds
no credential — a batch's token is an integer id into `device_tokens`, which
`api_reader` cannot read). All are on the exact grant list in
`db/migrations/099_read_roles.sh`, re-applied on every `docker compose up
-d`.

### Verify ingest with curl

```bash
source .env

cat > /tmp/puls-fixture.ndjson <<'EOF'
{"batchID":"0a4fdc4e-9f3b-4f7e-9a64-0c2f7a1b9d11","deviceID":"curl-test","type":"HKQuantityTypeIdentifierHeartRate","reason":"manual","exportedAt":1718000000000,"schemaVersion":1,"clientVersion":"curl","sampleCount":2,"deletionCount":1,"aggregateCount":1,"activitySummaryCount":1}
{"uuid":"7f3e2b9a-1c4d-4e5f-8a6b-9c0d1e2f3a4b","type":"HKQuantityTypeIdentifierHeartRate","kind":"quantity","start":1718000000000,"end":1718000005000,"value":62.5,"unit":"count/min","sourceName":"Apple Watch","sourceBundleID":"com.apple.health","sourceVersion":"10.0","device":"Apple Watch","metadata":{"HKMetadataKeyHeartRateMotionContext":1}}
{"uuid":"8a4f3c0b-2d5e-4f6a-9b7c-0d1e2f3a4b5c","type":"HKQuantityTypeIdentifierHeartRate","kind":"quantity","start":1718000010000,"end":1718000015000,"value":64.0,"unit":"count/min","sourceName":"Apple Watch","sourceBundleID":"com.apple.health","sourceVersion":"10.0"}
{"deleted":{"uuid":"9b5a4d1c-3e6f-4a7b-8c8d-1e2f3a4b5c6d","type":"HKQuantityTypeIdentifierHeartRate"}}
{"aggregate":{"type":"HKQuantityTypeIdentifierHeartRate","func":"average","intervalValue":1,"intervalUnit":"hour","deviceFilter":"watch","bucketStart":1718000000000,"bucketEnd":1718003600000,"value":62.4,"unit":"count/min"}}
{"activitySummary":{"date":1718000000000,"moveKcal":420.5,"moveGoalKcal":600.0,"exerciseMin":25.0,"exerciseGoalMin":30.0,"standHours":9.0,"standGoalHours":12.0,"moveMode":0,"moveTimeMin":null,"moveTimeGoalMin":null}}
EOF

gzip -c /tmp/puls-fixture.ndjson | curl -sS \
  -X POST http://localhost:8080/v1/batches \
  -H "Authorization: Bearer $PULS_TOKEN" \
  -H "Content-Type: application/x-ndjson" \
  -H "Content-Encoding: gzip" \
  -H "X-Puls-Protocol: 1" \
  -H "X-Batch-ID: 0a4fdc4e-9f3b-4f7e-9a64-0c2f7a1b9d11" \
  -H "X-User-ID: 5ea4d000-0000-4000-8000-000000000001" \
  -H "X-Wake-ID: 11111111-2222-4333-8444-555555555555" \
  -H "X-Wake-Trigger: observer" \
  --data-binary @-
# → {"accepted":2,"deleted":0,"duplicates":0,"routePoints":0,"seriesPoints":0,"aggregateSamples":1,"activitySummaries":1}
# Run it again → {"accepted":0,"deleted":0,"duplicates":2,"routePoints":0,"seriesPoints":0,"aggregateSamples":0,"activitySummaries":0}
#   (the batch ID is reserved before health-data mutations, so a retry exits early)
# Send it with -H "X-Puls-Protocol: 2" (or "schemaVersion":2 in the header line)
#   → HTTP 400 {"error":"unsupported protocol version","supportedVersions":[1]}

curl -s -H "Authorization: Bearer $PULS_TOKEN" http://localhost:8080/v1/capabilities
# → {"protocolVersions":[1],"features":["batches","stats","digest","uuids","aggregates","activitySummaries","routes","series","profile"],"server":"puls-ingest","version":"…"}

# The app's connection probe for a receiver without /v1/capabilities: a
# header-only batch (fresh batchID each time, every count 0, reason "manual").
printf '%s\n' '{"batchID":"1b2c3d4e-5f60-4718-8293-a4b5c6d7e8f9","deviceID":"curl-test","type":"HKQuantityTypeIdentifierHeartRate","reason":"manual","exportedAt":1718000000000,"schemaVersion":1,"clientVersion":"curl","sampleCount":0,"deletionCount":0}' \
  | gzip -c | curl -sS -X POST http://localhost:8080/v1/batches \
  -H "Authorization: Bearer $PULS_TOKEN" -H "Content-Encoding: gzip" -H "X-Puls-Protocol: 1" \
  --data-binary @-
# → {"accepted":0,"deleted":0,"duplicates":0,"routePoints":0,"seriesPoints":0,"aggregateSamples":0,"activitySummaries":0}

curl -s -H "Authorization: Bearer $PULS_TOKEN" http://localhost:8080/v1/stats | python3 -m json.tool
```

### Analysing background wakes

Every upload writes one `batches` row with `received_at` (server time),
`wake_id`/`trigger` (the iOS wake that produced it), `bytes`, `parse_ms`,
`insert_ms` and the per-kind counts — enough to see how often the phone got
execution time and what each wake did. The app's own wake export (Sync →
Activity → Background → Export) adds durations, gaps, expirations and Low
Power Mode.

```bash
# Uploads per hour over the last 14 days, by trigger.
docker compose exec db psql -U postgres -d postgres -c "
  SELECT date_trunc('hour', received_at) AS hour, trigger,
         count(*) AS batches, sum(sample_count) AS samples, sum(bytes) AS bytes
  FROM batches WHERE received_at > now() - interval '14 days'
  GROUP BY 1, 2 ORDER BY 1 DESC, 2;"

# One row per wake: when, what triggered it, how much it carried, server timings.
docker compose exec db psql -U postgres -d postgres -c "
  SELECT min(received_at) AS at, trigger, count(*) AS batches,
         sum(sample_count) AS samples, sum(bytes) AS bytes,
         max(parse_ms) AS parse_ms, max(insert_ms) AS insert_ms
  FROM batches WHERE wake_id IS NOT NULL AND received_at > now() - interval '7 days'
  GROUP BY wake_id, trigger ORDER BY at DESC;"

# Dump the raw batch log to CSV for offline analysis.
docker compose exec db psql -U postgres -d postgres -c "
  COPY (SELECT received_at, wake_id, trigger, type_identifier, reason,
               sample_count, deletion_count, aggregate_count,
               activity_summary_count, bytes, parse_ms, insert_ms
        FROM batches WHERE received_at > now() - interval '14 days'
        ORDER BY received_at) TO STDOUT CSV HEADER" > batches_14d.csv
```

## Grafana

Open `http://localhost:3000` on the host, or through your TLS proxy (e.g.
`https://<machine>.<tailnet>.ts.net:8443`), and log in as `$GRAFANA_USER`
(default `admin`) / `$GRAFANA_PASSWORD`. The TimescaleDB datasource
(read-only `grafana` role) and two cross-linked dashboards are provisioned
automatically:

- **PulsHealth** (`puls-health`, 15 min refresh) — heart rate with workout
  annotations, daily steps, on-device aggregate series, a metric explorer
  over `quantity_rollups`, sleep, resting HR and HRV trends, workouts, a GPS
  route map, state of mind and medication doses. Daily panels bucket by the
  hidden `tz` variable, read from `puls_time_zone()`, so they agree with
  `metric_daily` and the API. Everything is filtered by the *User* variable
  (default: the seeded user).
- **PulsHealth Ops** (`puls-ops`, 1 min refresh) — ingest health: last-batch
  age (yellow > 2 h, red > 6 h), batches per hour, ingest latency,
  samples/aggregates/deletions per day, and per-type row counts (quantity
  counts from the `quantity_rollups` rollup, not hypertable scans).

The route map's basemap is OpenStreetMap, named explicitly in the panel, and
Compose sets `GF_GEOMAP_DEFAULT_BASELAYER_CONFIG` to the same so a geomap
panel you add with the *Default base layer* uses it too. Grafana's own
default is CARTO, whose raster tiles have shown an "API KEY REQUIRED"
watermark on every keyless request since September 2026; OpenStreetMap needs
no key or account. The browser fetches the tiles from
`tile.openstreetmap.org` directly while the panel is open.

### Alerting

A red dashboard nobody has open alerts no one, so four rules in
`grafana/provisioning/alerting/rules.yml` push instead:

| Rule | Fires when | Detects in | Why that threshold |
|---|---|---|---|
| Ingest is rejecting batches | > 10 rejections in 30 min | ~10 min | A real outage rejects ~85 an hour; the benign `context canceled` class runs 1–2 per *month*. Nothing lives between those numbers. |
| A batch is stuck on a rejected page | the same 4xx message in ≥ 3 distinct hours of the last 6 | ~3 h | A page the server always rejects (a new line type before the server update, an oversized line, an out-of-range value) is re-sent about hourly and never reaches the rate rule; the client does not retry 4xx, so that type stalls until server or client is fixed. |
| Ingest stalled | no batch for > 14 h | 14.5 h | Over 60 days of `batches`, only 2 normal gaps exceeded 14 h, versus 7 at 12 h and 22 at 10 h. |
| Lookup sequence near exhaustion | any smallint identity sequence > 95% | ~5 min | At the ceiling every insert fails and ingest stops. Not 80%: `sources_source_id_seq` legitimately sits near 90% with unreclaimable gaps, and a permanently red rule gets muted. |

To re-derive the staleness threshold after usage patterns change:

```sql
SELECT thr, count(*) FILTER (WHERE gap > thr) AS false_alarms_60d FROM (
  SELECT received_at - lag(received_at) OVER (ORDER BY received_at) AS gap
  FROM batches WHERE received_at > now() - interval '60 days'
) s, (VALUES (interval '10 hours'),(interval '12 hours'),
             (interval '14 hours'),(interval '18 hours')) t(thr)
WHERE gap IS NOT NULL GROUP BY thr ORDER BY thr;
```

The sequence rule needs `SELECT` on the sequences — without it
`pg_sequences.last_value` reads NULL for `grafana` and the rule never fires.
`099_read_roles.sh` grants it on every `docker compose up -d`.

**Email delivery needs one manual step.** Rules always evaluate and turn the
UI red, but SMTP is off by default so a deploy never fails on a missing
credential. To turn mail on, put a Gmail **App Password** (not the account
password; it needs 2-Step Verification —
<https://myaccount.google.com/apppasswords>) in `GRAFANA_SMTP_PASSWORD`, set
`GRAFANA_SMTP_USER` and `GRAFANA_SMTP_ENABLED=true` (another provider:
`GRAFANA_SMTP_HOST`, default `smtp.gmail.com:587`), then:

```bash
docker compose up -d grafana
```

Test it end to end in the UI — **Alerting → Contact points → puls-email →
Test** — and check the contact point shows your `GRAFANA_ALERT_EMAIL` rather
than the `alerts@example.com` default (see "Configuration"). If the test mail
does not arrive, alerts will not either.

## Backup & restore

**The stack has a backup service, and it is off until you turn it on.** Until
then the live Postgres volume is the only copy of your data: a dead disk, a
bad migration or a `docker compose down -v` loses everything.

```bash
# One dump, right now — do this before any schema change or upgrade.
make backup

# Dumps on a schedule (default: every 24h, keeping 14 days). Naming the
# service starts only it (and db); the app containers are left alone.
cd server && docker compose --profile backup up -d backup

make backup-list                     # what is in the store
make restore FILE=<name or path>     # put one back (destroys the current data)
```

Name `backup` as above: `docker compose --profile backup up -d` alone also
(re)starts everything else, which on an install built from the checkout
swaps those containers for the published images (unless you add `-f
compose.build.yml`).

`backup` sits behind the **`backup` profile**, so a plain `docker compose up
-d` never starts it. It runs `backup/backup.sh` on the same pinned image as
`db`, so `pg_dump` always matches the server version. Each run writes
`puls-<UTC timestamp>.dump` (`pg_dump --format=custom`, compressed), checks
it with `pg_restore --list`, and only then renames it into place, so a
truncated dump is never mistaken for a backup. It then deletes dumps older
than `PULS_BACKUP_KEEP_DAYS` but **never the newest one**, however old — a
schedule that stopped weeks ago must not also delete your last copy.

`pg_dump` warns about circular foreign keys on `continuous_agg` on every run.
That is TimescaleDB's own catalog, and the hint applies to `--data-only`
dumps; these are full dumps, and they restore.

### Settings

| `.env` | Default | What |
|---|---|---|
| `PULS_BACKUP_INTERVAL` | `24h` | Between scheduled dumps. `24h`, `90m`, `3600s`, or bare seconds; minimum 60s. |
| `PULS_BACKUP_KEEP_DAYS` | `14` | Delete dumps older than this. `0` keeps everything. |
| `PULS_BACKUP_DIR` | (the `backups` volume) | Where dumps go. Set it to a path and they land there instead. |

**Point `PULS_BACKUP_DIR` at something that is not this disk.** The default
`backups` volume lives on the same disk as the database: it protects you
from a bad migration or a dropped table, not from a dead drive, and `docker
compose down -v` removes it along with `db_data`. An external disk, a NAS
mount, or a directory something else replicates survives both. Dumps written
there are owned by the directory's owner, mode `600`.

The schedule is a sleep loop, not cron (the image has no cron daemon), so it
is relative to when the container started — restarting the stack shifts the
dump time. For a fixed time, leave the profile off and run `make backup`
from the host's cron or systemd timer. `docker compose stop backup` returns
at once rather than waiting out the kill timeout.

### Restoring

`server/backup/restore.sh` (`make restore FILE=…`) **replaces the contents of
the database** — it does not merge, everything synced since the dump is
gone, and there is no undo. `FILE` is a path on the host or the name of a
dump in the backup store as `make backup-list` shows it (streamed out by a
throwaway container, never staged in a temporary file). Flags go through
`ARGS`, e.g. `make restore FILE=… ARGS="--yes --build"`:

| Flag | What |
|---|---|
| `--yes` | Skip the "type restore to continue" prompt. For scripted drills. |
| `--build` | Bring the stack back up from this checkout (`compose.build.yml`) rather than the published images. `PULS_BOOTSTRAP_BUILD=1` sets it too. |
| `--no-start` | Leave the app services stopped afterwards; `docker compose up -d` when you are ready. |

In order, it: starts `db` and verifies the archive is readable; stops
`ingest`, `api`, `mcp`, `web` and `grafana`; drops the web viewer's
`web` and `auth` schemas (the dump recreates them; left in place they stop
`pg_restore` at "schema already exists"), then drops and recreates the
`public` schema while TimescaleDB is still live, so its event triggers
dismantle hypertable chunks and continuous aggregates properly; reinstalls
the extension (it lives in `public`, so the drop takes it too); runs
`timescaledb_pre_restore()`, a **single-threaded** `pg_restore --no-owner
--no-privileges`, `timescaledb_post_restore()` and `ANALYZE`; and finally
`docker compose up -d`, where `migrate` recreates the `grafana`,
`api_reader`, `ingest` and (with `WEB_DB_PASSWORD`) `web_app` roles from
`.env` with their grants. The first
check is the important one: a truncated file, a plain-SQL dump, the wrong
file or a name not in the store is refused **before** anything is dropped.

Three TimescaleDB rules the script enforces, if you ever restore by hand:
`timescaledb_pre_restore()`/`timescaledb_post_restore()` around the restore;
**never** `pg_restore -j` (parallel restore reorders work in ways restoring
mode does not tolerate); and drop the old schema *before* `pre_restore`, not
after, or the extension catalog ends up describing tables that no longer
exist.

### The restore drill

Nothing verifies a backup but restoring it. Run this once on a scratch
install — not the one holding your data — so the first time you use
`restore.sh` is not the day you need it.

```bash
scripts/bootstrap.sh                    # a stack with something in it
# ...sync a batch from the app, or use the curl fixture in
#    "Verify ingest with curl" — give it a value you will recognise

make backup                             # → puls-<timestamp>.dump
make backup-list

# Destroy the database, keeping the dump. (Not `down -v`: that removes the
# backups volume too.)
make down
docker volume rm pulshealth_db_data

make restore FILE=puls-<timestamp>.dump ARGS=--yes
```

Add `--build` to both scripts to drill against images built from the
checkout. A good restore, as recorded on a throwaway stack, looks like this:

- `docker compose ps`: six services up, `db` healthy.
- `docker compose logs migrate`: **`0 applied, 0 rerun, <every .sql file>
  skipped, 2 script(s) ran`** — the schema came from the dump, and the role
  and time-zone scripts put back the roles, their grants and
  `puls_time_zone()`, which the restore itself skips.
- Every row count identical either side of the wipe, down to the values you
  recognise (`GET /v1/stats`, the viewer or `psql`); the hypertables, the
  `quantity_rollups` continuous aggregate and `metric_daily` querying; the
  `timescaledb` extension at the same version.
- Ingest accepts a new sample, and re-posting the seeded batch answers
  `"duplicates":2`.

## Development

Run the stack from the checkout with `make dev-up` (see "Images and
versions"). `ingest`, `api` and `mcp` are separate Go modules, so tests run
from each module's directory — for ingest:

```bash
cd ingest
go vet ./... && go test ./...                  # unit tests, no DB needed
# Integration tests against the compose database (db + schema, nothing else):
docker compose up -d migrate
set -a; source ../.env; set +a
# As the scoped ingest role — what the stack connects as; the superuser URL is
# still needed for the tests' DDL and compress_chunk setup steps:
DATABASE_URL="postgres://ingest:$INGEST_DB_PASSWORD@localhost:5432/postgres" \
ADMIN_DATABASE_URL="postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres" \
  go test -run Integration ./...
# ...or everything as the superuser:
DATABASE_URL="postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres" go test -run Integration ./...
```

The product API's fixture-writing integration tests also need
`PULS_API_WRITE_INTEGRATION_TESTS=1`; never run them against a live or
shared database. They read through `DATABASE_URL` and write fixtures through
`ADMIN_DATABASE_URL` (falling back to `DATABASE_URL`), so pointing the first
at `api_reader` and the second at the superuser tests the role's grants as
well as the queries.
