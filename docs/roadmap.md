# Roadmap — what is left

Reviewed 2026-10-01, after the app's 1.6 reached the App Store, and pruned the
same day to what is worth doing. This is what is still outstanding, roughly in
the order worth doing it; what was considered and dropped is under **Not
planned** at the end, with the reason, so it is not proposed again without
something new. Requirement IDs (OSS-4, APP-11, …) tie items to
[`open-source-plan.md`](open-source-plan.md), which records the decisions
behind them.

## 1. The next app release

1.6 (19) is on the store. The next upload needs a `MARKETING_VERSION` above
1.6 and build 20 or later (`PulsHealth/project.yml`).

- **Device passes never run on hardware for 1.5 or 1.6:** background sync
  over several days; the iOS 26 continued-processing first run; leaving the
  app mid-backfill; an export on a device; and on iOS 27, limiting a type's
  history, widening it again, and the re-sweep that follows.

## 2. Standing maintenance

Not backlog — things that come due on someone else's schedule.

| Trigger | Do this |
|---|---|
| A new iOS runtime | Re-run the app-hosted `AggregateMatrixTests` (378 type×function combos): the legal set is HealthKit's, not ours. |
| A major Xcode/iOS SDK update | Refresh `010_category_labels.sql` from `HKCategoryValues.h` and check the seed shape (`server/README.md`). |
| Never yet done on real data | The backup restore drill. The one recorded in `server/README.md` ran against a throwaway stack; nothing else verifies that a dump restores. |
| Publishing images from a new organization or a fork | A package `release.yml` creates starts private, and it can be made public only once the organization's package-creation policy allows public packages. Change the policy first, then flip each of the four in its package settings. |
| A schema migration that is not additive | The quickstart clones `main`, which between releases can carry migrations the `latest` images have not caught up with. Harmless while every migration is additive; before one is not, point the quickstart at the release tag. |
| Dependabot re-proposes eslint 10 or TypeScript 7 for `web`/`site` | Check upstream, then close against [#37](https://github.com/PulsHealth/pulshealth/issues/37). Both blockers are `eslint-config-next`'s own dependencies: `typescript-eslint` refuses TS >= 6.1 ([typescript-eslint#10940](https://github.com/typescript-eslint/typescript-eslint/issues/10940)), and `eslint-plugin-react` still calls `context.getFilename()`, which ESLint 10 removed. Still true against `eslint-config-next` 16.3.8 (2026-10-01). |
| A red `advisories` workflow run | Bump the dependency in its own pull request. `advisories.yml` is separate from `ci.yml` so it can go red without blocking a merge or a release; its header says when it runs and why. |

## Not planned

Decided 2026-10-01.

- **Leaving out a new aggregate series' leading empty buckets** (PR #70,
  closed). It saves only the first backfill, because the 30-day full
  recompute resends those nulls anyway. And a series that is new to the phone
  is not necessarily new to the server: a reinstall, or an aggregate deleted
  and added again with the same series identity, would leave stale server
  values until the next full pass.
- **A reinstall that sends only what the server lacks.** A reinstall re-reads
  its whole sync window and re-sends it; the server ignores what it has (one
  re-sent about 1.3M samples, 98% already there). Avoiding that means a first
  sync that drains the anchored query without uploading, reconciles against
  `GET /v1/digest`, then stores the anchor and marks the backfill complete —
  new anchor handling in the code with the most invariants, plus an
  upload-only reconcile, for a one-time saving on a rare event.
- **Device tokens by default, and phone-side enrollment** (SRV-8). Per-device
  tokens are there for whoever wants a revocable token per phone (`make
  devices`, `scripts/bootstrap.sh --issue-device`). As the default they would
  cost `make pairing` its re-print, since only a hash is stored, for no gain
  on a one-phone install. Enrollment (`POST /v1/devices/enroll`, approved on
  the server) would add an unauthenticated endpoint and an app release to
  replace pairing by QR code, which already works.
- **A per-user read token for the product API** (SRV-11). Multi-user reads are
  off by default (`PULS_MULTI_USER`), and no household has asked for one.
- **Alternative sinks** (APP-11). `HealthSyncEngine.buildTransport` hardcodes
  `HTTPSyncTransport`, and a transport set with `setTransport` lives only in
  memory, so a cold background launch rebuilds HTTP from the persisted URL
  and token. Persisting the sink choice and putting the read side behind a
  protocol is worth doing only once a second sink exists.
- **Scheduled or automatic export.** An export runs only when the user taps
  Export, in the foreground, with the phone unlocked, and always reads its
  whole range. An App Intent (which Shortcuts automations could run) would
  first have to answer three things: HealthKit is unreadable while the phone
  is locked, which is when automations tend to fire; an intent needs a
  durable place for the files, which the share sheet decides today and the
  privacy policy promises the app does not keep; and the staging directory's
  clear-at-launch rule must not delete an export an intent is writing.
- **A real-device screenshot set with real data** (OSS-4). Simulator shots
  from the demo fixtures show the same screens without anyone's health data.
