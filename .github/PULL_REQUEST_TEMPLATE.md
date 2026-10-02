## What

<!-- One or two sentences: what changes, in which component. -->

## Why

<!-- The problem this solves, and a link to the issue or plan item if there is one. -->

## Checklist

- [ ] Every commit is signed off (`git commit -s`) — see the DCO section of `CONTRIBUTING.md`.
- [ ] Wire format **unchanged**, or changed on **both sides** in this PR: client models + NDJSON encoder, server parser + store, schema file, `parse_test.go` fixtures, the `server/README.md` curl example, and the protocol spec, schemas and fixture corpus under `docs/protocol/` — and the description says the server ships first.
- [ ] Checks pass locally for every component touched (`go vet` + `go test`, `npm run lint`/`typecheck`/`test`/`build`, `xcodebuild test`).
- [ ] `PulsHealth/project.yml` changed → `xcodegen` re-run and the generated project builds (the `.xcodeproj` itself is gitignored, never committed).
- [ ] New DDL is a new `NNN_name.sql` under `server/db/migrations/` (never an edit to an applied file; `-- puls:rerun` only for CREATE OR REPLACE files), and `server/README.md` says when it must be applied relative to the ingest build.
- [ ] `scripts/check-public-tree.sh` passes.
- [ ] Docs updated where behaviour changed (component README, root README, `CLAUDE.md` invariants).
