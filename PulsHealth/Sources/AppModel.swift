import Foundation
import Observation
import PulsHealthSync

@MainActor
@Observable
final class AppModel {
    let engine: HealthSyncEngine
    let scheduler: BackgroundSyncScheduler
    /// The Export tab: the server-less way out. A model of its own so a run
    /// outlives the screen that started it (`ExportModel`).
    let export = ExportModel()
    /// The Explore tab: what HealthKit holds per type, and the analyses
    /// in flight to find out (`ExploreModel`). Read-only over HealthKit.
    let explore: ExploreModel

    private(set) var statuses: [TypeSyncStatus] = []
    /// Per-aggregate-config sync progress, keyed by config ID.
    private(set) var aggregateStates: [UUID: AggregateSyncState] = [:]
    private(set) var events: [SyncEvent] = []
    /// The `start()` task, so callers that need a loaded `config` (the first
    /// foreground `syncNow`) can await it instead of racing the launch.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Durable per-wake telemetry for the Background Activity screen. Refreshed
    /// from the engine's WakeLog whenever a wake finishes (engine `changes()`).
    private(set) var wakeRecords: [WakeRecord] = []
    /// Durable evidence that a BGProcessing request was submitted/pending versus
    /// the separate fact of whether iOS ever launched it.
    private(set) var backgroundScheduleStatus = BackgroundTaskScheduleStatus()
    private(set) var isSyncingAll = false
    /// Server-side aggregates from GET /v1/stats, keyed by type identifier.
    private(set) var serverStats: [String: TypeServerStats] = [:]
    private(set) var serverStatsError: String?
    private(set) var reconciling: Set<String> = []
    /// What the configured server advertised on its last successful
    /// `GET /v1/capabilities` — in memory only, refreshed after a successful
    /// connection test and on every foreground while a server is configured.
    /// Nil means unknown (never fetched, or the server has no such endpoint),
    /// and unknown hides the feature-gated UI: reconciliation needs `digest`
    /// + `uuids`, the per-type server rows need `stats`.
    private(set) var serverCapabilities: ServerCapabilities?
    /// The last Test Connection this session and the URL it ran against, so
    /// the Sync tab can say what is known about the applied server without
    /// testing again. Not persisted: a fresh launch knows nothing.
    private(set) var lastConnectionTest: ConnectionTestRecord?
    /// The live editing draft bound by the Synced Data, Server and Settings screens.
    var config = SyncConfiguration()
    /// Snapshot of what's actually been pushed to the engine. The Synced Data
    /// screen edits `config` freely; changes only reach the engine (and start
    /// backfilling) when `applyChanges()` advances this to match.
    private(set) var appliedConfig = SyncConfiguration()
    var authorizationRequested = false
    /// True while some catalog type's read authorization is still undetermined —
    /// queries against those types fail until the user grants access.
    var needsAuthorization = false
    /// Set when iOS refused to show the permission sheet for some enabled types
    /// (e.g. the iOS 26.5 blood-pressure regression, FB22735935): the request
    /// "succeeds" but the types never appear in the sheet and stay undetermined.
    /// Cleared when a later request actually determines them.
    var authorizationHint: String?
    /// iOS 27 limited history access: the applied types HealthKit lets the
    /// app read only from a date on, by identifier, as of the last look
    /// (`refreshReadableHistory`). Empty when nothing is limited, and always
    /// before iOS 27. Drives the Sync tab's notice.
    private(set) var readableHistory: [String: Date] = [:]

    /// Every enabled type has completed at least one sync and not one of them
    /// returned a single sample.
    ///
    /// This exists because HealthKit never reports a read *denial*. Once the
    /// permission sheet has been shown, `statusForAuthorizationRequest` answers
    /// `.unnecessary` whether the user allowed everything or denied everything,
    /// and a denied read returns an empty result set rather than an error — so
    /// `needsAuthorization` goes false, no type is ever marked `.failed`, and
    /// the app happily reports success while uploading nothing, forever. The
    /// only signal left is the outcome, which is what this reads.
    ///
    /// It is a heuristic, not a verdict: a phone with no recorded health data
    /// looks identical. The copy it drives says so rather than accusing.
    var readsLookBlocked: Bool {
        let observed = statuses.filter { !HealthTypeCatalog.isActivitySummary($0.id) }
        guard !observed.isEmpty else { return false }
        // Only judge once every type has actually run — mid-backfill counts are
        // legitimately zero.
        guard observed.allSatisfy({ $0.state.lastSyncAt != nil }) else { return false }
        return observed.allSatisfy { $0.state.totalSamplesExported == 0 }
    }
    var lastErrorMessage: String?
    /// True while the first-run flow covers the app (`OnboardingView`). Set
    /// synchronously in `init` so a fresh launch never flashes an unconfigured
    /// dashboard, then corrected in `startBody` once the persisted
    /// configuration has actually been read.
    var showsOnboarding = false
    /// Whether the flow is a replay on an install that already finished it
    /// (Settings → Diagnostics). Only a replay gets a Close button — a genuine
    /// first run walks forward through the steps instead.
    private(set) var onboardingIsRerun = false
    /// A Save & Apply that would point the sync at a different server or user
    /// ID. Held here — nothing applied yet — until the user chooses between
    /// starting fresh and keeping progress (`confirmServerChange`); RootView
    /// presents the prompt wherever the apply came from.
    private(set) var pendingServerChange: ServerIdentityChange?
    /// Whether the deferred apply asked to backfill newly enabled types.
    @ObservationIgnored private var pendingServerChangeWantsNewTypeSync = false

    /// What an incoming `puls://` link is waiting to show: the confirmation for
    /// a valid pairing link, or the reason an unusable one was dropped.
    enum PairingLinkPrompt: Equatable {
        case confirm(PairingPayload)
        case rejected(String)
    }
    /// Set by `handleIncomingURL`, cleared by the prompt's buttons. A link
    /// fills nothing until the user has answered this (`PairingLinkPromptModifier`).
    private(set) var pairingLinkPrompt: PairingLinkPrompt?
    /// A pairing link the user accepted, waiting for Sync → Database to collect
    /// it with `takeConfirmedPairing()` — after the first-run flow, if that is
    /// up (`pairingAwaitsSyncTab`). A hand-off rather than a write into
    /// `config`: the screen keeps the URL and token as local text until Save &
    /// Apply, and a link gets no shortcut past that.
    private(set) var confirmedPairing: PairingPayload?

    /// Types a permission request failed to determine this session. Re-requesting
    /// them just makes the sheet flash and auto-dismiss, so the proactive tab-exit
    /// prompt skips them until something else becomes pending. Session-only on
    /// purpose: after an iOS update fixes the bug, a fresh launch retries once.
    @ObservationIgnored private var undeterminableTypes: Set<String> = []

    /// Types the user answered Don't Allow for on iOS 27's history page ("How
    /// much data would you like to share?"). iOS leaves them undetermined, so
    /// nothing stops the app asking again — but the user just said no, and
    /// declining on the first page is never asked about again. So for the
    /// rest of the session they are treated the same way: not requested
    /// again, and not counted as access still to ask for. A later launch's
    /// Apply may ask again; Settings → Privacy & Security → Health is the
    /// other way back.
    @ObservationIgnored private var declinedTypes: Set<String> = []

    /// True while a medication access request is scheduled or in flight, so a
    /// second Apply doesn't stack another one on top of it.
    @ObservationIgnored private var requestingMedicationAccess = false

    private var started = false

    init() {
        let engine = HealthSyncEngine()
        self.engine = engine
        self.scheduler = BackgroundSyncScheduler(engine: engine)
        self.explore = ExploreModel(engine: engine)
        // An analysis can show the permission sheet too; what it answered
        // for history (iOS 27) is recorded the same way as after Apply's.
        explore.onHealthAccessRequested = { [weak self] in await self?.refreshReadableHistory() }
        // An export's files are health data sitting in the temporary directory
        // until they are shared. The privacy policy says none survives a
        // launch, and this line is what makes that true — for the export the
        // user never got round to sharing, and for whatever a crash or a
        // force-quit left half-written. Here rather than in `start()` because
        // this runs once per process, before any export can, so it can never
        // delete a run's directory out from under it; and it is a synchronous
        // unlink, which works on a locked device too (a background launch).
        HealthExporter.removeAllExports()
        // Reading the persisted configuration is async, and the window is built
        // before it lands. Decide from the two durable flags alone so a first
        // launch opens straight into onboarding: `authorizationRequested` marks
        // any install that has been through Apply, including one that predates
        // this flow. `startBody` re-checks against the loaded configuration.
        let defaults = UserDefaults.standard
        showsOnboarding = !defaults.bool(forKey: Self.onboardingCompletedKey)
            && !defaults.bool(forKey: "authorizationRequested")
    }

    // MARK: - Lifecycle

    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await self.startBody() }
        startTask = task
        await task.value
    }

    private func startBody() async {
        guard !started else { return }
        started = true

        config = await engine.store.configuration
        appliedConfig = config
        // The Export tab's draft starts from the applied selection, if the
        // user has not already started editing it.
        export.seedFromApplied(config)
        authorizationRequested = UserDefaults.standard.bool(forKey: "authorizationRequested")
        // Don't trust the one-shot flag alone: types added to the catalog after
        // the first grant (or an interrupted permission sheet) stay notDetermined
        // and make their syncs fail until access is requested again.
        await refreshNeedsAuthorization()
        // Not awaited: it is one HealthKit round trip, which has been seen to
        // stall for up to its ten-second timeout, and the observer
        // registration at the end of this method must not wait behind it on
        // a background launch. Nothing here needs the answer; the
        // foreground sync asks again before it claims anything.
        Task { await refreshReadableHistory() }
        // Heal installs where the flag was never written because access was
        // already determined when Apply ran (older builds only set it after an
        // actual prompt): a configured setup with nothing left to ask for is
        // exactly the state the observer and BG schedule should run in.
        if !config.observedTypeIdentifiers.isEmpty, !needsAuthorization {
            markAuthorizationRequested()
        }
        // A server/user change that was applied but never confirmed (the app
        // died between the two) leaves the stored progress pointing at the
        // wrong server. Ask again rather than quietly syncing on.
        if let change = await engine.pendingServerIdentityChange() {
            pendingServerChange = change
        }
        // Correct `init`'s guess now the stored configuration is known: an
        // install that already has a server or types (an upgrade from before
        // this flow existed, or one whose Apply predates the durable flag) is
        // configured and must never be sent through first-run onboarding.
        if showsOnboarding {
            if config.serverURL != nil || !config.observedTypeIdentifiers.isEmpty
                || authorizationRequested {
                completeOnboarding()
            } else {
                preselectCommonTypesIfUnset()
            }
        }

        // Observe engine changes -> refresh the status tabs.
        let changeTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await engine.changes() {
                await refresh()
            }
        }
        // Observe event log -> live log view.
        let logTask = Task { [weak self] in
            guard let self else { return }
            for await event in await engine.eventLog.stream() {
                events.append(event)
                if events.count > 1_000 { events.removeFirst(events.count - 1_000) }
            }
        }
        _ = (changeTask, logTask)

        events = await engine.eventLog.recent(limit: 500)
        await ensureBackgroundCatchupScheduled()
        await refresh()

        if authorizationRequested {
            await engine.startObserving()
        }
    }

    func refresh() async {
        statuses = await engine.snapshot()
        let rawStates = await engine.store.aggregateStates
        aggregateStates = Dictionary(uniqueKeysWithValues: rawStates.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
        wakeRecords = await engine.wakeLog.recent(limit: 1_000)
        backgroundScheduleStatus = scheduler.scheduleStatus()
    }

    func ensureBackgroundCatchupScheduled() async {
        guard authorizationRequested else { return }
        await scheduler.ensureScheduled()
        backgroundScheduleStatus = scheduler.scheduleStatus()
    }

    // MARK: - Diagnostics export

    /// Write the wake records (CSV + JSON) and the event log (JSON) to temp files
    /// for the share sheet. Returns the files in a stable order so the Background
    /// Activity screen can offer them via `ShareLink`.
    func writeDiagnosticsBundle() async -> [URL] {
        let stamp = Self.exportStampFormatter.string(from: Date())
        let dir = FileManager.default.temporaryDirectory
        let wakeCSV = await engine.wakeLog.exportCSV()
        let wakeJSON = await engine.wakeLog.exportJSON()
        let eventsJSON = await engine.eventLog.exportJSON()
        let scheduleEncoder = JSONEncoder()
        scheduleEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        scheduleEncoder.dateEncodingStrategy = .iso8601
        let scheduleJSON = (try? scheduleEncoder.encode(backgroundScheduleStatus)) ?? Data()
        let files: [(String, Data)] = [
            ("puls-wakes-\(stamp).csv", Data(wakeCSV.utf8)),
            ("puls-wakes-\(stamp).json", wakeJSON),
            ("puls-events-\(stamp).json", eventsJSON),
            ("puls-background-schedule-\(stamp).json", scheduleJSON),
        ]
        var urls: [URL] = []
        for (name, data) in files {
            let url = dir.appendingPathComponent(name)
            if (try? data.write(to: url, options: .atomic)) != nil { urls.append(url) }
        }
        return urls
    }

    private static let exportStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: - First run

    private static let onboardingCompletedKey = "onboardingCompleted"
    /// An emptied profile whose clearing upload failed (`ProfilePayload.shouldUpload`).
    private static let profileClearPendingKey = "profileClearPending"

    /// Marks the first run done and leaves the flow. Durable, so the flow is
    /// shown exactly once per install; Settings → Diagnostics can replay it.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        showsOnboarding = false
        onboardingIsRerun = false
    }

    /// The flow's Start Exploring: push the draft (the starter set, and on a
    /// replay whatever else is staged) to the engine, which requests Health
    /// access for anything still undetermined and starts backfilling the newly
    /// enabled types — the same path Save & Apply takes.
    /// The first-run flag is written first so a failure here cannot trap the
    /// user in the flow.
    func finishOnboarding() async {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        await applyConfiguration(syncNewTypes: true, wholeHistory: true)
        showsOnboarding = false
        onboardingIsRerun = false
    }

    /// Settings → Diagnostics: replay the flow on a configured install. Nothing
    /// is reset — the existing selection and server stay in the draft.
    func restartOnboarding() {
        onboardingIsRerun = true
        preselectCommonTypesIfUnset()
        showsOnboarding = true
    }

    /// Seeds the draft with the Common preset — the starter set the flow's
    /// Health page asks iOS about, and what Explore and Export start from.
    /// Only ever fills an empty draft: a replay must not overwrite what the
    /// user already chose.
    private func preselectCommonTypesIfUnset() {
        guard config.enabledTypes.isEmpty, config.aggregates.isEmpty else { return }
        config.enabledTypes = TypePresets.common
    }

    /// Requests Health access for the current draft without applying anything
    /// else — the flow's Health page, run before the selection reaches the
    /// engine on its last page.
    func requestOnboardingHealthAccess() async {
        await requestAccessForEnabledTypesIfNeeded()
    }

    /// Whether the flow's Health page still has a sheet to show: some type in
    /// the draft iOS has never asked about, other than the ones it leaves off
    /// the sheet (`undeterminableTypes`) or the user declined on iOS 27's
    /// history page this session — the same rule `requestAccessForEnabledTypesIfNeeded`
    /// asks by. False lets the page be swiped past; true holds the flow on
    /// it until iOS has been asked.
    ///
    /// Waits for `start()`: before it the draft is empty — a first run's
    /// starter set is preselected there — and an empty draft would read as
    /// nothing to ask.
    func onboardingHealthAccessPending() async -> Bool {
        await start()
        let enabled = config.observedTypeIdentifiers.subtracting(declinedTypes).sorted()
        guard !enabled.isEmpty, await engine.authorizationNeeded(for: enabled) else { return false }
        let pending = await pendingTypes(among: enabled)
        return !Set(pending).isSubset(of: undeterminableTypes)
    }

    // MARK: - Export to files

    /// What the Export tab exports: its own draft (`ExportModel.draft`),
    /// seeded from the applied selection and edited on the tab. It is not the
    /// Synced Data draft: what is chosen there counts only after Apply, and
    /// what is chosen here never reaches the sync at all.
    var exportSelection: ExportSelectionSummary {
        ExportSelectionSummary(selection: export.draft.selection())
    }

    /// A backfill and an export are the same sweep over the same HealthKit
    /// store, each several queries wide. Running both is allowed and neither
    /// corrupts the other (the export's engine shares no state), but each
    /// would crawl — so the screen waits for the backfill rather than start a
    /// multi-minute run that looks hung. Incremental syncs are small and are
    /// not waited for.
    var exportBlockedByBackfill: Bool { backfillActive }

    /// Medication Doses is in the export draft but this install has never got
    /// the per-object picker on screen, so the export will find no doses.
    /// Apply schedules that picker for any synced selection that includes the
    /// type. Export only *says* so — it must not present the picker itself,
    /// least of all on a path it awaits (see `scheduleMedicationAccessRequest`).
    var exportLacksMedicationAccess: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return export.draft.types.contains(HealthTypeCatalog.medicationDoseIdentifier)
            && !UserDefaults.standard.bool(forKey: Self.medicationAuthRequestedKey)
    }

    func startExport() {
        guard !exportBlockedByBackfill, !exportSelection.isEmpty else { return }
        export.start(configuration: appliedConfig, engine: engine) { [weak self] in
            await self?.requestHealthAccessForExport()
        }
    }

    /// The export's permission step. `HealthExporter` never prompts, and a type
    /// whose access was never requested comes back as a failure, so anything in
    /// the export draft (its types and its series' types) that iOS still
    /// reports as undetermined is asked for first — one sheet, the same request
    /// Apply makes.
    ///
    /// The draft is built on the tab, so unlike the applied selection it can
    /// hold types no Apply has asked about; this is where they are asked for.
    /// Two rules carry over from Apply: types iOS refuses to put in the sheet
    /// are not asked for again (it would only flash — they show up in the
    /// export's failures, with the hint already on the Explore tab), and the
    /// medication picker is not requested here at all.
    ///
    /// It does not touch `authorizationRequested`: that flag gates observer
    /// registration and background scheduling, which are the sync's business.
    private func requestHealthAccessForExport() async {
        let selection = export.draft.selection()
        let selected = selection.types
            .union(selection.aggregates.map(\.typeIdentifier))
            .sorted()
        guard !selected.isEmpty, await engine.authorizationNeeded(for: selected) else { return }
        let pending = await pendingTypes(among: selected)
        guard !Set(pending).isSubset(of: undeterminableTypes.union(declinedTypes)) else { return }
        do {
            switch try await engine.requestAuthorization(for: selected.filter { !declinedTypes.contains($0) }) {
            case .answered:
                undeterminableTypes.formUnion(await pendingTypes(among: selected))
            case .declined:
                // The export runs anyway and reports these as unread.
                declinedTypes.formUnion(pending)
            }
        } catch {
            // Not fatal: the export runs and reports what it could not read.
            await engine.eventLog.log(
                .warn, "Health access request before export failed: \(error.localizedDescription)")
        }
        await refreshNeedsAuthorization()
        // As after Apply's sheet: it may just have limited history (iOS 27)
        // for types the sync also reads, and the engine records it before
        // the next sync reads under it.
        await refreshReadableHistory()
    }

    // MARK: - Actions

    /// Recomputes the Explore tab's "access incomplete" warning. Scoped to the
    /// types the user actually enabled (raw-sync ∪ aggregates): unselected
    /// catalog types staying undetermined is normal and must never raise a
    /// warning — only enabled types whose syncs would fail matter.
    private func refreshNeedsAuthorization() async {
        // A type declined on iOS 27's history page is as answered as one
        // declined on the first page, which iOS reports as determined.
        let enabled = config.observedTypeIdentifiers.subtracting(declinedTypes).sorted()
        needsAuthorization = enabled.isEmpty
            ? false
            : await engine.authorizationNeeded(for: enabled)
    }

    /// Re-read how much history iOS 27 lets the app read for each applied
    /// type, and let the engine act on what moved (a widened type is
    /// re-swept — `HealthSyncEngine.refreshReadableHistory`). Forced, unlike
    /// the engine's own rate-limited calls: this runs when the app comes to
    /// the foreground, which is when someone may just have changed access
    /// in Settings, and after a permission sheet.
    func refreshReadableHistory() async {
        let observed = appliedConfig.observedTypeIdentifiers
        readableHistory = await engine.refreshReadableHistory(force: true)
            .filter { observed.contains($0.key) }
    }

    /// Observed types (raw-sync ∪ enabled aggregates) that iOS still reports as
    /// never-determined, one by one.
    private func pendingEnabledTypes() async -> [String] {
        await pendingTypes(among: config.observedTypeIdentifiers.subtracting(declinedTypes).sorted())
    }

    private func pendingTypes(among identifiers: [String]) async -> [String] {
        var pending: [String] = []
        for id in identifiers {
            if await engine.authorizationNeeded(for: [id]) { pending.append(id) }
        }
        return pending
    }

    /// After a permission request ran, anything still pending is a type iOS
    /// refused to put in the sheet (iOS 26.5 omits blood pressure, FB22735935).
    /// Remember them so we stop re-prompting, and tell the user the manual path.
    private func noteUndeterminableTypes() async {
        let stillPending = await pendingEnabledTypes()
        undeterminableTypes.formUnion(stillPending)
        guard !stillPending.isEmpty else {
            authorizationHint = nil
            return
        }
        let names = stillPending
            .map { HealthTypeCatalog.descriptor(for: $0)?.displayName ?? $0 }
            .joined(separator: ", ")
        // Blood pressure is the known case: iOS 26 leaves it off the sheet
        // (FB22735935); iOS 27.0 lists it again. The hint stays for any type
        // a sheet leaves out, so it only names the bug where it applies.
        let cause: String
        if #available(iOS 27, *) {
            cause = ""
        } else {
            cause = " (a known iOS 26 bug that iOS 27 fixes)"
        }
        authorizationHint = """
        iOS didn't include some types in the permission sheet\(cause): \(names). \
        Enable them manually in Settings → Privacy & Security → Health → PulsHealth.
        """
    }

    /// The app's single HealthKit permission prompt. Called from Apply/Save when
    /// a configuration is pushed to the engine: any enabled type (raw-sync or
    /// aggregate-only) whose read access iOS still reports as undetermined is
    /// requested now, in one sheet, before we start reading. The Explore tab only
    /// *warns* about missing access — it never prompts. Idempotent: once a type
    /// is determined it isn't asked again, so re-applying never re-prompts.
    func requestAccessForEnabledTypesIfNeeded() async {
        let enabled = config.observedTypeIdentifiers.sorted()
        if !enabled.isEmpty, await engine.authorizationNeeded(for: enabled) {
            // If everything still pending is known-unpromptable (the iOS 26.5
            // blood-pressure regression), asking again just flashes the sheet —
            // keep the hint up and skip to the per-object step.
            let pending = await pendingEnabledTypes()
            if !Set(pending).isSubset(of: undeterminableTypes) {
                do {
                    let asking = enabled.filter { !declinedTypes.contains($0) }
                    switch try await engine.requestAuthorization(for: asking) {
                    case .answered:
                        markAuthorizationRequested()
                        await noteUndeterminableTypes()
                    case .declined:
                        // Don't Allow on iOS 27's history page: the user's
                        // answer, not a failure — no banner, and asked, so
                        // the observer and background schedule run as they
                        // do after a Don't Allow on the first page.
                        markAuthorizationRequested()
                        declinedTypes.formUnion(pending)
                    }
                } catch {
                    lastErrorMessage = error.localizedDescription
                }
            }
        } else {
            authorizationHint = nil
            // Access for every enabled type is already determined (a reinstall
            // keeps HealthKit grants but not UserDefaults; or the user granted
            // access from Settings → Health before the first Apply). Without
            // the flag, every later launch skipped the observer registration
            // and the BGProcessing schedule, and the Explore tab kept showing the
            // welcome banner — background sync silently stopped after a
            // reinstall until the user tapped Apply again in each session.
            if !enabled.isEmpty { markAuthorizationRequested() }
        }
        // Medications use a separate per-object sheet (the user picks which
        // medications the app may read). It follows the bulk one so the main
        // grant always comes first — but it is started, never awaited, because
        // iOS can swallow its presentation and never call back
        // (`scheduleMedicationAccessRequest()`).
        scheduleMedicationAccessRequest()
        await refreshNeedsAuthorization()
    }

    /// Durable "we have asked, or never need to ask, for Health access" — the
    /// gate for observer registration and background catch-up scheduling.
    private func markAuthorizationRequested() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UserDefaults.standard.set(true, forKey: "authorizationRequested")
    }

    /// Push the draft to the engine. Returns false when nothing was applied
    /// because the draft points at a different server or user ID than the
    /// stored sync progress belongs to: the prompt is raised instead, and the
    /// apply resumes from `confirmServerChange` with the user's choice.
    ///
    /// `wholeHistory` marks an apply whose backfill is every enabled type from
    /// the start date — the first run, or a start-fresh server change — as
    /// opposed to a type or two added on the Synced Data screen.
    @discardableResult
    func applyConfiguration(
        syncNewTypes: Bool = false, serverChangeConfirmed: Bool = false, wholeHistory: Bool = false
    ) async -> Bool {
        if !serverChangeConfirmed, let change = await engine.serverIdentityChange(applying: config) {
            pendingServerChange = change
            pendingServerChangeWantsNewTypeSync = syncNewTypes
            return false
        }
        let previousProfile = await engine.store.configuration.userProfilePayload
        await resetReidentifiedAggregates()
        await engine.configure(config, confirmServerIdentity: serverChangeConfirmed)
        appliedConfig = config
        // User identity is independent of workout availability. Send it as its
        // own tiny batch so Save & Apply updates the server immediately even when
        // there are no new workouts to carry a profile line — unless there is
        // nothing to say: an install that never had a profile (a reinstall
        // pairing with its old server, above all) must not clear the one the
        // server already holds (`ProfilePayload.shouldUpload`).
        let profile = config.userProfilePayload
        let clearPending = UserDefaults.standard.bool(forKey: Self.profileClearPendingKey)
        if config.serverURL != nil, config.authToken != nil,
           ProfilePayload.shouldUpload(profile, replacing: previousProfile, clearPending: clearPending) {
            do {
                try await engine.syncProfile(reason: .manual)
                UserDefaults.standard.set(false, forKey: Self.profileClearPendingKey)
            } catch {
                // A clear that did not arrive is remembered for the next Apply;
                // a filled profile needs no flag, it is always sent.
                if profile.isEmpty {
                    UserDefaults.standard.set(true, forKey: Self.profileClearPendingKey)
                }
                lastErrorMessage = error.localizedDescription
            }
        }
        // Apply/Save is the one place the app asks HealthKit for access. Request
        // it before reading so a newly enabled type doesn't fail its first sync.
        await requestAccessForEnabledTypesIfNeeded()
        // The sheet may just have limited what can be read (iOS 27). The
        // engine records it before the backfill below reads anything, which
        // is what lets a later widening be noticed.
        await refreshReadableHistory()
        // A whole-history backfill may start in a task of its own (iOS 26,
        // below), after the wake the observer registration triggers. Tell the
        // engine it is coming so that wake does not take its types first.
        if syncNewTypes, wholeHistory { await engine.expectBackfill() }
        await engine.startObserving()
        await refresh()

        guard syncNewTypes, configured, config.authToken != nil, !isSyncingAll else { return true }
        // Types enabled but never synced (no anchor) start backfilling right
        // away so they appear live on the dashboard instead of "not synced".
        let newTypes = statuses
            .filter {
                !HealthTypeCatalog.isActivitySummary($0.id)
                    && $0.state.anchorData == nil
                    && $0.activity == .idle
            }
            .map(\.id)
        // Enabled aggregate configs that have never computed a bucket start
        // backfilling right away too.
        let newAggregates = config.aggregates
            .filter { $0.enabled && aggregateStates[$0.id]?.computedThrough == nil }
            .map(\.id)
        let activitySummaryState = await engine.store.activitySummaryState
        let newRings = config.enabledTypes.contains(HealthTypeCatalog.activitySummaryIdentifier)
            && activitySummaryState.computedThrough == nil
        guard !newTypes.isEmpty || !newAggregates.isEmpty || newRings else { return true }

        // The whole history is the largest data movement an install makes, and
        // it used to stop the moment the user left the app: iOS suspended it
        // and every later wake crawled through the rest a few pages at a time.
        // On iOS 26 run it as the continued-processing task Start Initial
        // Backfill uses, which keeps going with system progress UI. That task
        // runs `syncAllEnabled(.backfill)`: rings, aggregates and every type,
        // which on a whole-history apply is exactly the new work above.
        if wholeHistory, #available(iOS 26.0, *), scheduler.startContinuedBackfill() {
            return true
        }
        // This is usually the largest data movement of an install, so it runs
        // inside a wake like every other entry point (X-Wake-ID on its batches,
        // a Background Activity record) and under the same isSyncingAll gate as
        // Start Initial Backfill, so the two cannot run 4-wide on top of each
        // other.
        isSyncingAll = true
        Task {
            defer { isSyncingAll = false }
            let wake = await engine.beginWake(.manual, detail: "apply: backfill newly enabled types")
            let finished = await BackgroundExecution.run("PulsHealth backfill") { [engine] in
                await WakeScope.$current.withValue(wake) {
                    await withTaskGroup(of: Void.self) { group in
                        if !newTypes.isEmpty {
                            group.addTask { await engine.syncTypes(newTypes, reason: .backfill) }
                        }
                        if !newAggregates.isEmpty {
                            group.addTask {
                                for id in newAggregates {
                                    await engine.syncAggregate(configID: id, reason: .backfill)
                                }
                            }
                        }
                        if newRings {
                            group.addTask { await engine.syncActivitySummary(reason: .backfill) }
                        }
                    }
                }
            }
            await engine.finishWake(wake, outcome: finished ? .completed : .expired)
        }
        return true
    }

    // MARK: - Server / user change

    /// Resolve a deferred apply. "Start fresh" runs the existing full reset —
    /// every anchor and watermark — so the new server receives all history
    /// from the start date; "keep progress" leaves them, so only data newer
    /// than the old high-water mark reaches it. Either way the identity is
    /// recorded only now, with the choice, never before it.
    ///
    /// Synchronous on purpose: the alert button's action and the dismissal of
    /// its `isPresented` binding land in the same turn, so the choice is
    /// captured here, before any await, and the work continues in a task.
    func confirmServerChange(startFresh: Bool) {
        guard let change = pendingServerChange else { return }
        pendingServerChange = nil
        let wantsNewTypeSync = pendingServerChangeWantsNewTypeSync
        pendingServerChangeWantsNewTypeSync = false
        Task {
            await resolveServerChange(change, startFresh: startFresh, wantsNewTypeSync: wantsNewTypeSync)
        }
    }

    private func resolveServerChange(
        _ change: ServerIdentityChange, startFresh: Bool, wantsNewTypeSync: Bool
    ) async {
        if startFresh {
            guard await engine.resetAll() else {
                lastErrorMessage = "A sync is in progress. Wait for it to finish, then save again."
                return
            }
            await engine.eventLog.log(
                .warn, "Sync target changed (\(change.summary)) — all anchors and watermarks reset; re-syncing history")
        } else {
            await engine.eventLog.log(
                .warn, "Sync target changed (\(change.summary)) — progress kept; only new data will reach it")
        }
        await applyConfiguration(
            syncNewTypes: startFresh || wantsNewTypeSync, serverChangeConfirmed: true,
            wholeHistory: startFresh)
    }

    /// Dismiss the prompt without applying. The draft keeps what was typed so
    /// the user can adjust it; nothing has reached the engine.
    func cancelServerChange() {
        pendingServerChange = nil
        pendingServerChangeWantsNewTypeSync = false
    }

    // MARK: - Pairing links

    /// Entry point for `onOpenURL`: a tapped `puls://pair?…` link, or the same
    /// string read from the server's QR code by the iOS Camera app.
    ///
    /// **A link is untrusted input.** Any web page or app can fire one, so this
    /// never touches the configuration, the draft or the fields. It parses the
    /// link — `PairingPayload.parse` re-validates the URL and the UUID exactly
    /// as it does for a scanned code — and raises a prompt naming the host. The
    /// values go nowhere until the user accepts, and then only as far as a scan
    /// would take them: into the server fields, tested, not applied.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == PairingPayload.scheme else { return }
        Task {
            // A link can be what launches the app. Both things the prompt
            // depends on are only known once `start()` has read the stored
            // state: whether a server is already configured (the "replaces"
            // warning), and whether the first-run flow is really up — `init`
            // guesses that from two flags and `startBody` corrects it.
            await start()
            // First one wins. The prompt on screen must describe the payload
            // that accepting it delivers; a second link swapping the payload
            // underneath an alert that still names the first host would defeat
            // the whole confirmation.
            guard pairingLinkPrompt == nil else {
                await engine.eventLog.log(.warn, "Pairing link ignored — another one is awaiting an answer")
                return
            }
            // Never log the link itself: it carries the token. Host only.
            switch PairingPayload.parse(url.absoluteString) {
            case .success(let payload):
                pairingLinkPrompt = .confirm(payload)
                await engine.eventLog.log(
                    .info,
                    "Pairing link for \(pairingConfirmation(for: payload).serverLabel) opened — waiting for confirmation")
            case .failure(let failure):
                pairingLinkPrompt = .rejected(PairingConfirmation.rejectionMessage(for: failure))
                await engine.eventLog.log(
                    .warn, "Pairing link not used: \(failure.errorDescription ?? "unreadable")")
            }
        }
    }

    /// What the prompt says about `payload`, worked out when the prompt is
    /// shown rather than when the link arrived: a link that lands during the
    /// flow's final Apply is only presented once the cover is down, and by
    /// then both halves of the answer have changed — a server is applied, and
    /// accepting leads to Sync → Database, not into the flow.
    func pairingConfirmation(for payload: PairingPayload) -> PairingConfirmation {
        PairingConfirmation(
            payload: payload,
            // The *applied* server: where data goes today, not a half-typed draft.
            currentServerURL: appliedConfig.serverURL,
            currentUserID: appliedConfig.userID,
            // Always Sync → Database: the first-run flow has no database step
            // any more, so a link accepted during it waits for the flow to end and
            // lands there (`pairingAwaitsSyncTab`).
            destination: .settings)
    }

    /// The prompt's Continue. Takes the payload the prompt *displayed* and
    /// refuses anything else, for the same reason as first-one-wins above.
    ///
    /// Synchronous, like `confirmServerChange`: an alert button's action and
    /// the dismissal of its binding land in the same turn.
    func confirmPairingLink(_ payload: PairingPayload) {
        guard case .confirm(let pending) = pairingLinkPrompt, pending == payload else { return }
        pairingLinkPrompt = nil
        confirmedPairing = payload
        let label = pairingConfirmation(for: payload).serverLabel
        Task {
            await engine.eventLog.log(
                .info, "Pairing link for \(label) accepted — server details filled in, nothing applied")
        }
    }

    /// Cancel on the confirmation, or OK on the "can't be used" notice.
    func dismissPairingLink() {
        guard let prompt = pairingLinkPrompt else { return }
        pairingLinkPrompt = nil
        if case .confirm(let payload) = prompt {
            let label = pairingConfirmation(for: payload).serverLabel
            Task { await engine.eventLog.log(.info, "Pairing link for \(label) declined") }
        }
    }

    /// True while an accepted link is waiting for Sync → Database, i.e. the
    /// first-run flow is not the one that should take it. RootView switches to
    /// the Sync tab and pushes the Database screen on this.
    var pairingAwaitsSyncTab: Bool { confirmedPairing != nil && !showsOnboarding }

    /// One-shot: the screen that fills its fields from the payload takes it.
    func takeConfirmedPairing() -> PairingPayload? {
        defer { confirmedPairing = nil }
        return confirmedPairing
    }

    // MARK: - Staged Synced Data changes

    /// True while the Synced Data draft differs from what's applied to the
    /// engine. Scoped to the fields that screen edits (raw types, aggregates,
    /// workout routes) so Settings-only edits don't trip the Apply bar. Drives
    /// the pending-changes bar on the Sync tab.
    var hasPendingChanges: Bool {
        config.enabledTypes != appliedConfig.enabledTypes
            || config.aggregates != appliedConfig.aggregates
            || config.includeWorkoutRoutes != appliedConfig.includeWorkoutRoutes
            || config.includeWorkoutEnhancedData != appliedConfig.includeWorkoutEnhancedData
    }

    /// The Settings twin of `hasPendingChanges`: true while a field Settings
    /// or its User page edits differs from what's applied. Settings shows its
    /// Save & Apply only then — including for User edits left unsaved when
    /// that page was popped.
    var hasPendingSettingsChanges: Bool {
        config.startDate != appliedConfig.startDate
            || config.maxConcurrentTypes != appliedConfig.maxConcurrentTypes
            || config.batchSize != appliedConfig.batchSize
            || config.userID != appliedConfig.userID
            || config.userName != appliedConfig.userName
            || config.userEmail != appliedConfig.userEmail
            || config.userDateOfBirth != appliedConfig.userDateOfBirth
            || config.userBiologicalSex != appliedConfig.userBiologicalSex
    }

    /// Short description of what's staged, e.g. "2 data types · 1 aggregate".
    var pendingChangesSummary: String {
        var parts: [String] = []
        let typeDelta = config.enabledTypes.symmetricDifference(appliedConfig.enabledTypes).count
        if typeDelta > 0 {
            parts.append("\(typeDelta) data type\(typeDelta == 1 ? "" : "s")")
        }
        let applied = Dictionary(uniqueKeysWithValues: appliedConfig.aggregates.map { ($0.id, $0) })
        let draft = Dictionary(uniqueKeysWithValues: config.aggregates.map { ($0.id, $0) })
        let aggDelta = Set(applied.keys).union(draft.keys).count { applied[$0] != draft[$0] }
        if aggDelta > 0 {
            parts.append("\(aggDelta) aggregate\(aggDelta == 1 ? "" : "s")")
        }
        if config.includeWorkoutRoutes != appliedConfig.includeWorkoutRoutes {
            parts.append("workout routes")
        }
        if config.includeWorkoutEnhancedData != appliedConfig.includeWorkoutEnhancedData {
            parts.append("enhanced workout data")
        }
        return parts.isEmpty ? "configuration" : parts.joined(separator: " · ")
    }

    /// Commits the staged Synced Data draft: pushes it to the engine and starts
    /// backfilling newly enabled types/aggregates. Mirrors Settings' Save & Apply.
    func applyChanges() async {
        await applyConfiguration(syncNewTypes: true)
    }

    /// Validates a user ID edit: a UUID in any case or nil. Normalized to
    /// lowercase to match `PulsDefaultUser.id`; the server treats the ID
    /// case-insensitively but the stored identity compares lowercased.
    nonisolated static func normalizedUserID(_ text: String) -> String? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { $0.uuidString.lowercased() }
    }

    /// Before applying, reset the watermark of any aggregate whose server
    /// identity or start date changed in the draft: that describes a different
    /// series, so the next sync must recompute it from scratch (the server
    /// upserts, so re-sending is safe). New configs have no watermark yet, so
    /// they're skipped — `applyConfiguration` backfills them instead.
    private func resetReidentifiedAggregates() async {
        let applied = Dictionary(uniqueKeysWithValues: appliedConfig.aggregates.map { ($0.id, $0) })
        for agg in config.aggregates {
            guard let old = applied[agg.id] else { continue }
            if old.seriesIdentity != agg.seriesIdentity || old.startDate != agg.startDate {
                await engine.store.resetAggregate(configID: agg.id)
                await engine.eventLog.log(
                    .warn, type: agg.typeIdentifier,
                    "Aggregate \(agg.summaryLabel) reconfigured — next sync recomputes the whole series")
            }
        }
    }

    /// Reverts the staged draft back to what's currently applied.
    func discardChanges() {
        config = appliedConfig
    }

    func syncNow(trigger: String) async {
        // A cold launch's `.active` transition can land before `start()` has
        // loaded the persisted config, in which case the guard below would see
        // the empty default and skip the launch sync.
        await start()
        if trigger == "foreground" {
            // Off the sync's critical path: capabilities only gate UI.
            Task { await refreshServerCapabilities() }
        }
        // Server or not: Explore and Export read under the same limits, and
        // a widened type has to be re-swept before this sync claims it.
        await refreshReadableHistory()
        // observedTypeIdentifiers: an aggregate-only setup (no raw types) still syncs.
        guard !isSyncingAll, config.serverURL != nil,
              !config.observedTypeIdentifiers.isEmpty else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }
        // "foreground" = scenePhase became active; everything else (Sync Now,
        // pull-to-refresh) is user-driven.
        let wakeTrigger: WakeTrigger = trigger == "foreground" ? .foreground : .manual
        let wake = await engine.beginWake(wakeTrigger, detail: trigger)
        // Leaving the app mid-sync used to freeze it where it stood; this buys
        // the run iOS's background grace period and ends it cleanly after.
        let finished = await BackgroundExecution.run("PulsHealth sync") { [engine] in
            await WakeScope.$current.withValue(wake) {
                await engine.syncAllEnabled(reason: .incremental)
            }
        }
        await engine.finishWake(wake, outcome: finished ? .completed : .expired)
    }

    func startBackfill() async {
        guard !isSyncingAll else { return }
        // iOS 26: run as a continued-processing task so the backfill keeps going
        // with system progress UI if the user backgrounds the app (that path
        // records its own wake).
        if #available(iOS 26.0, *), scheduler.startContinuedBackfill() {
            return
        }
        isSyncingAll = true
        defer { isSyncingAll = false }
        let wake = await engine.beginWake(.manual, detail: "foreground backfill")
        let finished = await BackgroundExecution.run("PulsHealth backfill") { [engine] in
            await WakeScope.$current.withValue(wake) {
                await engine.syncAllEnabled(reason: .backfill)
            }
        }
        await engine.finishWake(wake, outcome: finished ? .completed : .expired)
    }

    func syncOne(_ identifier: String) async {
        if HealthTypeCatalog.isActivitySummary(identifier) {
            await engine.syncActivitySummary(reason: .manual)
        } else {
            await engine.sync(type: identifier, reason: .manual)
        }
    }

    /// Pull /v1/stats so type detail screens can confirm device and server agree.
    func refreshServerStats() async {
        do {
            let stats = try await engine.serverStats()
            serverStats = Dictionary(
                stats.map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })
            serverStatsError = nil
        } catch {
            serverStatsError = error.localizedDescription
        }
    }

    func reconcile(_ identifier: String) async {
        guard !reconciling.contains(identifier) else { return }
        reconciling.insert(identifier)
        defer { reconciling.remove(identifier) }
        do {
            _ = try await engine.reconcile(type: identifier)
            await refreshServerStats()
            await refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private static let medicationAuthRequestedKey = "medicationAuthRequested"

    /// True while the per-object medication sheet still has to be shown: the type
    /// is enabled and this install has never asked. One-shot per install, like
    /// the main grant.
    private var medicationAccessNeeded: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return config.enabledTypes.contains(HealthTypeCatalog.medicationDoseIdentifier)
            && !UserDefaults.standard.bool(forKey: Self.medicationAuthRequestedKey)
    }

    /// Medications need HealthKit's per-object authorization sheet (the user picks
    /// which medications the app may read). Apply *starts* it and moves on; it is
    /// deliberately never awaited.
    ///
    /// iOS presents this picker on top of whatever HealthKit view controller is on
    /// screen, and presenting it into one that is still tearing down — the bulk
    /// permission sheet Apply just showed — fails ("whose view is not in the window
    /// hierarchy") *without ever calling back*. Awaited inline, that deadlocked the
    /// first run: `finishOnboarding` never returned, so its spinner never stopped
    /// and the cover never came down, for any selection that merely included
    /// Medication Doses. So the request waits for the flow's cover to go and the
    /// bulk sheet to settle, and it does that off the critical path.
    func scheduleMedicationAccessRequest() {
        guard medicationAccessNeeded, !requestingMedicationAccess else { return }
        requestingMedicationAccess = true
        Task { [weak self] in await self?.requestMedicationAccess() }
    }

    private func requestMedicationAccess() async {
        defer { requestingMedicationAccess = false }
        // Never present over the first-run cover: this can be scheduled from the
        // flow's own Health-access step, minutes before the user reaches the end.
        // Giving up is safe — the final Apply schedules it again.
        var waited = 0
        while showsOnboarding {
            guard waited < 480 else { return }  // 2 minutes
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        // Let the bulk sheet's remote view controller finish dismissing.
        try? await Task.sleep(for: .milliseconds(600))
        guard #available(iOS 26.0, *), medicationAccessNeeded else { return }
        // If iOS swallows the presentation anyway the call below never returns, so
        // the user hears it from here rather than waiting on a picker that never
        // appears. (The stuck request costs nothing: it blocks no UI, and the
        // one-shot flag stays clear so the next Apply retries.)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.requestingMedicationAccess else { return }
            await self.engine.eventLog.log(
                .warn,
                "iOS did not show the medication picker; medication doses stay unauthorized")
            if self.authorizationHint == nil {
                self.authorizationHint = """
                iOS didn't show the medication picker, so medication doses stay \
                unauthorized. Try Save & Apply again, or turn Medication Doses off \
                under Synced Data.
                """
            }
        }
        do {
            try await engine.requestMedicationAuthorization()
            UserDefaults.standard.set(true, forKey: Self.medicationAuthRequestedKey)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        watchdog.cancel()
    }

    /// Clears both the engine's persisted ring buffer and the on-screen list —
    /// the list is a separate array fed by the event stream, so clearing only
    /// the actor left the activity log unchanged until the next launch.
    func clearEvents() async {
        await engine.eventLog.clear()
        events = []
    }

    /// True while any raw type, aggregate, or the rings are mid-run. Gates the
    /// reset buttons: a reset under a running sync is silently undone by that
    /// run's next state write (see `HealthSyncEngine.resetType`).
    var anySyncActive: Bool {
        statuses.contains { $0.activity != .idle }
    }

    /// True while a backfill is running by any path — the in-app one
    /// (`isSyncingAll`) or the iOS 26 continued-processing task, which runs
    /// outside this model and only shows up through the engine's activities.
    var backfillActive: Bool {
        isSyncingAll || typesBackfilling > 0
    }

    func resetType(_ identifier: String) async {
        let name = HealthTypeCatalog.descriptor(for: identifier)?.displayName ?? identifier
        guard await engine.resetType(identifier) else {
            lastErrorMessage = "\(name) is syncing right now. Wait for it to finish, then reset."
            return
        }
        await engine.eventLog.log(
            .warn, type: identifier,
            HealthTypeCatalog.isActivitySummary(identifier)
                ? "Activity rings reset — next sync recomputes from the start date"
                : "Anchor reset — next sync re-exports from start date")
        await refresh()
    }

    func resetAll() async {
        guard await engine.resetAll() else {
            lastErrorMessage = "A sync is in progress. Wait for it to finish, then reset."
            return
        }
        await engine.eventLog.log(.warn, "All anchors reset")
        await refresh()
    }

    // MARK: - Server capabilities

    /// Reconciliation compares `GET /v1/digest` and `GET /v1/uuids`; both must
    /// be advertised. Unknown capabilities hide the controls.
    var serverSupportsReconciliation: Bool {
        serverCapabilities?.supportsReconciliation ?? false
    }

    /// The per-type "Server" rows come from `GET /v1/stats`.
    var serverSupportsStats: Bool {
        serverCapabilities?.supportsStats ?? false
    }

    /// Re-reads the configured server's capabilities. A definitive "no such
    /// endpoint" (404/405, or a body that is not capabilities JSON) clears the
    /// last answer; a transient failure (offline, 5xx) keeps it, so a flaky
    /// network does not make the reconciliation controls flicker.
    func refreshServerCapabilities() async {
        guard config.serverURL != nil, config.authToken != nil else {
            serverCapabilities = nil
            return
        }
        do {
            serverCapabilities = try await engine.serverCapabilities()
        } catch TransportError.serverError(let status, _) where status == 404 || status == 405 {
            serverCapabilities = nil
        } catch is DecodingError {
            serverCapabilities = nil
        } catch {
            // Transient: keep the last known capabilities.
        }
    }

    /// Tests a server URL + token *without saving them* — the Settings screen
    /// calls this with the entered, not-yet-applied values. Nothing is
    /// persisted; a successful answer only refreshes the in-memory
    /// capabilities so the feature gates reflect the server just tested.
    ///
    /// `userID` is the one the entered values would sync as — the draft's,
    /// unless a pairing code staged a different one alongside them
    /// (`ServerFieldsDraft.connectionTestUserID`).
    func testConnection(url: URL, token: String, userID: String? = nil) async -> ConnectionTestResult {
        let deviceID = await engine.store.deviceID
        let tester = ConnectionTester(
            baseURL: url, authToken: token, userID: userID ?? config.userID, deviceID: deviceID)
        let result = await tester.run()
        if case .ok(let capabilities) = result {
            serverCapabilities = capabilities
        }
        lastConnectionTest = ConnectionTestRecord(url: url, result: result, at: Date())
        return result
    }

    // MARK: - Aggregates

    func aggregates(for typeIdentifier: String) -> [AggregateConfig] {
        config.aggregates.filter { $0.typeIdentifier == typeIdentifier }
    }

    func addAggregate(_ aggregate: AggregateConfig) {
        config.aggregates.append(aggregate)
    }

    func updateAggregate(_ aggregate: AggregateConfig) {
        guard let index = config.aggregates.firstIndex(where: { $0.id == aggregate.id }) else { return }
        config.aggregates[index] = aggregate
    }

    func deleteAggregate(id: UUID) {
        config.aggregates.removeAll { $0.id == id }
    }

    /// Clears the watermark so the next sync recomputes the whole series.
    func resetAggregate(id: UUID) async {
        let aggregate = config.aggregates.first { $0.id == id }
        guard await engine.resetAggregate(configID: id) else {
            lastErrorMessage = "\(aggregate?.summaryLabel ?? "This aggregate") is computing right now. Wait for it to finish, then recompute."
            return
        }
        await engine.eventLog.log(
            .warn, type: aggregate?.typeIdentifier,
            "Aggregate \(aggregate?.summaryLabel ?? id.uuidString) reset — next sync recomputes the whole series")
        await refresh()
    }

    func syncAggregate(id: UUID) {
        Task { await engine.syncAggregate(configID: id, reason: .manual) }
    }

    /// Settings → Delete Analysis: every stored type profile. Summaries,
    /// never samples, but still about health data, so there is one switch.
    func deleteAnalysis() async {
        await explore.deleteAll()
        await engine.eventLog.log(.info, "Stored type analyses deleted")
    }

    // MARK: - Derived totals for the Explore and Sync tabs

    var totalSamples: Int { statuses.reduce(0) { $0 + $1.state.totalSamplesExported } }
    var totalBytes: Int { statuses.reduce(0) { $0 + $1.state.totalBytesUploaded } }
    var typesBackfilling: Int { statuses.filter { $0.activity == .backfilling }.count }
    var typesFailed: Int { statuses.filter { $0.state.lastError != nil }.count }
    var backfillRemaining: TimeInterval? {
        let remaining = statuses.compactMap(\.estimatedSecondsRemaining)
        return remaining.isEmpty ? nil : remaining.max()
    }
    /// Whether there is anything to sync and somewhere to sync it — on the
    /// *applied* configuration, which is what the engine runs on. The draft
    /// used to decide this, so a URL typed but not yet saved lit Sync Now
    /// against a server the engine had never been given.
    var configured: Bool {
        appliedConfig.serverURL != nil && !appliedConfig.observedTypeIdentifiers.isEmpty
    }
}
