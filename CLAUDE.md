# CLAUDE.md — agent guide for Puls

Personal HealthKit → self-hosted Postgres sync. Five components, each with its own README
(architecture, wire format, performance numbers live there — read them before deep work),
plus two standalone CLIs and the public website:

| Path | What | Docs |
|---|---|---|
| `PulsHealthSync/` | Swift package (iOS 17+, Swift 6 strict concurrency): sync engine, transport, NDJSON encoding | `PulsHealthSync/README.md` |
| `PulsHealth/` | SwiftUI app wrapping the library: Explore (type pages with analysis charts and an aggregate preview), Export builder (server-less files), Sync (the Database screen, synced types, activity log), Settings; benchmark | `PulsHealth/README.md` |
| `server/` | Docker Compose: Go ingest/product APIs + PostgreSQL 17/TimescaleDB + Grafana | `server/README.md` |
| `server/mcp/` | Go MCP server (stdio + streamable HTTP) giving AI assistants read-only tools over the product API; talks only to the API, never Postgres | `server/mcp/README.md`, `docs/ai.md` |
| `web/` | Next.js self-hosted viewer, published as the fourth GHCR image. Reads Postgres directly: as the read-only `grafana` role (open, or one HTTP Basic password), or in accounts mode as `web_app`, limited by the database to the signed-in person's records. **Not** `site/`, which is the public marketing site | `web/README.md` |
| `tools/puls-export/` | Standalone Go module: CLI for the product API's `GET /v1/export` (streamed CSV/JSONL). Its own `go.mod`, stdlib only | `docs/export.md` |
| `tools/protocol-check/` | Standalone Go module: validates the `docs/protocol/fixtures/` corpus against the JSON Schemas. Own `go.mod`, own CI job | `docs/protocol/README.md` |
| `site/` | Next.js static export behind **pulshealth.com** (marketing pages, blog, knowledge-base viewer). Built with bun. **Not** `web/`, which is the self-hosted viewer | `site/README.md` |
| `knowledge-base/`, `blog/` | The site's content: 178 YAML HealthKit type files (clinical prose, ranges, sources) and the MDX posts + images | `knowledge-base/README.md`, `blog/BLOG_SYSTEM.md` |

[`AGENTS.md`](AGENTS.md) is the short, tool-agnostic version of this file for
an automated contributor (components, where the authoritative facts live, the
test command for each suite); [`llms.txt`](llms.txt) indexes the
documentation. Both point back here for the invariants below rather than
restating them — keep it that way. What is still outstanding is
[`docs/roadmap.md`](docs/roadmap.md), over the requirements in
[`docs/open-source-plan.md`](docs/open-source-plan.md).

## Build & test

```bash
# Library tests (Swift Testing)
cd PulsHealthSync && xcodebuild test -scheme PulsHealthSync \
  -destination 'platform=iOS Simulator,name=iPhone 17'
# After editing HealthTypeCatalog, regenerate docs/protocol/catalog.json, then
# web/lib/catalog.generated.ts (the comparison checks fail until you do):
cd PulsHealthSync && TEST_RUNNER_PULS_WRITE_CATALOG=1 xcodebuild test \
  -scheme PulsHealthSync -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PulsHealthSyncTests/CatalogVocabularyTests
cd web && npm run gen:catalog

# App: run `xcodegen` (brew install xcodegen) before the first build and after
# adding/removing/renaming files. PulsHealth.xcodeproj is gitignored: it
# carries DEVELOPMENT_TEAM from Config/Local.xcconfig, which xcodegen seeds.
cd PulsHealth && xcodegen && xcodebuild build -scheme PulsHealth \
  -destination 'platform=iOS Simulator,name=iPhone 17'
# App-hosted XCTest (HealthKit entitlement): the 378-combo aggregate matrix
cd PulsHealth && xcodebuild test -scheme PulsHealth \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# The whole stack from this checkout (docker-compose.yml alone pulls the
# published images). bootstrap.sh writes server/.env and prints the pairing
# block; `make up/down/logs/ps/migrate/baseline/pairing` wrap Compose.
scripts/bootstrap.sh --build                   # first run
make dev-up                                    # thereafter (compose.build.yml)

# Marketing site (bun, not npm; also make site-dev|site-build|deploy-site)
cd site && bun install && bun run lint && bun run build

# Self-hosted viewer (npm, not bun)
cd web && npm ci && npm run check:catalog && npm run lint && \
  npm run typecheck && npm test && npm run build

# Go unit tests, no DB. Each directory is its own module; none at server/.
cd server/ingest && go vet ./... && go test ./...
cd ../api && go vet ./... && go test ./...
cd ../mcp && go vet ./... && go test ./...   # against an httptest fake of the API
cd ../../tools/puls-export && go vet ./... && go test ./...

# Protocol corpus vs the JSON Schemas, then vs the Python reference receiver
# (each from the repository root)
cd tools/protocol-check && go test ./... && go run . ../../docs/protocol/fixtures/*.ndjson
python3 examples/receivers/python-sqlite/smoke_test.py

# Notebook, against a throwaway TimescaleDB it starts (needs Docker and psql)
pip install -r notebooks/requirements.txt && python -m pytest tests/test_healthkit_notebook.py -rs

# Integration tests: skipped without DATABASE_URL (CI's db-integration job
# runs them as the scoped roles). server/api also needs
# PULS_API_WRITE_INTEGRATION_TESTS=1; as a scoped role, set DATABASE_URL to it
# and ADMIN_DATABASE_URL to postgres.
cd server && docker compose up -d migrate      # db + schema, nothing else
cd ingest && DATABASE_URL="postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres" \
  go test -run Integration ./...
```

Device builds need a paid Apple Developer team (HealthKit + background-delivery
entitlements): set `DEVELOPMENT_TEAM` in `PulsHealth/Config/Local.xcconfig`.

## Invariants — do not break

- **Anchor-after-ack.** A type's `HKQueryAnchor` is persisted *only after* the server
  confirms the upload (`HealthSyncEngine` → `recordUploadedBatch`). Persisting earlier
  loses data on crash. Re-sending the same page is safe: every insert is
  `ON CONFLICT DO NOTHING` on sample UUID, so the pipeline is idempotent end-to-end.
- **Export never shares sync state.** Anchors and watermarks are keyed per type
  with **no destination dimension** and advance whenever the transport returns
  normally, so an export through the app's engine (or `ExportFileTransport`
  given to it) would silently record every exported sample as delivered.
  `HealthExporter.run` builds a throwaway `HealthSyncEngine` per run — its own
  `SyncStateStore`, `SyncEventLog` **and `WakeLog`** (the default one rewrites
  the app's real `wake-log.json`), an `InMemoryTokenStore`, a configuration
  with no server URL, token or identity (`ExportPlan.configuration`),
  `recentWindowFirst: false` — never calls `startObserving` or
  `syncAllEnabled` (the priority window would write recent buckets twice), and
  deletes its directory on every exit path. Failures come from the throwaway
  store's completion markers (`ExportPlan.failures`) and
  `HealthSyncEngine.unmappableSampleCounts`, since the engine only logs them:
  a throw leaves no files, a partial export returns `isComplete == false`.
  `ExportColumnTests` pins shared CSV columns to `docs/export.md`. **App side,
  which the privacy documents promise:** staged files live under
  `HealthExporter.stagingRoot` (temporary directory). `AppModel.init` clears it
  at launch, before any export can run (`removeAllExports()` must never run
  during one), with `ExportZipper`'s `CoordinatedZipFile…` scratch directories
  (`ExportZipTests` fails if iOS renames them); `ExportModel` clears it when
  another export starts, on Delete Export, and on the share sheet's
  `completed` — hence `UIActivityViewController`, not `ShareLink` (no
  completion callback). The tab exports its own `ExportDraft` (seeded once
  from `appliedConfig`) and requests Health access itself
  (`requestHealthAccessForExport`: skips undeterminable types, never the
  medication picker). Change any of that and `docs/privacy-policy.md`
  § Exports, `SECURITY.md`, the site's `/privacy` card and `docs/appstore/`
  change with it.
- **Every row belongs to a user.** `users` (`db/migrations/000_users.sql`,
  seeded with the default user) is the FK target of `user_id` on every data
  table. The client sends its user in the **`X-User-ID` header**
  (`SyncConfiguration.userID`, set by `HTTPSyncTransport`), *not* in the NDJSON
  body; ingest (`main.go`) defaults an absent header to the default user,
  `ensureUser`s whatever id arrives before any insert, and tags every row.
  `user_id` joins the conflict target where identity would otherwise collide
  (`activity_summaries` `(user_id, date)`, `aggregate_samples` `(series_id,
  bucket_start, user_id)`); UUID-keyed sample tables keep their UUID PK. The
  `{"profile":…}` line is the complete identity snapshot (null or omitted
  fields clear stored values), so the app sends an empty profile only to
  replace a non-empty one (`ProfilePayload.shouldUpload`) — otherwise a
  reinstall pairing with its old server wipes it. The product API settles one
  user per request (`user=<uuid>`, else `PULS_USER_ID`) in `scopeUser`
  (`server/api/main.go`, after `auth`) and passes it to every `Store` read
  explicitly. Another user needs `PULS_MULTI_USER` (default off: the static
  `PULS_API_TOKEN` is bound to nobody); off, it is **403 `multi-user reads are
  disabled`**, never a quiet default-user answer, and neither that nor a
  malformed id (400) charges the auth limiter. A per-device ingest token
  (`device_tokens`) is bound to its user — `X-User-ID` absent or equal, else
  403; the shared `PULS_TOKEN` (while `PULS_ALLOW_SHARED_TOKEN`, default true)
  is not, so with it `X-User-ID` is unauthenticated tenant selection. Details:
  `server/README.md`, "Product API" and "Tokens".
- **Canonical units.** Every quantity type has one `unitString` in
  `HealthTypeCatalog`; `SampleMapper` converts before encoding. Never send raw
  device units. **A wrong one is silent:** `SampleMapper.map` returns nil for a
  quantity incompatible with the unit, and compatibility is per type, so one bad
  `unitString` makes every sample of that type unmappable. So **"drained" is a
  raw-count question, never a mapped-count one** — `result.addedSamples.count`,
  not `samples.count`; `MergedPage.isRawEmpty`, not `isEmpty` — or such a type
  reports zero samples, drained and backfill complete, with no error. Both
  sweeps log any drop (`HealthSyncEngine.runSync`, `MergedSync`), and a type
  that dropped anything is never marked backfill-complete.
- **The bearer token has a second home, and it is load-bearing for the privacy
  claims.** Normally it lives only in the Keychain (`writeSnapshot` strips it,
  `SyncConfiguration.encode` omits it). **When a Keychain write fails** it is
  parked in `sync-state.json` under `PersistedState.fallbackAuthToken`, retried
  on the next launch and removed once the Keychain accepts it — dropping it
  instead stalls every sync until the user retypes it. That file is
  `.completeUntilFirstUserAuthentication` and backup-excluded
  (`ProtectedStateFile`), which keeps a parked token off iCloud and other
  devices. Anything that changes where the token can rest, removing this
  fallback included, changes `docs/privacy-policy.md`, `SECURITY.md` and the
  site's `/privacy` page with it.
- **One type vocabulary.** `HealthTypeCatalog.swift` is the only hand-written
  list of types. `CatalogVocabularyTests` renders `docs/protocol/catalog.json`
  from it (and otherwise fails on any byte of drift), and
  `web/scripts/gen-catalog.mjs` renders `web/lib/catalog.generated.ts` from the
  JSON (`check:catalog` in CI). Never edit either generated file, and never
  restate a type in `web/lib/catalog.ts`, the web-only overlay. Catalog OS
  gates are declarative (`minimumIOS`), not `#available`, so `definitions` is
  complete on every runtime and `all` is the available subset. Likewise
  `PulsHealth/Sources/Resources/knowledge.json` is generated from
  `knowledge-base/**/*.yaml` by `scripts/gen-knowledge-json.py` (checked by
  `scripts/check-knowledge-json.sh` in CI) — never edit it by hand.
- **Epoch-ms dates everywhere.** Wire format, state files, and query params use
  millisecondsSince1970 (`JSONEncoder.puls` / `JSONDecoder.puls`). Not ISO 8601.
- **Wire format changes touch both sides.** `Models/SyncModels.swift` (incl.
  `AggregateSampleRow`) + `Serialization/NDJSONEncoder.swift` on the client stay
  in lockstep with `server/ingest/parse.go` + `store.go` and the schema in
  `server/db/migrations/`; update the fixtures in `parse_test.go` and the curl
  example in `server/README.md` too. **The protocol documents change in the
  same PR:** `docs/protocol/README.md` (the spec), the JSON Schemas in
  `docs/protocol/schema/`, the fixture corpus in `docs/protocol/fixtures/`
  (with `.expected.json` counts) and, for a catalog change, the two rendered
  vocabulary files above. `tools/protocol-check` runs the corpus against the
  schemas in CI and `examples/receivers/python-sqlite/smoke_test.py` posts it to
  the Python reference receiver, so both fail until they agree. The header's
  `schemaVersion` (and `X-Puls-Protocol`) is bumped **only for incompatible
  changes** — anything a v1 receiver written from the spec would reject,
  including new sample kinds and new line types; new optional fields, type
  identifiers and read endpoints are additive and keep the number. Deploy
  server-first: an old server 400s batches carrying new line types (the client
  doesn't retry 4xx, so nothing is lost, but syncing stalls until it updates).
- **Aggregates overwrite; raw samples never do.** Aggregate buckets
  (`Engine/AggregateSync.swift`) have no UUIDs: identity is (type, func,
  interval, deviceFilter, bucketStart, user_id), and the server **upserts**
  (`aggregate_samples` `ON CONFLICT DO UPDATE`); empty buckets go out as
  explicit `"value":null` so recomputes clear stale values. The per-config
  `computedThrough` watermark advances only after ack; every run recomputes a
  trailing lookback (late Watch data), and a ~monthly full pass repairs older
  edits. **The priority window** (`syncRecentAggregates`,
  `AggregatePass.priority`: ~30 recent days ahead of a first backfill's raw
  sweep) **uploads without advancing a watermark**
  (`recordAggregateUploadWithoutWatermark`): its chunks end near *now*, so
  recording them would push `computedThrough` (and `fullRecomputeThrough`) past
  all unprocessed history. Keep any future bounded pass on that recorder.
- **Activity rings upsert by date; they are not samples.** `HKActivitySummary`
  (`Engine/ActivitySummarySync.swift`) has no UUID, one row per local day, and
  today mutates all day. It rides its own `{"activitySummary":…}` line; the
  server **upserts** on `(user_id, date)` (null columns overwrite); progress is
  a *singleton* `computedThrough` day watermark
  (`SyncStateStore.activitySummaryState`) advanced only after ack, today
  re-queried every run. `validKind` rejects it as a sample kind.
  `HKActivitySummaryType` is an `HKObjectType` (catalog `sampleType == nil`;
  the engine adds `HKObjectType.activitySummaryType()` to read auth itself)
  with **no observer or background delivery**, so it rides `syncAllEnabled` and
  `refreshActivitySummaryIfStale()` at the tail of every observer wake (at most
  hourly, `ActivitySummaryState.lastComputedAt`) — keep the latter: the
  scheduled path runs from the `BGProcessingTask` while the device is locked.
  Store the local `date` straight through, never UTC-shifted (the PK is a
  plain `date`), or a day splits across two rows.
- **`PULS_TIME_ZONE` must match the phone's zone.** Aggregate day buckets and
  ring dates are the phone's calendar days; the server's day boundary for
  `metric_daily` and every server-side daily query is `PULS_TIME_ZONE` (stored
  by `db/migrations/013_time_zone.sh`, exposed as `puls_time_zone()`, default
  UTC).
- **A locked device means HealthKit is unreadable.** Every query fails with
  `errorDatabaseInaccessible`, and iOS runs `BGProcessingTask` when the device
  is idle — overnight, locked. Check `ProtectedData.isAvailable` (or
  `engine.isHealthDataAccessible()`) before HealthKit work in any background
  path and skip cleanly, recording `WakeRecord.Outcome.skippedLocked`, not
  `.completed`. Never report the BG task itself as failed for this — that costs
  future scheduling opportunities.
- **Limited history access (iOS 27).** A type limited to *Past 30 Days* is
  readable only from a fixed date (`HKHealthStore.earliestAuthorizedSampleDate(for:)`),
  and older history reads as **empty**, never an error. Empty is destructive, so
  `ReadableHistory` clamps every pass the server overwrites or deletes from:
  every aggregate pass computes only buckets that *start* at or after the date,
  the rings start at the first whole readable day, and reconciliation compares
  from the date or throws `readableHistoryUnknown`. The raw sweep and the
  route/stream phases never overwrite and need no clamp. Each pass records
  `readableSince` in its state — optional, so 1.5 state files decode; never
  make it required. **Widening re-sweeps**, because an anchor taken under a
  limit never returns the older samples: `refreshReadableHistory` (at most
  every 15 min; forced by the app at launch, on foreground and after every
  permission sheet) resets a widened raw type's anchors and reopens its
  backfill; aggregate series, rings and enrichment reset on their next run.
  **A widening must be confirmed:** a type set to **None** also drops out of
  `earliestAuthorizedSampleDate(for:)`, exactly like Full Access, and treating
  that as widening resets an aggregate series to all nulls — so it counts only
  once HealthKit returns a sample (rings: a day) ending before the recorded
  date (`ReadableHistory.resolve`, `hasHistory`). A type a run holds is not
  touched, not even recorded, until released; ±1 day (DST) is the same date; a
  narrowing only records. Calls here time out after 10 s and fail closed (an
  aggregate or ring pass records `readableHistoryUnknown` and sends nothing).
  Never pass the API an empty set: it breaks the `healthd` connection (Cocoa
  4099). The API is iOS 27 SDK only and CI also builds with Xcode 26.5, so it
  is called **only** in `ReadableHistory.swift`, behind `#if compiler(>=6.4)`
  (Xcode 27) *and* `#available(iOS 27.0, *)`. Don't Allow on the history page
  throws `errorAuthorizationDenied`; `requestAuthorization` returns
  `.declined`, an answer, not an error.
  Details: `PulsHealthSync/README.md`, "Limited history access (iOS 27)".
- **Incremental sync merges types into one batch; backfill does not.**
  `syncTypes(_:reason:)` routes `.incremental` through `MergedSync`, packing
  one anchored page per type into shared uploads (`maxMergedBatchSamples`,
  default 1,000). **A page is never split across batches** (the budget is
  clamped up to `batchSize`), so one page is one ack and a failed upload leaves
  its pack's anchors untouched — keep `HealthSyncEngine.pack`'s no-split
  property (`MergedSyncPackingTests`). Backfill keeps the per-type path (full
  pages; four type pipelines overlap better). Reading ahead keeps
  anchor-after-ack: the up to `maxConcurrentTypes` merged packs in flight hold
  disjoint types (`ConcurrentUploadTests`), and the per-type path reads one
  page ahead in memory only, cancelled by a failed upload. **A backfill claims
  all its types up front** (`claimTypes`, then `sweep` releases each;
  `syncAllEnabled(.backfill)` before its first phase), or the observer wake
  Apply's registration triggers takes them down the merged path one upload at
  a time; a whole-history Apply also calls `expectBackfill()` before
  registering the observer, because the iOS 26 continued-processing task
  claims later still (observer wakes then leave those types alone for up to a
  minute). Details: `PulsHealthSync/README.md`, "How a sync runs".
- **Recent data first, on an anchor of its own.** A nil-anchor sweep returns
  history roughly oldest first, so every sweep entry point first runs a
  recent-window pass (`RecentSampleWindow`, `SweepPass.recent`) over types
  still backfilling: the last 30 days, through `TypeSyncState.recentAnchorData`
  from a fixed `recentWindowStart`. Its acks go through
  `recordRecentWindowUpload`, which moves that anchor only — never
  `anchorData`, `backfillComplete` or `totalSamplesExported` (the sweep sends
  and counts those samples later). The two anchors never stand in for each
  other: the stream's is read under a date-bounded predicate and would skip all
  older history. `markBackfillComplete` drops the stream. A destination where a
  repeated sample is a duplicate row, not a no-op, uses `recentWindowFirst:
  false`.
- **Work the app starts itself holds a background-task assertion**
  (`BackgroundExecution.run`): observer wakes, the foreground/Sync Now pass,
  Apply's inline backfill and Start Initial Backfill's fallback. When iOS's
  grace period ends the work is **cancelled, not frozen** (a frozen run keeps
  its types claimed): every sweep stops at a page boundary with acked anchors
  recorded and claims released, and the wake is logged `expired`. An observer
  wake whose types another run holds waits (`waitForRelease`, ≤25 s) rather
  than acknowledging HealthKit at once, and acknowledges from `onExpiration`
  if time runs out — the cancelled wake may be suspended before its `defer`,
  and three unacknowledged deliveries stop HealthKit waking the app. After
  expiry a sweep starts no further type (`addTaskUnlessCancelled`) and
  `syncAllEnabled` stops after phase 3. Never nest it inside a
  `BGTaskScheduler` handler: those have their own expiration, and a nested
  request would cut a processing task short at ~30 s.
- **The schema is applied by the `migrate` service, never by hand.**
  `server/db/migrate.sh`, a one-shot Compose service that runs before every app
  service on each `docker compose up -d`, applies `db/migrations/` in lexical
  order and records each file's checksum in `schema_migrations`. New DDL is a
  new `NNN_name.sql`; an applied file is immutable (a changed checksum or a
  missing recorded file aborts the run, and the app services do not start).
  First-line exceptions: `-- puls:rerun` (re-applied whenever it changes —
  `009_metric_daily.sql`, `010_category_labels.sql`) and
  `-- puls:no-transaction` (statement by statement — `008_quantity_rollups.sql`,
  for `refresh_continuous_aggregate`). `*.sh` files (`013_time_zone.sh`,
  `099_read_roles.sh`) run every time from `.env` values, so rotating a
  database password or changing the zone is "edit `.env`, `docker compose up
  -d`". A database with the schema but no `schema_migrations` is refused until
  `docker compose run --rm migrate baseline`. DDL on a live database is one-way:
  `make backup` first. See `server/README.md`, "Schema migrations".
- **Actors.** `HealthSyncEngine`, `SyncStateStore`, and `SyncEventLog` are actors
  under Swift 6 strict concurrency (`BackgroundSyncScheduler` is a `Sendable` final
  class). Views call them via `@MainActor` `AppModel`.
- **iOS version gates.** State of Mind / effort scores / sleep apnea are
  `#available(iOS 18, *)`; medication doses and `BGContinuedProcessingTask` are
  `#available(iOS 26, *)`. Gate new type support the same way. An API that
  exists only in an SDK newer than CI's oldest Xcode also needs a compile guard
  — `#if compiler(>=6.4)` for the iOS 27 SDK; `#available` alone does not
  compile against the older SDK.
- **First run only, it applies nothing until the last page, and its Health
  page cannot be skipped.** `OnboardingView` covers `RootView` while
  `AppModel.showsOnboarding` is true — decided synchronously in `init` from the
  durable `onboardingCompleted` and `authorizationRequested` flags (no flash of
  an unconfigured tab), corrected in `startBody` from the stored configuration:
  an install with a database, types or a prior Apply must **never** see it.
  Four pages in a paging horizontal `ScrollView` (a paged `TabView` swallows
  the drag past its last page). The draft holds `TypePresets.common`
  (`preselectCommonTypesIfUnset`); only Start Exploring applies it
  (`finishOnboarding()` → `applyConfiguration(syncNewTypes: true)`). **Page 2
  is the pre-permission screen App Review judges under guideline 5.1.1(iv)**:
  one neutral Continue, no skip. Until `onboardingHealthAccessPending()`
  reports nothing left to ask (it awaits `start()`, since an empty draft reads
  as settled) the pager holds only pages 1–2; Continue or a swipe past page 2
  (`onPullPastEnd`, iOS 18+) presents the sheet, and any answer, Don't Allow
  included, moves on. Never add a page, link or gesture that reaches page 3
  around that. The medication picker is scheduled after the cover is down,
  never awaited (see Gotchas); a pairing link accepted during the flow waits
  in `confirmedPairing` until then (`pairingAwaitsSyncTab`), when RootView
  opens Sync → Database with it.
- **`site/` reads its content by relative path:** `knowledge-base/`
  (`site/src/lib/api.ts`), `blog/` (`site/src/lib/blog.ts`, `copy-blog-images`
  in `site/package.json`) and the eleven repository markdown files in the
  `site/src/lib/docs.ts` manifest (rendered at `/docs/<slug>/`; never edit the
  markdown for the site). Move or rename any of them and the build **still
  succeeds** with fewer pages, so the `site` CI job asserts the counts: one
  type page per tracked YAML file (178), one per `blog/articles/*.mdx`, one per
  manifest entry (`manifest=11` in `ci.yml` moves with the manifest). Keep that
  check honest; don't loosen it.
- **The app is shipped software, not a source drop.** It is on the App Store as
  [PulsHealth](https://apps.apple.com/us/app/pulshealth/id6757657354), so the
  privacy policy, listing copy and entitlements describe a binary people run.
  `docs/appstore/` is a **record** of what shipped and the material for the
  next submission, which starts from its README's § Release record. The store
  record's bundle ID `com.pulsHealth.PulsHealth` is immutable, so
  `project.yml`'s `bundleIdPrefix` (`com.pulsHealth`) is fixed: only an archive
  carrying it updates the listing. `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` stay ahead of every upload: 1.6 (19) is on the
  store (released 2026-10-01), so the next upload needs build 20 and a version
  above 1.6.
- **The published privacy claims are load-bearing.** `docs/privacy-policy.md`,
  `docs/appstore/` and the site's `/privacy` page state as fact that the app
  has zero third-party dependencies, sends data only to the configured server,
  never writes HealthKit, keeps the token in the Keychain, and stores no health
  samples on the device — except an export the user asked for, staged in the
  temporary directory until it is shared. A change to any of those — a
  dependency, a new outbound request, a new permission, a new on-disk store —
  updates those documents in the same pull request, and the App Store listing's
  privacy answers with them (`docs/appstore/README.md` has the table).

- **The web viewer's accounts mode: the database decides what a signed-in
  person can read.** With `WEB_ACCOUNTS=true` the viewer connects as
  `web_app`, which has **no grant on any table holding health data**; it
  reads them only through the security-barrier views in schema `web`
  (`015_web_accounts.sql`), each filtered on `puls_viewer_user()`, the
  transaction-local `puls.user_id` that `scoped()` (`web/lib/db.ts`) sets
  from the session. So every health read goes through `scoped(userId, q =>
  …)` and issues statements through its `q` only (a `query()` or nested
  `scoped()` inside takes a second pooled connection and can deadlock the
  pool; `queries.test.ts` checks); a query without its own `WHERE user_id`
  still returns one person's rows, and one without the setting returns
  none. Row-level security is not the mechanism: TimescaleDB refuses it on
  hypertables with columnstore enabled. `web_app`'s `search_path` is `web,
  public`, so the same SQL names the views as `web_app` and the tables as
  `grafana` — no table-name switching in the viewer. `099_read_roles.sh`
  rebuilds the views every run (`puls_create_web_views()`, so a CASCADE or a
  column change heals on the next `up -d`) and asserts the exact grant set,
  the exact set of views, and that `web_app` can read no relation with a
  `user_id` outside `web`/`auth`; a relation the viewer newly reads is a new
  migration replacing that function plus a `GRANT` and expected rows there.
  `sources` is a scoped view too (device names and app bundle ids are
  per-person). In accounts mode the viewer serves no data as any role that
  can read the tables directly. `web/lib/webapp.integration.test.ts` and
  `accounts.integration.test.ts` (db-integration CI job) prove it.
- **The viewer never identifies a user from a cookie it did not sign.** In
  accounts mode the user is the session row's (`auth.sessions`, looked up
  from the `__Host-puls-session` cookie by `proxy.ts` *and* again by
  `viewerUser()` per request); `?user=`, the `puls-user` cookie, the
  switcher and `/api/user` mean nothing there, and `getUsers()` is never
  called. Basic and open mode are untouched — same `grafana` role, same
  switcher — and one image serves all three modes (`web/lib/mode.ts`).
  Accounts mode refuses plain HTTP (403, except `/api/healthz`), checks
  `Origin` on every state-changing request, and throttles failed sign-ins
  with the ingest/API failure-only bucket, keyed per address and per email —
  but the token is taken *before* the scrypt check and refunded on success
  (`takeAll`/`refundAll`), or parallel guesses all pass the check first;
  never charge on a GET (an `<img>` can trigger one). `safeReturnPath`
  checks the *parsed* path too: `/.//x` parses to `//x`.
- **Account identity lives in `auth.*`, never in `users`.** `users.name` and
  `users.email` are the phone's HealthKit profile, overwritten by every
  `{"profile":…}` line. Accounts are invite-only (`make web-invite`); an
  invite for a user with an account resets its password.
- **The viewer never issues or displays an ingest token**, in any mode (no
  pairing QR code in `web/` either). Pairing a phone is the operator's step
  (`make issue-device`).

## Gotchas

- `HKQueryAnchor` blobs are opaque NSKeyedArchiver data — never inspect or
  synthesize them; reset state instead (`Settings → Reset All Anchors`).
- A type the permission sheet will not list stays `.shouldRequest` forever, and
  requested alone it flash-dismisses the sheet — iOS 26 does this to blood
  pressure (FB22735935, fixed in iOS 27.0; the BP correlation type cannot be
  requested instead). So `AppModel` remembers undeterminable types per session
  (`undeterminableTypes`), skips them in later requests and points at Settings
  → Privacy & Security → Health, naming the iOS 26 bug only below iOS 27. Keep
  it: it is version-agnostic and self-heals (retried each launch).
- Statistics queries crash on illegal option×type combos: HealthKit raises an
  uncatchable NSInvalidArgumentException when the query *executes*, not when it
  is built. Only ever offer or construct functions from
  `HealthTypeCatalog.allowedAggregateFunctions(for:)` (derived from
  `aggregationStyle`), verified against all 378 type×function combos by
  `PulsHealth/HostedTests/AggregateMatrixTests` (ObjC exception catcher +
  legacy `execute()`); re-run it on each new iOS runtime.
  Settings → Validate Aggregate Functions checks the legal set on-device.
- Never add `workoutEffortScore`/`estimatedWorkoutEffortScore` to the catalog or
  any read-authorization request: iOS refuses to show them in the permission
  sheet (FB15315876), leaving the request stuck at `.shouldRequest` and making
  the sheet flash-dismiss, which blocks grants for every other pending type.
  Effort scores ship attached to workout payloads via `SeriesEnricher` instead.
- The iOS 26 medication picker (`requestPerObjectReadAuthorization`) presents
  over whatever HealthKit view controller is on screen; asked while the bulk
  sheet is still tearing down, it never appears and the call **never
  returns**. So `AppModel.scheduleMedicationAccessRequest()` starts it without
  awaiting, after the onboarding cover is down and the bulk sheet has settled,
  with a watchdog that logs when it never appears. Keep per-object requests off
  Apply's awaited path.
- iOS silently throttles "immediate" background delivery to ~hourly for
  steps/energy/distance, and Watch→iPhone sync can't be forced. Latency complaints
  are usually iOS behavior, not bugs — see the latency table in the root README.
- `quantity_samples` chunks >30 days old are columnstore-compressed (segmentby
  `type_id`, orderby `start_ts`). DELETE/UPDATE against them must be prunable —
  include `start_ts` (and ideally `type_id`) in the predicate, never bare
  `uuid` — or TimescaleDB trips its per-transaction decompression limit
  (SQLSTATE 53400 → 500s, sync stalls). `InsertBatch` lifts the limit via
  `SET LOCAL` as a safety net; `TestIntegration_DeletionsOnCompressedChunk`
  guards the deletion path.
- Reconciliation (digest/UUID repair) covers only quantity/category/workout
  kinds, and **never deletes from a month HealthKit returned nothing for**
  (`ReconcileDigest.orphanVerdict`): read denial is undetectable —
  `authorizationStatus(for:)` speaks only for writes, and a denied type
  answers every query empty without an error — so an empty month is treated
  as unreadable, not as cleared, unless iOS 27 has just listed the type with
  an earliest readable date (`ReadableLimit.isConfirmed`). A run that reads
  nothing anywhere throws `reconciliationUnreadable`.
- The ingest container is distroless: no shell, debug via `docker compose logs ingest`.
- `server/mcp` is a read-only client of the product API (`server/api/docs.go`
  is its contract) and must stay one: no database URL, no writes, every tool
  annotated read-only. Its tool descriptions and embedded `guide.md` spell out
  units, the time-zone rule and the double-counting rule for the model — update
  them with any change to the API's shapes. `PULS_TIME_ZONE` must be handed to
  it separately (the API does not report its zone). In stdio mode stdout is the
  transport: never print to it; logs go to stderr.
- Grafana datasource UID `puls-tsdb` is hardcoded in dashboard JSON — keep it stable.
- Debounces are intentional: state persist 250 ms, event-log save 1 s. Synced Data
  edits are not debounced — they are staged in `AppModel.config` and reach the
  engine only when the user taps Apply (`applyChanges`).
- **Public tree.** This repository is public: no personal identifiers, hostnames,
  e-mail addresses, Apple Team IDs or credentials in tracked files (`.env`,
  `PulsHealth/Config/Local.xcconfig` and `PulsHealth/PulsHealth.xcodeproj` are
  gitignored for exactly this reason). CI runs `scripts/check-public-tree.sh`,
  which fails on the known identifiers — keep examples generic (`<host>`,
  `<user>`, `YOUR_PASSWORD`).
- The `web` viewer's data pages are `export const dynamic = "force-dynamic"`.
  Don't reintroduce `revalidate`/ISR on them — it bakes a DB-less demo render
  at build time and serves it stale after deploys. **Demo data is dev-only:**
  `web/lib/queries.ts` gates it on `ALLOW_DEMO = NODE_ENV !== "production"`
  (the container sets `production`), so an unset or unreachable DB shows the
  `"error"` source ("Database unavailable"), never demo data.

## Deployment

The reference stack (`server/docker-compose.yml`) runs on any Docker host;
`server/README.md` covers configuration, ports, tokens, upgrades and backups.
The maintainer's own production operations live outside this repository —
nothing here assumes a particular machine.

- **The four app services run published images, not local builds**
  (`ghcr.io/pulshealth/<name>:${PULS_VERSION:-latest}`, no `build:` block);
  the overlay `server/compose.build.yml` builds them instead, tagged
  `pulshealth-<service>:dev` so a local build never looks like a release. A
  Dockerfile, build-context or build-arg change touches that overlay, the
  `images` job in `ci.yml` and the build matrix in `release.yml`. The checkout
  must be on the release `PULS_VERSION` names: the compose file and
  `db/migrations/` (which `migrate` mounts) come from it.
- CI: `ci.yml` (Go vet/tests, lint, shellcheck, `check-public-tree.sh`,
  `docker compose config` over **both** compose variants, the `images` build
  for `linux/amd64`) and `ios-ci.yml`. `release.yml` publishes multi-arch
  images to `ghcr.io/pulshealth` on `v*` tags and `workflow_dispatch` (which
  never moves `latest`). There is no deploy workflow.
- **Backups are opt-in** (the `backup` Compose profile; `make backup`,
  `make restore FILE=…`): until they are on, the Postgres volume is the only
  copy, and only the restore drill in `server/README.md` verifies a backup.
  TimescaleDB restore rules (`server/backup/restore.sh` enforces them; a
  hand-restore must too): `timescaledb_pre_restore()`/`timescaledb_post_restore()`
  around it, never `pg_restore -j`, and drop the old `public` schema *before*
  `pre_restore`, reinstalling the extension the drop takes with it.
- Ingest connects as the scoped DML-only `ingest` role (`INGEST_DB_PASSWORD`
  required; `099_read_roles.sh` keeps the role's password equal to it), never
  as the superuser; `INGEST_DB_USER=postgres` is the discouraged way back.
- Ingest publishes 8080 on `${INGEST_BIND_ADDR:-127.0.0.1}`, assuming a TLS
  proxy. Only `scripts/bootstrap.sh --lan` writes `0.0.0.0`, on request, for a
  phone on the same Wi-Fi over plain `http://`, which the app's ATS exception
  allows only for local-network hosts (`ServerURLValidation.isLocalNetworkHost`).
  Keep the two rules in step, and keep the loopback default.
- The product API binds `127.0.0.1`. The `web` login is **optional, off unless
  `WEB_AUTH_PASSWORD` is set** (`web/proxy.ts` over `web/lib/auth.ts`: HTTP
  Basic, any username, `/api/healthz` exempt, constant-time, nothing logged);
  it is not TLS, so `web` still binds `WEB_BIND_ADDR` (default `127.0.0.1`) and
  reads Postgres as the read-only `grafana` role. Accounts mode
  (`WEB_ACCOUNTS=true`, `WEB_DATABASE_URL` pointing at `web_app`) is the one
  meant for the internet, behind a TLS proxy with `TRUST_PROXY_HEADERS=true` —
  the optional `tunnel` Compose profile (a Cloudflare Tunnel to
  `http://web:3000`, `COMPOSE_PROFILES=tunnel` in `.env`) is the documented
  way; `WEB_BIND_ADDR` stays on loopback either way.
- **Ingest and the product API throttle failed authentications, never
  successful ones** (`server/ingest/ratelimit.go`, `server/api/ratelimit.go` —
  copies across two modules; keep them in step). The refusal comes *before*
  the token comparison, or it would change only the status code, not the
  guessing rate; successes never draw, because a backfill is thousands of
  requests. `TRUST_PROXY_HEADERS=true` keys on `X-Forwarded-For` and, on the
  API, lets `X-Forwarded-Host` pick the host the unauthenticated
  `/openapi.json` advertises. Limits: `server/README.md`, "Rate limiting".
- **Ingest auth** (`server/ingest/auth.go`): the limiter, the shared token in
  memory, then the bearer's unsalted SHA-256 (the preimage is 256 random bits)
  in `device_tokens`. A database error there is **503 `authentication
  unavailable`, never 401**, and not charged: the app treats 401 as terminal,
  so it would stall until the user retyped a correct token. Only wrong
  credentials charge the limiter; a user mismatch (403) does not.
  `099_read_roles.sh` revokes `grafana`'s default-privilege SELECT on
  `device_tokens` every run; `api_reader` is an exact grant list asserted by a
  `DO` block, so a table the product API newly reads goes on BOTH the `GRANT`
  and the `expected_public` rows. `PULS_TOKEN` is optional; do not make it
  required again.
- **`/healthz` is unauthenticated on both services, so it must not touch the
  pool per request** (`server/ingest/health.go`, `server/api/health.go` — again
  copies): the database status is cached for two seconds and concurrent
  callers share one probe, or a loop of GETs holds every pooled connection.
