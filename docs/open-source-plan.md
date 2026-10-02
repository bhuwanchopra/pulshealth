# Open-sourcing PulsHealth — decisions and requirements

Status: approved 2026-09-04. Its five phases (scrub and go public; protocol
v1 and app safety; self-host v1; the AI layer; the App Store) were complete
by 2026-09-19: the repository went public on 2026-09-07, the server stack's
v0.1.0 shipped on 2026-09-14, and the app's 1.4 reached the store on
2026-09-19. This file records what was decided and why, and defines the
requirement IDs that code and documents cite. **What is still open is in
[`roadmap.md`](roadmap.md).**

## 1. Goal

Let anyone get their Apple Health data into a backend they control and use
it with AI tools. Three deliverables:

| Deliverable | What it is |
|---|---|
| **PulsHealth app** | The App Store app. Reads HealthKit, syncs to a backend the user configures, exports files. The source is open; the store listing and the name are the maintainer's. |
| **Puls Sync Protocol** | The versioned wire contract between the app and *any* backend: one gzip NDJSON `POST`, optional read endpoints. Spec, JSON Schema, conformance fixtures and a small reference receiver (`docs/protocol/`). |
| **Reference backend** | The Docker Compose stack: TimescaleDB, Go ingest, product API, MCP server, web viewer, Grafana. |

The model is Bitwarden or Immich: an official store app anyone can point at
their own server, with app and server both open. "Use it with AI" means a
user connects PulsHealth to Claude, ChatGPT or Cursor over MCP and asks "how
did I sleep this week", or drops an export into a chat.

## 2. Decisions

### D1. License

**Apache-2.0 for everything, plus `TRADEMARK.md`.** The goal is adoption of
the protocol and the app, and the Swift package is meant to be embedded in
other apps, so the terms are permissive. Apache-2.0 carries a patent grant
and, in section 6, withholds trademark rights: anyone may fork and ship,
nobody may call it PulsHealth or use the icon. AGPL for the server was
rejected: a closed hosted clone is a small risk for data people self-host to
avoid hosted services, copyleft slows adoption by AI tooling, and GPL code on
the App Store would need a CLA from every contributor. Contributions carry a
DCO sign-off instead.

### D2. Repository

**One monorepo at `github.com/PulsHealth/pulshealth`, with a fresh history.**
The rule that wire-format changes touch both sides is easiest to enforce in
one repository with one CI. Split later if the Swift package gains outside
adopters. History started from a single commit because personal identifiers
were in every earlier one; the private repository is the archive.

### D3. What "bring your own backend" means

**One transport (HTTPS), one open protocol, an ecosystem of receivers.** No
native S3, Supabase, Sheets or Notion sinks in the app. The spec says what a
receiver must do, and a minimal one is about a hundred lines in any language.
That keeps the app small, App Review simple, and the protocol the thing
people build on. The one addition, a local file export for people who want a
file to hand to a chat, shipped as the Export tab, which is not a sink: it
runs on a throwaway engine of its own (`docs/export.md`).

### D4. Auth between app and backend

**Bearer tokens are the protocol contract.** Every hobbyist can check a
header; mTLS, OAuth or signed requests would shrink the set of people who can
write a receiver. On the client the token lives in the Keychain
(`AfterFirstUnlock`, so background wakes still work), HTTPS is required except
on the local network, a connection test runs before saving, and pairing reads
a `puls://pair` QR code or link. Per-device tokens with revocation are a
reference-server feature, not a protocol change; binding a token to a user
closes the unauthenticated `X-User-ID` hole (SRV-8).

### D5. Identity model

**A fixed, neutral default user UUID and no personal defaults.** A
per-install random UUID would make every reinstall a second user and a second
full backfill; a fixed one survives reinstalls, which is what a single-person
self-host wants. Households set distinct IDs, by hand or through pairing.
Name, email, date of birth and sex default to nil on the client and NULL in
the seed, and the server creates a user the first time it sees one. The
product API, the MCP server and the web viewer read `PULS_USER_ID`, else the
default user.

### D6. The first AI surface

**A read-only MCP server over the product API, in Go.** Over the API rather
than Postgres because the token boundary and the read-only role already
exist, OpenAPI already describes every shape, and the API keeps the
double-counting traps out of the model's hands. Go keeps the server side one
language and distroless, and one binary serves both `stdio` (desktop clients)
and streamable HTTP (the Compose service, for remote connectors). The raw-SQL
tool that was to follow as an opt-in (AI-7) was dropped.

### D7. Name

**"PulsHealth" for the app and the project, "Puls Sync Protocol" for the
spec.** `pulshealth.com` hosts the documentation and the privacy policy.

### D8. What stays private

**The maintainer's production operations** — host, network, deploy pipeline
and rollback — are not in this repository. `CLAUDE.md` keeps the invariants
and gotchas, which are the best contributor documentation in the tree.

## 3. Requirements

MoSCoW: **M**ust before public launch, **S**hould for v1.0, **C**ould later.
"Done" means it is in the tree; open items are in [`roadmap.md`](roadmap.md),
and so are the ones decided against (its "Not planned").

### App (R-APP)

| # | Requirement | Pri | Status |
|---|---|---|---|
| APP-1 | No personal defaults: name/email/DOB/sex nil; a fixed neutral default user UUID, editable; decode fallbacks match. | M | Done |
| APP-2 | Bearer token in the Keychain (`AfterFirstUnlock`); `sync-state.json` and `event-log.json` protected until first unlock and excluded from backup. | M | Done |
| APP-3 | Server URL validation: `https` required unless the host is on the local network. | M | Done (`ServerURLValidation`) |
| APP-4 | "Test connection" before saving (`GET /v1/capabilities`), telling auth, reachability and TLS errors apart. | M | Done (`ConnectionTest`) |
| APP-5 | Sync state keyed by server identity; changing server asks whether to start a fresh backfill or keep the anchors. | M | Done (`ServerIdentity`) |
| APP-6 | Development team and bundle-ID prefix from an untracked `Local.xcconfig`; BG task identifiers derived from the bundle ID, so forks can sideload. | M | Done |
| APP-7 | `PrivacyInfo.xcprivacy` with required-reason API declarations. | M | Done |
| APP-8 | Onboarding: explain, Health permission, then on to syncing. | S | Done; since 1.6 the first run leaves connecting a database to the Sync tab |
| APP-9 | Pairing from a `puls://pair?url=&token=&user=` payload. | S | Done: QR code, link, Camera app, clipboard |
| APP-10 | Capabilities-driven UI: hide reconciliation and stats when the backend does not advertise them. | S | Done |
| APP-11 | A non-HTTP sink persisted with the configuration so it survives cold background launches; read side behind a protocol so reconciliation degrades gracefully. | S | Not planned until a second sink exists — roadmap, Not planned |
| APP-12 | Local file export (NDJSON/CSV via the share sheet). | C | Done: the Export tab (`HealthExporter`, `docs/export.md`) |
| APP-13 | The event log never holds sample UUIDs; server error bodies are truncated and scrubbed before they are kept. | S | Done (`ErrorScrubber`) |

### Protocol (R-PROTO)

| # | Requirement | Pri | Status |
|---|---|---|---|
| PROTO-1 | `schemaVersion` and `clientVersion` in the batch header and an `X-Puls-Protocol: 1` header; an unknown major is a 400 with `supportedVersions`. | M | Done |
| PROTO-2 | The `docs/protocol/` spec: transport, line types, canonical units, epoch-ms, and the idempotency, ack and retry contracts. | M | Done |
| PROTO-3 | JSON Schema for the header and every line type. | M | Done (`docs/protocol/schema/`; `tools/protocol-check` runs the corpus against it in CI) |
| PROTO-4 | A conformance corpus runnable against any receiver URL. | S | Done: `examples/receivers/python-sqlite/smoke_test.py --url … --token …` posts `docs/protocol/fixtures/` and checks the expected outcomes |
| PROTO-5 | A minimal reference receiver, to prove the spec can be implemented in an afternoon. | S | Done (`examples/receivers/python-sqlite/`) |
| PROTO-6 | Optional `GET /v1/capabilities`. | S | Done |
| PROTO-7 | Type vocabulary v1 published as one JSON file, with no hand-kept second catalog. | S | Done, generated the other way round: `HealthTypeCatalog.swift` renders `docs/protocol/catalog.json`, which renders `web/lib/catalog.generated.ts` |
| PROTO-8 | Optional response body (`accepted`, `duplicates`, …) surfaced in the upload result. | C | Done (`IngestReceipt`) |

### Reference server (R-SRV)

| # | Requirement | Pri | Status |
|---|---|---|---|
| SRV-1 | Neutral user seed; users created on first batch; reads default to one user without configuration. | M | Done |
| SRV-2 | Time zone from configuration everywhere (`PULS_TIME_ZONE`). | M | Done (`puls_time_zone()`) |
| SRV-3 | Migration framework with a `schema_migrations` table. | M | Done, as the `migrate` Compose service (`server/db/migrate.sh`) |
| SRV-4 | Quickstart: one command generates the secrets, starts the stack and prints the pairing QR code. | M | Done (`scripts/bootstrap.sh`) |
| SRV-5 | Published images on `ghcr.io/pulshealth/{ingest,api,mcp,web}`; `compose.build.yml` for developers. | M | Done |
| SRV-6 | Ingest connects as the scoped `ingest` role by default. | M | Done |
| SRV-7 | Auth-failure rate limiting on ingest and the API. | S | Done |
| SRV-8 | Per-device tokens: enroll → pending → approve; hashed at rest; last-seen; revocable; bound to a user. | S | Done server side (`make devices`); phone-side enrollment not planned — roadmap, Not planned |
| SRV-9 | Opt-in backups with retention, and a documented restore drill. | S | Done (the `backup` profile) |
| SRV-10 | Web viewer auth, and a viewer-scoped database role instead of `grafana`. | S | Done, in two forms: `WEB_AUTH_PASSWORD` (one shared password, the `grafana` role) and accounts mode (`WEB_ACCOUNTS`: invite-only accounts, and the `web_app` role, which the database limits to the signed-in person's records) |
| SRV-11 | A second user without a volume wipe. | S | Writes, and reads through the API, viewer and MCP server, done; in the viewer's accounts mode each person signs in and reads only their own records. A per-user read token for the product API is not planned — roadmap, Not planned |
| SRV-12 | Grafana contact point from `GRAFANA_ALERT_EMAIL`; alert thresholds documented as tunables. | S | Done |
| SRV-13 | The API additions agents ask for first — sleep, raw samples, workout series, State of Mind — and pagination on daily metrics. | S | Done: `/v1/metrics/daily` pages in days across the requested types (`limit`, `offset`, `nextOffset`) |

### AI layer (R-AI)

| # | Requirement | Pri | Status |
|---|---|---|---|
| AI-1 | `server/mcp`: a read-only MCP server over the product API, as a `stdio` binary and a streamable-HTTP Compose service. | M | Done |
| AI-2 | Setup docs for Claude Desktop, Claude Code, Cursor and ChatGPT, with the "how did I sleep this week" demo. | M | Done (`docs/ai.md`) |
| AI-3 | Export: `GET /v1/export` (CSV/JSONL) and a CLI. | S | Done (`tools/puls-export`) |
| AI-4 | `llms.txt` on the docs site and an `AGENTS.md` in the repository. | S | Done: both in the repository, and `site/` renders `llms.txt` at https://pulshealth.com/llms.txt with its links pointed at the rendered documents |
| AI-5 | ChatGPT custom GPT Action from `/openapi.json`. | S | Done (`docs/ai.md`) |
| AI-6 | `GET /v1/summary` as compact markdown to paste into any chat. | C | Done, plus `get_summary` on the MCP server |
| AI-7 | Opt-in raw-SQL MCP tool over a read-only role. | C | Dropped: `server/mcp` is a read-only client of the product API and never holds a database URL. SQL users have `psql` and `docs/database-guide.md` |
| AI-8 | The exploration notebook reframed as "analyze your data", with an LLM section. | C | Done (`notebooks/healthkit_database_exploration.ipynb`) |

### OSS hygiene (R-OSS)

| # | Requirement | Pri | Status |
|---|---|---|---|
| OSS-1 | `LICENSE` (Apache-2.0), `NOTICE`, `TRADEMARK.md`. | M | Done |
| OSS-2 | `SECURITY.md` with a private disclosure path. | M | Done |
| OSS-3 | `CONTRIBUTING.md` with DCO sign-off, `CODE_OF_CONDUCT.md`, issue and PR templates. | M | Done |
| OSS-4 | A root README for a stranger: what it is, quickstart, screenshots, protocol, AI demo, FAQ. | M | Done. |
| OSS-5 | No personal identifiers in the tree, enforced by a CI gate. | M | Done (`scripts/check-public-tree.sh`) |
| OSS-6 | `CLAUDE.md` split: public invariants and gotchas; private operations elsewhere. | M | Done |
| OSS-7 | Generic CI (`ci.yml`, `ios-ci.yml`, `advisories.yml`) and a release workflow that pushes images on tag. | M | Done |
| OSS-8 | `CHANGELOG.md` and tagged releases. | S | Done |
| OSS-9 | Map tile usage-policy note in the web README. | S | Done |

### App Store (R-STORE)

| # | Requirement | Pri | Status |
|---|---|---|---|
| STORE-1 | Privacy policy and support URLs on `pulshealth.com`; App Privacy "Data Not Collected". | M | Done (`/privacy`, `/support`) |
| STORE-2 | A throwaway review backend, its URL and token in the review notes. | M | Done (`docs/appstore/review-backend.md`) |
| STORE-3 | App name reserved, screenshots, and a description that says plainly where data goes. | M | Done (`docs/appstore/listing.md`) |
| STORE-4 | A TestFlight public link as the beta channel before the listing. | S | Skipped: the app went straight to the store |
| STORE-5 | Guideline 5.1.3: read-only HealthKit, no health data in iCloud, no advertising use, stated in the review notes. | M | Done |

## 4. Risks that remain

| Risk | Mitigation |
|---|---|
| HealthKit behaviour that looks like a bug (Watch latency, hourly step delivery, locked device, force-quit) turns into support load. | The README's FAQ, and the app's Background Activity screen, which explains skipped wakes. |
| App Review pushes back on the local-network ATS exception or on needing a server. | A review backend with credentials in the notes, and a plain description (`docs/appstore/`). |
| The ingest attack surface is public. | `SECURITY.md`, auth-failure rate limiting, the scoped database role, per-device tokens. |

## 5. Out of scope

- Android / Health Connect. The protocol is platform-neutral in shape, but
  the v1 type vocabulary is HealthKit identifiers.
- A hosted PulsHealth service open to anyone. The maintainer runs one
  invite-only instance of the viewer for family and friends, which is close
  to a shared self-hosted install, and the privacy policy describes it.
  Opening it to sign-ups would make the maintainer a vendor of personal
  health records — in the US the FTC Health Breach Notification Rule likely
  applies, the App Store "Data Not Collected" answer likely changes for those
  users, and email verification, password reset and account deletion become
  mandatory — so it needs a decision of its own, not a configuration change.
- Writing data back into HealthKit.
- Native non-HTTP sinks in the app (see D3).
