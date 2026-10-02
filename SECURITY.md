# Security policy

PulsHealth moves personal health data from an iPhone to a server the user
runs. Security problems in it matter more than in most hobby projects, so
please report them privately and give the maintainer a chance to fix them
before anything is public.

## Supported versions

The **iOS app** ships from the App Store; the current version there is the
supported one, and a fix reaches users in the next store release. Report
against it even if you cannot build the source.

The **server stack** is released as versioned images (`CHANGELOG.md`). While
it is on 0.x, the latest release and `main` are supported: fixes land on
`main` and ship in the next release. The **Swift package and the protocol
tooling** are not released separately; `main` is their supported line.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository:

**https://github.com/PulsHealth/pulshealth/security/advisories/new**

That is the only reporting channel. Do not open a public issue, pull request,
or discussion for a security problem, and do not email individual maintainers.

A useful report includes:

- which component is affected (iOS app, `PulsHealthSync` package, ingest
  server, product API, MCP server, web viewer, Compose stack, database schema);
- the commit or version you tested;
- steps or a proof of concept that reproduces the problem;
- what an attacker gains (data read, data written or deleted, denial of
  service, code execution, and so on);
- whether you believe it is already being exploited.

## What to expect

This is a volunteer-maintained project.

- You should get an acknowledgement within **7 days**.
- You should get an initial assessment (accepted, needs more information, or
  not a vulnerability) within **14 days**.
- Accepted reports are fixed on `main`, shipped in the next server release or
  app update, and published as a GitHub Security Advisory that credits you,
  unless you ask not to be named. The advisory says which release fixes it.
- Please allow up to **90 days** before disclosing publicly. If a fix is
  taking longer, the maintainer will say so rather than go quiet.

## Scope

Everything in this repository is in scope, in particular:

- **Ingest server** (`server/ingest`): the only component designed to face the
  network. Authentication bypass, parsing crashes, decompression or memory
  exhaustion, SQL injection, and anything that lets one bearer token read or
  modify data outside its intended reach.
- **Product API** (`server/api`) and **MCP server** (`server/mcp`): token
  handling, data exposure beyond the read-only role they are meant to have.
- **iOS app and `PulsHealthSync`**: handling of the server URL and bearer
  token, including a pairing link (`puls://pair`) changing the server without
  the confirmation it is supposed to require; health data written anywhere
  the user did not ask for — the one intended case is an on-device export,
  staged in the app's temporary directory and handed to the share sheet, so an
  export that lingers, lands somewhere else, or carries the token or profile
  is in scope; data sent anywhere other than the configured server.
- **Compose stack and schema** (`server/docker-compose.yml`, `server/db/migrations`):
  defaults that expose a service or credential more widely than documented.
- **Web viewer** (`web/`): as deployed the documented way — bound to loopback
  or a private interface, or in accounts mode behind a TLS proxy. In accounts
  mode in particular: reading another account's records by any route;
  signing in without the password or a valid invite; a session that survives
  sign-out, a password change or an invite reset; cross-site request forgery;
  getting past the failed-sign-in throttle; an open redirect; and any table
  holding per-user data that the `web_app` database role can read directly
  rather than through its per-user views. See the notes below.

Out of scope:

- Vulnerabilities in upstream images and dependencies (PostgreSQL,
  TimescaleDB, Grafana, Next.js, Go modules). Report those upstream; a report
  here is welcome if the project pins a version with a known fix available.
- Deployments that diverge from the documentation, such as publishing the web
  viewer in open or basic mode, Grafana, or the database port on a public
  interface.
- Attacks that require an unlocked phone in hand, or a compromised server host.
- HealthKit behaviour (delivery latency, permission-sheet quirks). Those are
  bugs, not vulnerabilities; use the issue tracker.

## Things to know about the current design

These are documented properties of the current design; what is still open is
in `docs/roadmap.md`. They are not vulnerabilities to report; they are context
for judging what is.

- **Self-hosted.** PulsHealth is software you run; no PulsHealth service
  receives your data. Where your server runs, how it is exposed, and who can
  reach it are your decisions. The maintainer runs one invite-only instance
  for family and friends (the viewer at `app.pulshealth.com`); a report about
  the software covers it too, and one about that instance's configuration is
  welcome through the same channel.
- **Bearer tokens.** The ingest server accepts two kinds. The shared
  `PULS_TOKEN` is a single static value: anyone who holds it can upload,
  delete, and (via the reconciliation endpoints) enumerate samples for *any*
  user, because with it the `X-User-ID` header selects the user without
  further authentication. Per-device tokens (`make devices`) are stored only
  as a SHA-256, bound to one user — a request naming another is refused with
  403 — revocable one at a time and stamped with their last use, so a lost
  phone costs one `revoke`. The shared token stays enabled by default so an
  existing install is unchanged; `PULS_ALLOW_SHARED_TOKEN=false` (or an empty
  `PULS_TOKEN`) turns it off, and the `X-User-ID` hole exists only while it
  is on. Failed authentications are rate-limited per client IP, which slows
  guessing but does not change what a leaked token grants.
- **The token lives on the phone.** It is held in the Keychain, accessible
  after the first unlock so background syncs still run, and the sync-state and
  log files carry file protection and are excluded from device backups. If a
  Keychain write fails the app parks the token in that protected state file
  instead of dropping it — losing it would stall syncing until the user
  re-entered it — and removes it once the Keychain accepts it.
- **Analysis summaries are derived numbers, never samples.** Analyzing a
  type on the Explore tab stores one small file per type (counts, dates,
  per-day counts, a value histogram and percentiles, and per-source and
  per-device counts by name) under the same file protection and backup
  exclusion as the sync state. A summary file that carried an individual
  sample, a value paired with its timestamp, a sample identifier or any
  metadata would be a bug in scope here.
- **An export is a plain file, and it is yours once shared.** The app can
  write the selected health data to JSONL or CSV without a server
  (`PulsHealthSync/Sources/PulsHealthSync/Export/`). The files are staged in
  the app's temporary directory — never backed up — and deleted at the next
  launch and once the share sheet is done with them; they carry no token, no
  server URL and no name, e-mail or date of birth — of the app's own
  identifiers only the user ID, the install's random device ID and the phone's
  time zone — though the health data itself names the app or device that
  recorded each sample, as HealthKit does. They are not encrypted
  beyond iOS file protection, and after the share sheet hands them to Files,
  AirDrop or another app, where they rest is outside the app's control.
- **TLS is yours to provide.** Every service binds to loopback by default. The
  phone must reach the ingest port over HTTPS through a TLS-terminating
  reverse proxy or a VPN; the token is only a second layer.
- **The web viewer has three modes** (`web/README.md`, "Access control").
  Open, with no login, for loopback only; basic, one shared
  `WEB_AUTH_PASSWORD` over HTTP Basic, behind which everyone sees every user —
  in both, the bind address is the primary access control, so keep
  `WEB_BIND_ADDR` on loopback or a private network; and accounts
  (`WEB_ACCOUNTS=true`), with invite-only accounts and HTTPS required.
- **Accounts mode: what the database enforces, and what it does not.** The
  viewer connects as `web_app`, which has no grant on any table holding
  health data and reads it only through security-barrier views filtered on a
  transaction-local setting (`server/db/migrations/015_web_accounts.sql`;
  views, not row-level security, which TimescaleDB refuses on compressed
  hypertables). That turns a query that forgets its user filter into a
  harmless one. It does not make a compromised viewer harmless: code running
  as `web_app` — an SQL injection, a compromised container — can set the
  setting to any user, and can read the account table (email addresses,
  scrypt password hashes, session hashes), which sign-in needs. Shared,
  non-health metadata is readable by every account's role: the list of
  HealthKit type identifiers seen on the server, and TimescaleDB catalog
  information such as approximate row counts and chunk time ranges, reachable
  only with arbitrary SQL. Failed sign-ins are throttled in process, per
  address and per email, and reset when the container restarts. The viewer
  sends no email, so a forgotten password is a new invite from the operator.
- **Health data at rest.** The database holds identifiable data (name, email,
  date of birth, sex) alongside samples. Ingest connects as the scoped
  DML-only `ingest` role, which cannot create or drop objects; set
  `INGEST_DB_USER=postgres` to fall back to the superuser. Backups are opt-in
  and off by default: enable the `backup` Compose profile, and run the restore
  drill in `server/README.md` yourself, because nothing else verifies that
  your dumps restore.
