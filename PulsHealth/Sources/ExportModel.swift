import Foundation
import Observation
import PulsHealthSync
import UIKit

/// State of the Export tab (`ExportView`): the draft being built, the run in
/// flight, and the finished export waiting to be shared.
///
/// Owned by `AppModel` rather than by the view, for two reasons. A run takes
/// minutes on a phone with years of data, and leaving the screen must not end
/// it or lose its result. And the files it stages are health data at rest on
/// the device, which the privacy policy says is short-lived — so their lifetime
/// is managed in one place, here, instead of wherever a view happened to be
/// when it disappeared:
///
/// - `AppModel.init` clears the staging root at every launch, before an export
///   can exist, which also sweeps up whatever a crash or force-quit left;
/// - starting an export deletes the previous one first;
/// - the share sheet reporting `completed` deletes the files it just handed
///   over (`shareFinished`), and Delete Export does it on request.
///
/// None of those can run during an export (`removeAllExports()` must not): the
/// launch one precedes any run, and the rest are refused while `isRunning`.
///
/// The export itself never goes near the app's engine — `HealthExporter` builds
/// a throwaway one per run (CLAUDE.md, "Export never shares sync state"). The
/// real engine is used here for exactly two things: its `deviceID`, so a
/// replayed JSONL is attributed to this install, and — through the `authorize`
/// closure — the HealthKit permission request, which is per-app.
@MainActor
@Observable
final class ExportModel {
    /// A finished export. `result.files` exist on disk until `filesRemoved`.
    struct Finished {
        let result: ExportResult
        /// The draft the run was started from, as it was then.
        let draft: ExportDraft
        /// The range actually used: a preset's title, or the custom dates.
        let rangeLabel: String
        /// The app left the foreground at some point during the run. iOS locks
        /// HealthKit with the device, so this is the usual reason behind a list
        /// of failed types, and the screen says so instead of leaving a column
        /// of "database inaccessible" to be decoded.
        let wasBackgrounded: Bool
        /// True once the share sheet completed and the staged copy was deleted.
        /// The summary stays on screen; the Share button does not.
        var filesRemoved = false
    }

    enum State {
        case idle
        case running(ExportProgress)
        case finished(Finished)
    }

    /// Why the screen is back at its controls without a result, if it is.
    enum Notice: Equatable {
        case cancelled
        case failed(ExportFailureCopy)
    }

    /// What the next export covers. Lives for the session: leaving the tab
    /// keeps it, a launch starts over.
    var draft = ExportDraft()
    /// The draft as it was created, to tell an untouched one from an edited
    /// one (`seedFromApplied`).
    @ObservationIgnored private let pristineDraft: ExportDraft
    private(set) var state: State = .idle
    private(set) var notice: Notice?

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        let initial = ExportDraft()
        draft = initial
        pristineDraft = initial
    }

    // MARK: - The draft

    /// The applied sync selection becomes the draft's starting point, once,
    /// when `AppModel` has loaded it, and only if nothing has been changed yet:
    /// an edit made before the configuration landed is not thrown away, and
    /// an empty applied selection (no sync set up) leaves the common set.
    func seedFromApplied(_ configuration: SyncConfiguration) {
        guard draft == pristineDraft else { return }
        let applied = ExportSelection(configuration: configuration)
        guard !applied.types.isEmpty || !applied.aggregates.isEmpty else { return }
        draft.types = applied.types
        draft.aggregates = applied.aggregates
        draft.includeWorkoutRoutes = applied.includeWorkoutRoutes
        draft.includeWorkoutEnhancedData = applied.includeWorkoutEnhancedData
    }

    /// Add a series to the draft. A series already there (same
    /// `seriesIdentity`, whatever its id) is left alone: an export has no use
    /// for the same buckets twice.
    func addAggregate(_ config: AggregateConfig) {
        guard !draft.aggregates.contains(where: { $0.seriesIdentity == config.seriesIdentity }) else { return }
        draft.aggregates.append(config)
    }

    /// Replace the series with `config.id`, or add it. The edited series may
    /// now match another one; that one goes.
    func updateAggregate(_ config: AggregateConfig) {
        draft.aggregates.removeAll { $0.id != config.id && $0.seriesIdentity == config.seriesIdentity }
        if let index = draft.aggregates.firstIndex(where: { $0.id == config.id }) {
            draft.aggregates[index] = config
        } else {
            draft.aggregates.append(config)
        }
    }

    func removeAggregate(id: UUID) {
        draft.aggregates.removeAll { $0.id == id }
    }

    /// Add a type to the draft ("Export This Type" on a type's page).
    func include(type id: String) {
        draft.types.insert(id)
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Start an export of the draft. `configuration` is the applied one, and
    /// supplies only what `ExportRequest` takes from it: batch size,
    /// concurrency, the user ID and the aggregate grid anchor. What is
    /// exported is the draft's.
    ///
    /// - Parameters:
    ///   - engine: the app's real engine — read for its device ID only.
    ///   - authorize: asks HealthKit for read access to the selection. Awaited,
    ///     because the exporter never prompts and an un-requested type comes
    ///     back as a failure; see `AppModel.requestHealthAccessForExport`.
    func start(
        configuration: SyncConfiguration, engine: HealthSyncEngine,
        authorize: @escaping @MainActor () async -> Void
    ) {
        guard !isRunning else { return }
        // One staged export at a time: the previous one's files go before the
        // new run writes anything. Safe here and nowhere later — nothing is
        // running, and `removeAllExports()` would pull the directory out from
        // under a run that was.
        HealthExporter.removeAllExports()
        notice = nil
        state = .running(ExportProgress(phase: .preparing))
        let draft = draft
        task = Task { [weak self] in
            await self?.run(
                configuration: configuration, draft: draft,
                engine: engine, authorize: authorize)
        }
    }

    /// Cooperative: the sweep stops at its next page, `HealthExporter` deletes
    /// what it wrote and throws `CancellationError`, and `run` lands on idle.
    func cancel() {
        task?.cancel()
    }

    /// Delete Export, and New Export after a share.
    func discard() {
        guard case .finished(let finished) = state else { return }
        if !finished.filesRemoved { HealthExporter.remove(finished.result) }
        state = .idle
    }

    /// The share sheet closed. Only `completed` deletes: a sheet the user
    /// swiped away handed the files to nobody, and they may open it again.
    func shareFinished(completed: Bool) {
        guard completed, case .finished(var finished) = state, !finished.filesRemoved else { return }
        HealthExporter.remove(finished.result)
        finished.filesRemoved = true
        state = .finished(finished)
    }

    // MARK: - The run

    private func run(
        configuration: SyncConfiguration, draft: ExportDraft,
        engine: HealthSyncEngine, authorize: @MainActor () async -> Void
    ) async {
        let format = draft.format
        let zipped = draft.zipped
        let selection = draft.selection()
        let dates = draft.dates()
        let rangeLabel = draft.rangeLabel()
        let coverage = "\(selection.types.count) type\(selection.types.count == 1 ? "" : "s")"
            + (selection.aggregates.isEmpty
                ? "" : ", \(selection.aggregates.count) series")
        // A device that locks mid-run turns every remaining type into a
        // failure, so for the length of the run: no auto-lock, and a
        // background-task assertion so a glance at another app does not
        // suspend the process mid-file. Neither survives the user locking the
        // phone on purpose — `wasBackgrounded` is for that. Both end on every
        // way out of this function.
        let application = UIApplication.shared
        application.isIdleTimerDisabled = true
        // A class, not a captured `var`: the expiration handler is an escaping
        // closure, and it and the `defer` both need to end the same assertion
        // exactly once.
        let assertion = BackgroundAssertion()
        assertion.begin(named: "Health data export")
        let backgrounded = BackgroundWatch()
        defer {
            application.isIdleTimerDisabled = false
            assertion.end()
            backgrounded.stop()
        }

        await authorize()
        // The activity log is the app's account of what it did; an export belongs
        // in it. Counts and outcomes only, like every other line there.
        await engine.eventLog.log(
            .info, "Export to \(zipped ? "zipped " : "")\(format.title) (\(rangeLabel), \(coverage)) started")

        // Progress arrives on the exporter's executor, once per written batch
        // — hundreds of times over a large export, in bursts. Newest-only
        // buffering delivers them to the main actor in order and drops the
        // ones the screen would never have drawn, without a Task per batch.
        let (updates, continuation) = AsyncStream.makeStream(
            of: ExportProgress.self, bufferingPolicy: .bufferingNewest(1))
        let display = Task { [weak self] in
            for await progress in updates {
                guard let self, self.isRunning else { continue }
                self.state = .running(progress)
            }
        }

        let outcome: Result<ExportResult, Error>
        do {
            try Task.checkCancellation()
            let request = ExportRequest(
                selection: selection,
                configuration: configuration,
                startDate: dates.start,
                endDate: dates.end,
                format: format,
                zipped: zipped,
                deviceID: await engine.store.deviceID)
            outcome = .success(try await HealthExporter().run(request) { continuation.yield($0) })
        } catch {
            outcome = .failure(error)
        }
        // Drain the display task before writing the final state, or a progress
        // update still in flight could put `.running` back over it.
        continuation.finish()
        await display.value

        switch outcome {
        case .success(let result):
            state = .finished(Finished(
                result: result, draft: draft, rangeLabel: rangeLabel,
                wasBackgrounded: backgrounded.didEnterBackground))
            let missing = result.failures.count + result.unmappableSamples.count
            await engine.eventLog.log(
                result.isComplete ? .info : .warn,
                "Export finished (\(rangeLabel), \(coverage)): \(result.writtenRows.formatted()) rows, "
                    + "\(Int(result.totalBytes).byteString), \(result.duration.shortDuration)"
                    + (result.isComplete ? "" : " — incomplete, \(missing) type\(missing == 1 ? "" : "s") not fully read"))
        case .failure(let error):
            // A throw always means no files (`HealthExporter.run`).
            state = .idle
            if let copy = ExportFailureCopy(error: error) {
                notice = .failed(copy)
                await engine.eventLog.log(.error, "Export failed: \(copy.title)")
            } else {
                notice = .cancelled
                await engine.eventLog.log(.info, "Export cancelled — nothing kept")
            }
        }
        task = nil
    }
}

/// One `beginBackgroundTask` assertion, ended exactly once whether the run
/// finishes first or iOS calls time on it.
@MainActor
private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(named name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of background time. Ending the assertion is mandatory — iOS
            // kills an app that does not — and it is all this does: the run is
            // left alone, to be suspended with the process and to carry on if
            // the user comes back. What it could not read meanwhile it reports.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Remembers whether the app entered the background while it was watching.
@MainActor
private final class BackgroundWatch {
    private(set) var didEnterBackground = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground = true }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// What the Export tab is about to export, built on the tab and handed to
/// `ExportRequest` as a whole when Export is tapped. Its own thing: it starts
/// from the applied sync selection (`ExportModel.seedFromApplied`) and nothing
/// changed here reaches the configuration the app syncs with.
struct ExportDraft: Equatable {
    /// HealthKit type identifiers (`HealthTypeCatalog`). The common set until
    /// the applied selection is known.
    var types: Set<String> = TypePresets.common
    /// Ad hoc series, independent of the sync config's.
    var aggregates: [AggregateConfig] = []
    var includeWorkoutRoutes = false
    var includeWorkoutEnhancedData = false
    /// The preset in force while `customRange` is false.
    var range: ExportRange = .default
    /// True: the range is `customStart..<customEnd` instead of `range`.
    var customRange = false
    /// Earliest sample start, taken as the start of its local day.
    var customStart: Date
    /// Exclusive end. The screen shows and edits the last *inclusive* day
    /// (`lastCustomDay`), which is the local day before this instant.
    var customEnd: Date
    var format: ExportFormat = .csv
    /// Hand over one `.zip` instead of the loose files (`ExportRequest.zipped`).
    var zipped = false

    init(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        customStart = calendar.date(byAdding: .year, value: -1, to: today) ?? today
        customEnd = now
    }

    func selection() -> ExportSelection {
        ExportSelection(
            types: types,
            aggregates: aggregates,
            includeWorkoutRoutes: includeWorkoutRoutes,
            includeWorkoutEnhancedData: includeWorkoutEnhancedData)
    }

    /// What goes into `ExportRequest.startDate` / `.endDate`. A preset has no
    /// end (nil = now). A custom range starts at the start of its first day
    /// and ends at its exclusive end, unless that end falls in today or later:
    /// a range that reaches today means "to now" (nil), whatever instant of
    /// today the draft happens to hold.
    func dates(now: Date = Date(), calendar: Calendar = .current) -> (start: Date?, end: Date?) {
        guard customRange else { return (range.startDate(now: now, calendar: calendar), nil) }
        let start = calendar.startOfDay(for: customStart)
        let end = customEnd > calendar.startOfDay(for: now) ? nil : customEnd
        return (start, end)
    }

    /// The last day a custom range includes, as the start of that local day.
    func lastCustomDay(calendar: Calendar = .current) -> Date {
        let before = customEnd.addingTimeInterval(-1)
        return calendar.startOfDay(for: max(before, customStart))
    }

    /// Set the custom range's end from its last inclusive day: the exclusive
    /// end is the start of the day after.
    mutating func setLastCustomDay(_ day: Date, calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: day)
        customEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        if customStart > dayStart { customStart = dayStart }
    }

    /// The range in words, for the log and the finished summary: a preset's
    /// title, or "Mar 1 – Jun 30, 2026".
    func rangeLabel(calendar: Calendar = .current) -> String {
        guard customRange else { return range.title }
        let start = calendar.startOfDay(for: customStart)
        let last = lastCustomDay(calendar: calendar)
        if start == last { return start.formatted(date: .abbreviated, time: .omitted) }
        return (start..<last).formatted(date: .abbreviated, time: .omitted)
    }
}
