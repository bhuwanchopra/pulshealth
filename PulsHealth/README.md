# PulsHealth (iOS app)

SwiftUI front end for the `PulsHealthSync` library — all sync logic lives in the
package; this app is configuration, visibility, and lifecycle wiring. See
[`PulsHealthSync/README.md`](../PulsHealthSync/README.md) for the engine and
`CLAUDE.md` for the invariants.

Published as
[PulsHealth](https://apps.apple.com/us/app/pulshealth/id6757657354) on the App
Store (free). The listing material and the record of what shipped are in
[`docs/appstore/`](../docs/appstore/README.md).

## Project generation

`PulsHealth.xcodeproj` is **generated** from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is **not tracked** in git
(XcodeGen copies the signing team from `Config/Local.xcconfig` into the pbxproj,
so tracking it would leak every developer's team ID). Install XcodeGen once
(`brew install xcodegen`), then generate before the first build and again after
adding/removing/renaming files:

```bash
xcodegen && xcodebuild build -scheme PulsHealth \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Key settings (`project.yml`, `Info.plist`, `PulsHealth.entitlements`):

- Bundle ID `com.pulsHealth.PulsHealth`, iOS 17.0 target, Swift 6. It is the
  App Store record's identifier, which cannot change, so `bundleIdPrefix` is
  fixed and only an archive carrying it can update the app.
- Entitlements: `healthkit` + `healthkit.background-delivery` (device builds need a
  paid developer team).
- Signing is per-developer and untracked. `DEVELOPMENT_TEAM` lives in
  `Config/Local.xcconfig` (gitignored), which both targets pull in via
  `configFiles`; `xcodegen` (2.43+) seeds it from the tracked
  `Config/Local.xcconfig.example` on first run, or copy it yourself. Put your
  team ID there for device builds — simulator builds need none, so the empty
  template works as-is. Forks distributing their own build must also change
  `bundleIdPrefix` in `project.yml` and must not ship under the PulsHealth name
  (see `TRADEMARK.md` at the repo root).
- `UIBackgroundModes: processing`; the permitted BG task IDs are
  `$(PRODUCT_BUNDLE_IDENTIFIER).healthsync.catchup` and the
  `$(PRODUCT_BUNDLE_IDENTIFIER).backfill.*` wildcard, which covers the iOS 26
  continued-processing task `….backfill.run`. `BackgroundSyncScheduler`
  derives the same strings from `Bundle.main.bundleIdentifier`, so a fork with
  its own bundle ID changes nothing here.
- App Transport Security: `NSAllowsLocalNetworking` only — plain `http://` is
  reachable for local-network hosts (unqualified names, `*.local`, private IP
  ranges), everything else stays HTTPS-only — with the matching
  `NSLocalNetworkUsageDescription`. Settings enforces the same rule before a
  URL can be saved or tested.
- `PrivacyInfo.xcprivacy` (bundle root, listed as a resource in `project.yml`):
  no tracking, no collected data, and the one required-reason API the app uses
  — `UserDefaults` (CA92.1, the app's own flags). The `PulsHealthSync` package
  ships its own manifest for the same API (background-task schedule status).
- Usage strings declare read-only HealthKit access (the app never writes health
  data) and camera access for one purpose only — reading the pairing QR code
  (`NSCameraUsageDescription`).
- One URL scheme, `puls` (`CFBundleURLTypes`), for `puls://pair?…` pairing
  links — which is also what the iOS Camera app opens when it reads the
  server's QR code. An incoming link is never acted on directly; see "Pairing"
  under Behavior notes.

## Source map

Four tabs, each its own `NavigationStack`: **Explore** (the catalog, with the
Health-access cards), **Export** (files, no server needed), **Sync** (server,
status, synced types, activity) and **Settings**.

```
Sources/
├── PulsHealthApp.swift   @main. Registers BG tasks before launch finishes; scenePhase
│                         hooks: foreground → syncNow, background → schedule + persist.
│                         onOpenURL → AppModel.handleIncomingURL (puls:// links).
├── AppModel.swift        @MainActor @Observable coordinator. Owns HealthSyncEngine +
│                         BackgroundSyncScheduler; exposes statuses, events, server
│                         stats, config; stages type toggles until Apply; handles
│                         authorization (incl. iOS 26 per-object medication auth).
│                         Turns an incoming puls:// link into a prompt and, once
│                         accepted, a one-shot hand-off (confirmedPairing) to the
│                         Database screen. Decides whether the first run's
│                         Health page still has a sheet to show
│                         (onboardingHealthAccessPending). Clears the export
│                         staging directory at launch, and runs the export's
│                         Health-access step (applied selection, never the draft).
├── RootView.swift        TabView (Explore / Export / Sync / Settings). Owns the
│                         Sync tab's path so an accepted pairing link lands on
│                         Sync → Database; hosts the pairing and server-change
│                         prompts and presents OnboardingView on a first run.
├── Design/               The design system: TypeIcon (Health-style tile),
│                         CardSection, ChartCard (a chart with its controls
│                         and readout line), StatTile + StatusPill,
│                         ProgressBanner, EmptyState, and the
│                         Formatting helpers (byteString, compactString,
│                         shortDuration, relativeString).
├── ExploreView.swift     Home: the Health-access / reads-look-blocked cards
│                         (the latter with "Open Health Settings"), then
│                         every catalog type by category with search —
│                         types with data first, the sample count once
│                         analyzed. Categories collapse from their header;
│                         the toolbar menu expands/collapses all, hides
│                         types without data and sorts (Data First / Name /
│                         Most Recent), kept in UserDefaults; pull to
│                         refresh re-reads every type's facts. Every row
│                         opens its Type page
│                         (ExploreRoute.type), synced or not.
├── Explore/
│   ├── ExploreModel.swift  @MainActor @Observable, owned by AppModel: the
│   │                       per-type quick facts and TypeProfiles, read through
│   │                       the library's HealthExplorer (no engine, no sync
│   │                       state), the analyses in flight (one per type, over
│   │                       the past year, started the first time its page is
│   │                       opened; kept until Refresh), and
│   │                       deleteAll — what Settings → Privacy & Data → Delete
│   │                       Analysis calls. Profiles persist in TypeProfileStore.
│   ├── TypePageView.swift  The Type page: the analysis (started on open),
│   │                       stat tiles, the value distribution, samples over
│   │                       time, sources and devices, cadence; an aggregate
│   │                       preview (quantity types, after an analysis); and,
│   │                       for a synced type, the sync details
│   │                       (TypeSyncDetailsSections).
│   ├── ExploreCharts.swift The page's Swift Charts: the histogram (over the
│   │                       middle of the data, with the article's typical
│   │                       range behind it for discrete types), daily
│   │                       counts, sources.
│   └── TypeKnowledge.swift The slice of a knowledge-base article the page
│                           uses (one-line description, unit, typical range,
│                           category value names), decoded from the
│                           bundled knowledge.json (rendered from
│                           knowledge-base/ by scripts/gen-knowledge-json.py).
├── ExportView.swift      The Export tab as a builder: data types (a picker of
│                         its own), aggregate series (Add Series), a range (30
│                         days / 90 days / a year / all time, or a start and
│                         end date), CSV or JSONL, zipped or not, then
│                         running → result (totals, per-dataset rows, an
│                         "incomplete" section, what CSV left out) → a
│                         UIActivityViewController share sheet, whose
│                         completion is what deletes the staged copy.
├── Export/
│   ├── ExportTypePickerView.swift  Export → Data types: the Synced Data
│   │                       browser's shape (categories, per-category lists,
│   │                       search) with checkmarks rather than toggles, over
│   │                       the export's own draft — nothing chosen here
│   │                       touches the sync selection.
│   └── ExportAggregatesView.swift  The Add Series sheet (quick series as
│                           chips, then the full editor) and the draft's
│                           series rows.
├── ExportModel.swift     @MainActor @Observable, owned by AppModel: the draft
│                         (types, series, workout switches, range, format,
│                         zip — seeded once from the applied sync selection,
│                         then the export's own), the run in flight (progress,
│                         cancel, idle-timer and background-task assertion),
│                         the finished export, and the lifetime of its staged
│                         files. A run outlives the screen that started it.
├── SyncView.swift        The Sync tab. No database applied: a setup card ("Keep
│                         a copy in your own database") with one Set Up button
│                         (opens the Database screen). Otherwise the status
│                         card (host, last sync, backfill progress + ETA,
│                         failing count), the iOS 27 "Limited Health history"
│                         card while any applied type is readable only from a
│                         recent date, Sync Now, the synced types (TypeRow →
│                         TypeDetailView), pull-to-refresh and the error alert;
│                         then rows to Synced Data, Database and Activity. The
│                         PendingChangesBar sits on this tab.
├── ServerSettingsView.swift  Sync → Database: the Database URL and Token
│                         fields (validated: https, or http for local-network
│                         hosts only; held in a ServerFieldsDraft until Save &
│                         Apply, with Scan / Paste
│                         Pairing Code filling all three values) with Test
│                         Connection — runs against the entered, unsaved values
│                         and reports ok / no capabilities / token rejected /
│                         unsupported protocol / unreachable / server error.
│                         Collects an accepted puls:// link's payload.
├── ActivityView.swift    Sync → Activity: segmented Log / Background over
│                         LogView and BackgroundActivityView.
├── LogView.swift         Live filterable event stream (level + type filters).
├── BackgroundActivityView.swift  Field-study screen: per-wake telemetry from the
│                         library's WakeLog — wakes/24h & /7d, median background
│                         gap, expired/interrupted count, per-trigger rollups, a
│                         recent-wakes list, and a ShareLink that exports wakes
│                         (CSV+JSON) + the event log (JSON) for offline analysis.
├── TypePickerView.swift  Sync → Synced Data: ~80 types grouped by category;
│                         Common/All/None
│                         presets. Quantity rows link into TypeConfigView; other
│                         kinds keep plain toggles. Also PendingChangesBar.
├── TypeConfigView.swift  Per-quantity-type config: raw-sync toggle + aggregate
│                         series list, plus AggregateEditorView (function picker
│                         restricted to allowedAggregateFunctions, interval,
│                         device filter, start date, settle delay, status,
│                         Sync Now / Recompute All / Delete). Identity edits
│                         reset the watermark (different server series).
├── TypeDetailView.swift  Sync → type: a header (icon, name, activity) over
│                         TypeSyncDetailsSections — anchor/activity/rate/ETA,
│                         volume counters, timeline, server-side counts
│                         (GET /v1/stats) and the reconcile action, both shown
│                         only when the server's capabilities advertise
│                         `stats` / `digest` + `uuids`, plus reset. The Type
│                         page embeds the same sections under "Sync details".
├── SettingsView.swift    User row, Sync (start date, backfill trigger, reset
│                         all anchors — shown only once a server is applied),
│                         Performance (concurrency, batch size), Save & Apply
│                         (only while those or the User page have unapplied
│                         edits), Privacy & Data (Health Access, which opens
│                         the app's page in iOS Settings; delete a staged
│                         export; Delete Analysis — every stored type
│                         summary), Diagnostics (benchmark, "Validate
│                         Aggregate Functions", replay onboarding) and About
│                         (version, and four Links — the documentation, the
│                         privacy policy, the GitHub repository and its issue
│                         tracker — that open in Safari). No footers. Also
│                         UserView and the server-change prompt. The
│                         database is not here; it is the Sync tab's.
├── OnboardingView.swift  First run: four pages swiped in a paging ScrollView,
│                         no database asked for. "Unlock your Health Data"
│                         (Explore, Export, Sync); "Which Health data would
│                         you like to use?" (iOS's sheet for the preselected
│                         TypePresets.common, behind one Continue button);
│                         one-time exports; "Sync to your own database"
│                         (Learn more → pulshealth.com/docs/server/ in
│                         Safari) with Start Exploring, which applies the
│                         selection. Page 2 cannot be skipped: until iOS has
│                         been asked, pages 3 and 4 are not in the pager, and
│                         Continue or a swipe past the end presents the sheet
│                         (root CLAUDE.md). A puls:// link accepted during the
│                         flow waits until it ends, then Sync → Database
│                         opens with the fields filled. Settings →
│                         Diagnostics → "Show Onboarding Again" replays it
│                         (with a Close button) for testing.
├── PairingScannerView.swift  AVFoundation QR sheet feeding PairingPayload.parse.
│                         Used by Sync → Database (the setup card's Scan Pairing
│                         Code opens it on arrival). Handles
│                         not-yet-asked, denied, and no-camera, each with a
│                         "Type It Instead" way out; no frame is ever stored.
├── PairingLinkPrompt.swift  The "Pair with <host>?" alert an incoming puls://
│                         link has to get through (attached to RootView and to
│                         OnboardingView, which covers it), and the "Paste
│                         Pairing Code" row built on the system PasteButton.
├── TypeStyle.swift       Category colours and per-type SF Symbols.
└── BenchmarkView.swift   Throughput test: reads real HealthKit data through a
                          discarding transport with temporary state — touches no
                          real sync state.

HostedTests/              XCTest bundle hosted in the app (HealthKit entitlement
                          required to execute statistics queries): probes all 378
                          aggregate type×function combos behind an ObjC exception
                          catcher and fails on any mismatch with the library's
                          allowedAggregateFunctions — run on every new iOS runtime.
```

## Behavior notes

- A fresh install opens straight into the first-run flow; an install that
  already has a database, enabled types, or a previous Apply never sees it (the
  decision is `AppModel.showsOnboarding` — see the invariant in the root
  `CLAUDE.md`). What the app promises the user on that first screen is stated
  formally in [`docs/privacy-policy.md`](../docs/privacy-policy.md), and the
  App Store material that repeats it is in
  [`docs/appstore/`](../docs/appstore/README.md).
- **Pairing.** A database's pairing code (`puls://pair?url=&token=&user=`)
  reaches the app four ways: **Scan Pairing Code** (in-app camera), **Paste
  Pairing Code** (the system `PasteButton`, so iOS shows no paste banner and the
  clipboard is only read on that tap), the whole string put into the Database
  URL field, or a `puls://` link — tapped, or offered by the iOS Camera app when it
  reads the QR code. Each screen has one function that takes a `PairingPayload`
  (`applyPairing`), whatever the source: it fills the URL, token and user ID
  into the screen's `ServerFieldsDraft` and runs Test Connection. It applies
  nothing — the Database screen still ends with Save & Apply (and the
  server-change prompt, if the target moved).
  **A link is untrusted input**, because any web page or app can fire one, so
  `AppModel.handleIncomingURL` only ever raises a prompt: "Pair with
  \<host\>?", which says when accepting would replace a different configured
  server and when the URL is unencrypted `http://`; Cancel is the emphasized
  button. A link that does not parse gets "This Link Can’t Be Used" and
  changes nothing. The handler waits for `start()`, so on a cold launch the
  "replaces" decision reads the stored configuration and the prompt comes from
  the right host view (the first-run flow or the tabs). The first pending link
  wins, so the prompt on screen always describes the payload accepting it
  delivers. Only the host is logged, never the link or token. Accepting during
  the first run parks the payload in `confirmedPairing` and the flow's last
  page says a link is waiting; when the flow ends, and at any other time, the
  app switches to the Sync tab and pushes Sync → Database, popping anything
  pushed there.
- **Without a database.** The first-run flow never asks for one: it asks for
  Health access for the starter set, and Start Exploring applies it. Nothing
  syncs (`AppModel.configured` needs a database URL in the applied
  configuration), the Sync tab shows a setup card with a Set Up button instead
  of a status, and the Explore and Export tabs work regardless.
- **The Export tab** writes a selection of its own — `ExportDraft`: types,
  aggregate series, workout switches, a preset or custom range, the format
  and whether to zip it —
  seeded once from the applied sync selection and edited on the tab, never
  written back to it (a series added here is the export's alone). It goes to
  CSV or JSONL through the package's `HealthExporter`, which runs on a
  throwaway engine and never touches the app's sync state (root `CLAUDE.md`,
  "Export never shares sync state"). Before a run the app requests Health
  access for any type in the draft iOS still reports as undetermined — the
  draft can hold types no Apply has asked about — skipping types iOS refuses
  to list, and never presenting the medication picker (the screen says when
  Medication Doses is in the draft but that picker has not been answered) —
  then holds the screen awake and a background-task assertion until it ends.
  A partial export (`isComplete == false`) is shown as
  **Export incomplete** with the types that failed, and says so when the app
  left the foreground during the run, since a locked phone is the usual cause.
  Export is refused while a backfill runs, and Start Initial Backfill while an
  export does: they are the same sweep over the same store.
  **The staged files are short-lived by construction**, which the privacy
  policy relies on: they live under `HealthExporter.stagingRoot` in the
  temporary directory, and are deleted at every launch (`AppModel.init`), when
  another export starts, on Delete Export, and when the share sheet's
  completion handler reports `completed` — which is why the screen uses
  `UIActivityViewController` rather than `ShareLink`, which has no callback.
  A dismissed sheet deletes nothing. Copy is excluded from the sheet: it would
  report success for a file that is then deleted, and it is the one activity
  that would put health data on a shared clipboard.
- The most reliable sync trigger iOS offers is app-open: every foregrounding runs a
  full incremental pass, and re-reads the server's `GET /v1/capabilities` (kept
  in memory only) to decide which server-dependent controls to show.
- A newly enabled type with no anchor auto-backfills from the configured start date;
  a newly added aggregate config with no watermark does the same.
- Aggregates are independent of raw sync (a type can sync only its daily sum, no raw
  samples) — authorization and observer registration cover the union of both. A
  bucket inside its settle delay uploads on the next trigger after it settles;
  recent buckets are recomputed each run, so late Watch data self-corrects.
- Backfill on iOS 26 runs as a `BGContinuedProcessingTask` (system progress UI,
  survives backgrounding): Start Initial Backfill, and a whole-history Apply
  (the first Save & Apply after pairing, and a start-fresh server change).
  Adding a type under Synced Data backfills inline; earlier iOS keeps backfill
  foreground-resumable. Every sync the app starts itself holds a
  background-task assertion, so leaving the app mid-sync gives it iOS's grace
  period and then stops it cleanly (`BackgroundExecution`) instead of freezing
  it.
- Save & Apply sends the profile (Settings → User) only when there is one, or
  when the user has just emptied a filled one: the line replaces the server's
  copy, so an empty one sent by, say, a reinstall pairing with its old server
  would erase it.
- Types the permission sheet can't determine (blood pressure on iOS 26,
  FB22735935; fixed in iOS 27) are remembered per session and skipped from
  auth requests, with a hint on the Explore tab pointing at Settings → Privacy
  & Security → Health. The hint names the iOS 26 bug only below iOS 27.
- **Limited history (iOS 27).** The permission sheet's second page asks how
  much history to share, and Settings → Privacy & Security → Health →
  PulsHealth → (type) can change it per type later. With *Past 30 Days* a type
  is readable only from a date, and the package keeps every overwriting pass
  inside it and re-reads a type's history when access widens (root
  `CLAUDE.md`, "Limited history access"). The app's part: it re-reads the dates
  at launch (without holding up the launch), on every foreground (where a
  change made in Settings shows up) and after every permission sheet — Apply's,
  an analysis's, an export's (`AppModel.refreshReadableHistory`); the Sync tab shows a
  "Limited Health history" card naming the types, the date and the Settings
  path, with the existing Open Health Settings button; the Type page says an
  analysis covers only from that date, and the aggregate preview why its
  series starts late; an export lists the limited types under "Not exported"
  and is incomplete. **Don't Allow on that second page** throws, where the
  first page's does not; it is treated as the user's answer — no error,
  access marked as requested, and those types are not asked about again this
  session (`AppModel.declinedTypes`).
- Live logs from a Mac: `log stream --predicate 'subsystem == "com.pulsHealth.healthsync"'`.
- **Wake telemetry.** Every entry point that gives the engine execution time
  (observer delivery, the catch-up `BGProcessingTask`, the iOS 26
  continued-processing backfill, foregrounding, manual sync) opens a *wake*.
  The library's `WakeLog` (separate from the fast-rolling event log) keeps one
  durable record per wake — trigger, start/end, duration, inter-wake gap, work
  done, Low Power Mode, thermal state, and outcome
  (`completed`/`expired`/`failed`/`skippedLocked`/`interrupted`; a record still
  "running" at the next launch means the app was killed mid-wake) — about 10k
  wakes, months of them. Each wake's id and trigger ride the upload as
  `X-Wake-ID`/`X-Wake-Trigger` headers, so the server's `batches` rows join
  back to the device records. **Sync → Activity → Background → Export** shares
  the wakes (CSV and JSON) and the event log (JSON).
