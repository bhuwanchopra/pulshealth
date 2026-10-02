# Contributing to PulsHealth

Thanks for helping. This document covers the sign-off every commit needs, how
to get each component building, the rules that keep the app and the server in
step, and what to run before opening a pull request.

The iOS app is [on the App Store](https://apps.apple.com/us/app/pulshealth/id6757657354);
the self-hosted backend is pre-release (0.x). `docs/roadmap.md` lists what is
still outstanding. For anything bigger than a bug fix, open an issue first so
the design can be agreed before the code exists.

## Developer Certificate of Origin

Every commit must be signed off. Signing off is how you certify the
[Developer Certificate of Origin](https://developercertificate.org/): that you
wrote the change or otherwise have the right to submit it under the project's
Apache-2.0 license, and that you understand the contribution is public. There
is no CLA.

Add the sign-off with `-s`:

```bash
git commit -s -m "ingest: reject batches whose header count exceeds the line total"
```

which appends a trailer to the commit message:

```
Signed-off-by: Your Name <you@example.com>
```

Use your real name and a working email address. Forgot one? `git commit -s
--amend` fixes the last commit; `git rebase --signoff main` fixes a branch.

## Getting set up

Each component has its own README with architecture and details; this is the
short version. Everything runs from a checkout of this repository.

### `PulsHealthSync` (Swift package)

iOS 17+, Swift 6 strict concurrency, no dependencies. Tests are Swift Testing.

```bash
cd PulsHealthSync
xcodebuild test -scheme PulsHealthSync \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### `PulsHealth` (iOS app)

The Xcode project is **generated** by [xcodegen](https://github.com/yonaskolb/XcodeGen)
from `project.yml` and is gitignored (XcodeGen copies your Team ID into it),
so run `xcodegen` after cloning and again after adding, removing, or renaming
files. Never edit `project.pbxproj` by hand; project-level changes go in
`project.yml`.

```bash
brew install xcodegen
cd PulsHealth
xcodegen      # also seeds Config/Local.xcconfig from Local.xcconfig.example
xcodebuild build -scheme PulsHealth \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

`Config/Local.xcconfig` is gitignored and holds your `DEVELOPMENT_TEAM`.
Simulator builds work with it empty; device builds need a paid Apple
Developer team because of the HealthKit and background-delivery
entitlements. Never commit a Team ID.

The app-hosted tests need the HealthKit entitlement (they execute every
aggregate function × type combination against HealthKit) and are XCTest:

```bash
cd PulsHealth
xcodebuild test -scheme PulsHealth \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Go: `server/ingest`, `server/api`, `server/mcp`, `tools/`

Each is its own Go module. Unit tests need no database:

```bash
cd server/ingest && go vet ./... && go test ./...
cd ../api      && go vet ./... && go test ./...
cd ../mcp      && go vet ./... && go test ./...   # against a fake product API
cd ../../tools/puls-export && go vet ./... && go test ./...
```

The protocol corpus is checked against the JSON Schemas, then posted at the
Python reference receiver (both from the repository root):

```bash
(cd tools/protocol-check && go test ./... && go run . ../../docs/protocol/fixtures/*.ndjson)
python3 examples/receivers/python-sqlite/smoke_test.py
```

Integration tests are gated on `DATABASE_URL` and need the schema applied by
the `migrate` service — start that, not `db`. There is no module at
`server/`, so run them from the module directory. CI's `db-integration` job
runs them on every push.

```bash
cd server
cp .env.example .env            # fill in the secrets, see server/README.md
docker compose up -d migrate    # db + schema, nothing else
cd ingest
DATABASE_URL="postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres" \
  go test -run Integration ./...
```

The product API's fixture-writing integration tests additionally require
`PULS_API_WRITE_INTEGRATION_TESTS=1`; never point them at a database you care
about.

### `web` (Next.js viewer)

```bash
cd web
npm ci
npm run check:catalog           # lib/catalog.generated.ts matches docs/protocol/catalog.json
npm run lint && npm run typecheck && npm test && npm run build
npm run dev                     # demo data when DATABASE_URL is unset
```

### `site` (pulshealth.com marketing site)

Built with **bun**, not npm, and distinct from `web/`. It reads
`knowledge-base/`, `blog/` and eleven repository Markdown files by relative
path, so a moved file makes the build emit fewer pages instead of failing. CI
compares the built knowledge-base, blog and docs pages with their sources
(`site/README.md` has the details).

```bash
cd site
bun install
bun run lint && bun run build      # static export to site/out
bun run dev                        # localhost:3000
```

`make site-lint`, `make site-build` and `make site-dev` run the same things
from the repository root. If you edited `knowledge-base/`, validate it:

```bash
cd knowledge-base && python3 validate.py    # needs PyYAML and jsonschema
```

### Compose and shell

```bash
# Both variants, with the .env secrets exported: pulling the published
# images, and the developer overlay that builds them from the checkout.
docker compose -f server/docker-compose.yml config --quiet
docker compose -f server/docker-compose.yml -f server/compose.build.yml config --quiet
shellcheck server/db/migrate.sh server/db/migrations/*.sh scripts/*.sh
make dev-up                     # run the whole stack from this checkout
```

The `site` job in `ci.yml` builds the marketing site on its own — it is the
one thing here built with bun, and an unrelated site change must not gate the
server.

CI also builds the four app images for `linux/amd64` on every pull request
(`images` job), so a Dockerfile change is checked before it is merged.
`.github/workflows/release.yml` publishes them to `ghcr.io/pulshealth` on
`v*` tags and on manual runs; the image matrix there, the `images` job in
`ci.yml` and `server/compose.build.yml` must agree on contexts and build args.

## Rules that keep the pieces in step

`CLAUDE.md` at the repository root lists the project's invariants and gotchas
(anchor-after-ack, canonical units, epoch-milliseconds everywhere, why
aggregates upsert and raw samples never do, what a locked device means for
background work, and more). It is written for AI coding agents but it is the
best contributor documentation in the repository; read it before touching
the sync engine or the ingest path.

Two rules deserve repeating here because they cross component boundaries:

**The wire format changes on both sides at once.** Every change to the NDJSON
batch — a new line type, a new field, a changed unit — touches all of these
in the same pull request:

- client: `PulsHealthSync/Sources/PulsHealthSync/Models/SyncModels.swift` and
  `Serialization/NDJSONEncoder.swift`;
- server: `server/ingest/parse.go` and `server/ingest/store.go`;
- schema: a new `NNN_name.sql` under `server/db/migrations/`;
- tests: the fixtures in `server/ingest/parse_test.go`;
- docs: the curl example in `server/README.md`;
- protocol: the spec `docs/protocol/README.md`, the JSON Schemas in
  `docs/protocol/schema/`, and the fixture corpus in `docs/protocol/fixtures/`
  with its `.expected.json` counts (`tools/protocol-check` and the Python
  receiver's smoke test fail until they agree);
- for a catalog change (a new type, a changed unit): the rendered vocabulary
  `docs/protocol/catalog.json` and `web/lib/catalog.generated.ts`, both
  regenerated rather than edited (`docs/protocol/catalog.md`).

The header's `schemaVersion` (and `X-Puls-Protocol`) moves only for a change
a v1 receiver written from the spec would reject, such as a new sample kind or
line type; new optional fields, type identifiers and read endpoints keep it.
The server deploys first: an old server rejects batches carrying new line
types with a 400, and the client never retries 4xx and leaves its anchors in
place, so nothing is lost, but syncing stalls until the server is updated.

**Schema changes are new files; applied files are immutable.** The Compose
`migrate` service applies `server/db/migrations/` in order on every
`docker compose up -d` and records each file in `schema_migrations` with its
checksum, so new DDL goes in a new `NNN_name.sql` — never into a file that has
already been applied (the migrator refuses a changed checksum). Only files that
are `CREATE OR REPLACE` by design carry a first line of `-- puls:rerun` and are
re-applied when they change. Say so in `server/README.md` when a change must
land before the ingest build that depends on it (see "Schema migrations"
there).

## Before you open a pull request

- Run the checks for every component you touched (commands above). CI runs
  the Go, web, site, Compose, shell, and workflow checks on Ubuntu and the
  Swift package and app tests on macOS.
- If you changed `PulsHealth/project.yml`, re-run `xcodegen` and make sure
  the generated project still builds; `project.pbxproj` itself is not tracked.
- If you changed the wire format, walk the list above and tick the box in the
  pull request template.
- Run `scripts/check-public-tree.sh`. It fails on classes of private content
  (tailnet hostnames, personal mailboxes, home directories, Apple Team IDs);
  the same check runs in CI.
- Update the documentation that describes what you changed: the component
  README, the root README, or the invariants in `CLAUDE.md`.
- Sign off every commit.

Small, focused pull requests are reviewed faster than large ones. If a change
needs a schema migration and a client change, say in the description which
order they must ship in.

## Style

- **Swift:** Swift 6 language mode with strict concurrency; `HealthSyncEngine`,
  `SyncStateStore`, and `SyncEventLog` are actors and views reach them through
  the `@MainActor` `AppModel`. Gate new OS features with `#available` the way
  existing code does (iOS 18 for State of Mind and effort scores, iOS 26 for
  medication doses and `BGContinuedProcessingTask`); an API only in the iOS 27
  SDK also needs `#if compiler(>=6.4)`, because CI still builds with Xcode
  26.5. Only construct aggregate
  queries from `HealthTypeCatalog.allowedAggregateFunctions(for:)`; illegal
  combinations crash inside HealthKit.
- **Go:** `gofmt`, `go vet`, and the race detector clean. Dependencies are
  few and deliberate — `pgx` for the servers, `go-qrcode` in ingest, the MCP
  SDK in `server/mcp`, a JSON Schema validator in `tools/protocol-check` — so
  think twice before adding one.
- **TypeScript:** `eslint` with zero warnings and `tsc --noEmit` clean.
- **Shell:** `shellcheck` clean, `set -euo pipefail`.
- **SQL:** idempotent DDL, and predicates on compressed hypertables must
  include `start_ts` (see the gotchas in `CLAUDE.md`).
- Commit messages: a short imperative subject with a component prefix
  (`ingest:`, `app:`, `sync:`, `web:`, `site:`, `db:`, `docs:`), a body that
  says why.

## Reporting bugs and security problems

Use the issue templates for bugs and feature requests; there is also a
template for people implementing their own receiver for the sync protocol.
Read the FAQ in the root README first: most "the data is late" reports are
HealthKit behaviour, not bugs.

Security problems go through private vulnerability reporting, never the
issue tracker. See `SECURITY.md`.

This project follows the Contributor Covenant; see `CODE_OF_CONDUCT.md`.
