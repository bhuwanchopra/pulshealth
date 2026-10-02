import Foundation
import HealthKit

/// Server-less, on-demand export of HealthKit data to JSONL or CSV files,
/// optionally zipped into one.
///
/// An export is an ordinary sync sweep pointed at files: the same anchored
/// queries, the same `SampleMapper` and canonical units, the same enrichment
/// and aggregate math, with `ExportFileTransport` standing where
/// `HTTPSyncTransport` would. That is why the files agree with what a server
/// would have received — they are produced by the code that produces that.
///
/// **An export never shares sync state, and this type is the guard.** Anchors
/// and watermarks are keyed per type with no destination dimension
/// (`SyncStateStore`), and the engine advances them whenever its transport
/// returns normally. Run an export through the app's real engine and every
/// sample written to the file is recorded as delivered: the server never gets
/// it, and nothing anywhere reports a problem. So each run builds its own
/// `HealthSyncEngine` over a state store, event log and wake log in a
/// throwaway directory, with an in-memory token store, and deletes the
/// directory afterwards. An empty store is also what makes the export
/// complete: nil anchors mean "everything since the start date".
///
/// What that second engine does *not* do, checked against the engine source:
/// it never calls `startObserving`, so it registers no `HKObserverQuery` and
/// never enables — or disables — background delivery, which is per-app and
/// would otherwise be the real engine's; no `BackgroundSyncScheduler` is built
/// over it, so no `BGTask` is registered or rescheduled; its configuration has
/// no server URL or token, so no HTTP transport or API client exists to reach
/// a network with; its token store is in memory, so the Keychain item is never
/// read or written; and it takes a `WakeLog` of its own, because the default
/// one opens the app's real `wake-log.json` and rewrites any wake still marked
/// running as interrupted. It calls the sweep's phases itself rather than
/// `syncAllEnabled`, leaving out the recent-aggregate priority window: that
/// pass exists to put something on a server's dashboard early, and here it
/// would only write the newest month of every aggregate series twice. The raw
/// twin of that pass, the recent-window stream, is switched off on the engine
/// itself (`recentWindowFirst: false`) for the same reason: `syncTypes` runs
/// it ahead of every sweep, and in a file a sample sent twice is two rows.
///
/// Stateless and `Sendable`; `run` may be called from any actor. One export at
/// a time is the sensible limit — two would contend for the same HealthKit
/// query throughput — but nothing breaks if they overlap.
public final class HealthExporter: Sendable {
    public init() {}

    /// Everything the exporter stages by default lives under this directory
    /// (in the temporary directory, so it is never backed up and iOS may purge
    /// it): one subdirectory per export, plus `.state/` for the throwaway
    /// engines. `removeAllExports()` deletes it whole.
    public static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsHealthExport", isDirectory: true)
    }

    /// Delete every staged export and any throwaway engine state, including
    /// what a crash or force-quit mid-export left behind — a half-built zip in
    /// `NSFileCoordinator`'s scratch directory among it (`ExportZipper`). Call
    /// it at launch and once the share sheet is done with an export's files;
    /// do not call it while an export is running. Returns false if something
    /// could not be removed. Exports written to a caller-supplied
    /// `outputDirectory` are not touched.
    @discardableResult
    public static func removeAllExports() -> Bool {
        let scratchRemoved = ExportZipper.removeScratch()
        let root = stagingRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return scratchRemoved }
        do {
            try FileManager.default.removeItem(at: root)
            return scratchRemoved
        } catch {
            return false
        }
    }

    /// Delete one finished export: its files, and its directory when that is
    /// one the exporter staged itself.
    public static func remove(_ result: ExportResult) {
        for url in result.files { try? FileManager.default.removeItem(at: url) }
        if result.directory.path.hasPrefix(stagingRoot.path) {
            try? FileManager.default.removeItem(at: result.directory)
        }
    }

    /// Run one export to completion.
    ///
    /// Request HealthKit read authorization for the selected types *before*
    /// calling this (`HealthSyncEngine.requestAuthorization(for:)`): the
    /// exporter presents no UI, and a type whose access was never requested
    /// comes back as a failure, not a prompt.
    ///
    /// **Cancellation** is cooperative and prompt: cancel the calling task and
    /// the sweep stops at the next page or batch, every file written so far is
    /// deleted, and `CancellationError` is thrown. The same cleanup runs for
    /// any thrown error, so a throw always means "no files". A *partial*
    /// export — some types read, some not — is not a throw: it returns a
    /// result whose `failures` say what is missing (see `ExportResult`).
    ///
    /// - Parameter progress: Called from an arbitrary executor after each
    ///   written batch and at each phase change.
    /// - Throws: `HealthExportError`, or `CancellationError`.
    public func run(
        _ request: ExportRequest, progress: ExportProgressHandler? = nil
    ) async throws -> ExportResult {
        let started = ContinuousClock.now
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthExportError.healthDataUnavailable
        }
        guard ExportPlan.hasAnythingToExport(request.selection) else {
            throw HealthExportError.nothingSelected
        }
        progress?(ExportProgress(phase: .preparing))

        // The throwaway engine. Everything it persists goes here and is
        // deleted on every exit path; see the type comment for why each of
        // the three stores is passed explicitly.
        let stateDirectory = Self.stagingRoot
            .appendingPathComponent(".state", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        // `readEnd` is the export's end date: the one engine that may carry
        // one (see `HealthSyncEngine.readEnd`), because a bounded sweep marks
        // every backfill complete at the bound, which is right for a store
        // that is about to be deleted and wrong for the app's.
        let engine = HealthSyncEngine(
            store: SyncStateStore(directory: stateDirectory, tokenStore: InMemoryTokenStore()),
            eventLog: SyncEventLog(directory: stateDirectory),
            wakeLog: WakeLog(directory: stateDirectory),
            recentWindowFirst: false,
            readEnd: request.endDate)

        // Checked here, once, and thrown: `syncAllEnabled` makes the same test
        // but answers a locked device by logging and returning, which for an
        // export would be an empty file and no explanation.
        guard await engine.isHealthDataAccessible() else {
            throw HealthExportError.deviceLocked
        }

        var config = ExportPlan.configuration(for: request)
        let aligned = try await alignAggregates(
            config.aggregates, request: request, exportStart: config.startDate, engine: engine)
        config.aggregates = aligned.configs
        await engine.configure(config)
        // iOS 27 limited history access. The sweep reads only what HealthKit
        // allows (and the engine's clamps keep aggregates and rings off the
        // rest), so the files are honest about what they hold; this is what
        // makes the result honest about what they do not. Asked of HealthKit
        // directly: `earliestAuthorizedDates()` answers a failed lookup with
        // the throwaway engine's empty cache, which reads as "nothing is
        // limited" and would let an export of a limited type call itself
        // complete. Unknown is reported instead (`readableHistoryIssue`).
        let readable = await engine.currentReadableHistory(for: config.observedTypeIdentifiers)
        let limitedHistory = ExportPlan.limitedHistory(readable ?? [:], exportStart: config.startDate)

        let createdAt = Date()
        let baseName = "puls-export-\(Self.timestamp(createdAt))"
        let directory = request.outputDirectory ?? Self.stagingRoot.appendingPathComponent(
            "\(baseName)-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let createdDirectory = !FileManager.default.fileExists(atPath: directory.path)
        // A zipped export writes its files into a folder named after it, which
        // is what the archive then holds and what unzipping gives back.
        let contentDirectory = request.zipped
            ? directory.appendingPathComponent(baseName, isDirectory: true) : directory
        let zipURL = directory.appendingPathComponent("\(baseName).zip")
        do {
            try FileManager.default.createDirectory(
                at: contentDirectory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch {
            throw HealthExportError.writeFailed(
                ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit))
        }

        let transport = ExportFileTransport(
            format: request.format, directory: contentDirectory, baseName: baseName,
            deviceID: request.deviceID, progress: progress)
        await engine.setTransport(transport)
        let collector = await ExportEventCollector.start(on: engine.eventLog)

        do {
            try await sweep(
                engine: engine, config: config, selection: request.selection,
                transport: transport, collector: collector)
            await transport.setPhase(.finishing)

            let events = await collector.finish()
            let outcome = await Self.outcome(of: engine, config: config)
            var failures = aligned.issues
                + ExportPlan.failures(config: config, outcome: outcome, events: events)
            let unmappable = await engine.unmappableSampleCounts
            let tally = await transport.tally
            let written = try await transport.finish()
            try Task.checkCancellation()

            guard tally.rows.values.contains(where: { $0 > 0 }) else {
                throw failures.isEmpty ? HealthExportError.noData : HealthExportError.failed(failures)
            }
            // Only once there are files to qualify: with none, "no data" or
            // the read failures above are the answer.
            if let unknown = ExportPlan.readableHistoryIssue(readable) { failures.append(unknown) }

            let rowCounts = tally.rows
            let manifestURL = contentDirectory.appendingPathComponent("\(baseName)-manifest.json")
            let manifest = ExportManifest(
                format: request.format,
                schemaVersion: PulsProtocol.version,
                clientVersion: PulsProtocol.clientVersion,
                createdAt: createdAt,
                startDate: request.startDate,
                endDate: request.endDate,
                userID: config.userID,
                deviceID: request.deviceID ?? engine.store.deviceID,
                timeZone: TimeZone.current.identifier,
                complete: failures.isEmpty && unmappable.isEmpty && limitedHistory.isEmpty,
                types: config.enabledTypes.sorted(),
                aggregates: request.selection.aggregates.map(\.seriesIdentity).sorted(),
                files: written.map { file in
                    ExportManifest.File(
                        name: file.url.lastPathComponent, dataset: file.dataset?.rawValue,
                        rows: file.dataset.map { rowCounts[$0] ?? 0 }, bytes: file.bytes)
                },
                rows: Self.named(rowCounts),
                batches: tally.batches,
                notRepresented: Self.named(tally.notRepresented(in: request.format)),
                unmappableSamples: unmappable,
                limitedHistory: limitedHistory,
                failures: failures)
            let manifestBytes: Int64
            do {
                manifestBytes = try manifest.write(to: manifestURL)
            } catch {
                throw HealthExportError.writeFailed(
                    ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit))
            }

            var files = written.map(\.url) + [manifestURL]
            var totalBytes = written.reduce(manifestBytes) { $0 + $1.bytes }
            var archive: ExportArchive?
            if request.zipped {
                await transport.setPhase(.archiving)
                let zipped: ExportZipper.Zipped
                do {
                    zipped = try await ExportZipper.zip(folder: contentDirectory, to: zipURL)
                } catch {
                    throw HealthExportError.writeFailed(
                        ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit))
                }
                try? FileManager.default.removeItem(at: contentDirectory)
                try Task.checkCancellation()
                archive = ExportArchive(
                    url: zipURL, entries: files.map(\.lastPathComponent), contentBytes: totalBytes)
                files = [zipURL]
                totalBytes = zipped.bytes
            }

            return ExportResult(
                format: request.format,
                directory: directory,
                files: files,
                archive: archive,
                manifestURL: request.zipped ? nil : manifestURL,
                rowCounts: rowCounts,
                notRepresented: tally.notRepresented(in: request.format),
                unmappableSamples: unmappable,
                limitedHistory: limitedHistory,
                failures: failures,
                warnings: ExportPlan.warnings(from: events, excluding: failures),
                totalBytes: totalBytes,
                duration: (ContinuousClock.now - started).seconds)
        } catch {
            // One rule for every way out: a throw leaves no files. A partial
            // file with no manifest beside it to say so is the one artefact
            // this type must never leave lying around.
            collector.cancel()
            await transport.abort()
            if createdDirectory {
                try? FileManager.default.removeItem(at: directory)
            } else if request.zipped {
                // The caller's directory: only what this run put in it.
                try? FileManager.default.removeItem(at: contentDirectory)
                try? FileManager.default.removeItem(at: zipURL)
            }
            throw error
        }
    }

    // MARK: - The sweep

    /// `syncAllEnabled`'s phases in its order, minus the recent-aggregate
    /// priority window (see the type comment), with a checkpoint after each.
    ///
    /// The checkpoints are where the engine's forgiving error handling is
    /// turned back into throws. It catches `CancellationError` per type and
    /// carries on to the next — each of which then fails at its first
    /// cancellation check, so the sweep does drain quickly — and it treats a
    /// transport error as one type's bad day. For an export, cancellation and
    /// a dead disk both end the run.
    private func sweep(
        engine: HealthSyncEngine, config: SyncConfiguration, selection: ExportSelection,
        transport: ExportFileTransport, collector: ExportEventCollector
    ) async throws {
        func begin(_ phase: ExportProgress.Phase) async throws {
            try Task.checkCancellation()
            if let reason = await transport.writeFailure {
                throw HealthExportError.writeFailed(reason)
            }
            await collector.mark(phase)
            await transport.setPhase(phase)
        }

        let sampleTypes = config.enabledTypes.sorted()
            .filter { !HealthTypeCatalog.isActivitySummary($0) }

        if config.enabledTypes.contains(HealthTypeCatalog.activitySummaryIdentifier) {
            try await begin(.activity)
            await engine.syncActivitySummary(reason: .manual)
        }
        if !sampleTypes.isEmpty {
            try await begin(.samples)
            // Any reason but `.incremental` takes the per-type backfill path:
            // full pages, `maxConcurrentTypes` pipelines, heaviest type first.
            await engine.syncTypes(sampleTypes, reason: .manual)
        }
        if !config.aggregates.isEmpty {
            try await begin(.aggregates)
            await engine.syncAllAggregates(reason: .manual)
        }
        if sampleTypes.contains(HealthTypeCatalog.workoutIdentifier) {
            // Keyed on the selection (which `config` was built from, so the
            // engine's own gate on its configuration switch agrees).
            if selection.includeWorkoutRoutes {
                try await begin(.workoutRoutes)
                await engine.syncWorkoutRoutes(reason: .manual)
            }
            if selection.includeWorkoutEnhancedData {
                try await begin(.workoutStreams)
                await engine.syncWorkoutStreams(reason: .manual)
            }
        }
        try Task.checkCancellation()
        if let reason = await transport.writeFailure {
            throw HealthExportError.writeFailed(reason)
        }
    }

    /// Give each aggregate series its start (`ExportPlan.alignedAggregateStart`).
    /// A series whose type has no samples is left out — it could only produce
    /// null buckets — and one whose first-sample query fails is left out *and*
    /// reported, since its statistics queries would fail the same way.
    private func alignAggregates(
        _ aggregates: [AggregateConfig], request: ExportRequest,
        exportStart: Date, engine: HealthSyncEngine
    ) async throws -> (configs: [AggregateConfig], issues: [ExportIssue]) {
        var configs: [AggregateConfig] = []
        var issues: [ExportIssue] = []
        var earliest: [String: Result<Date?, Error>] = [:]
        for var aggregate in aggregates {
            try Task.checkCancellation()
            let type = aggregate.typeIdentifier
            if earliest[type] == nil {
                do {
                    earliest[type] = .success(try await engine.earliestSampleDate(ofType: type))
                } catch {
                    earliest[type] = .failure(error)
                }
            }
            switch earliest[type] {
            case .success(let first?):
                aggregate.startDate = ExportPlan.alignedAggregateStart(
                    for: aggregate,
                    syncStartDate: request.configuration.startDate,
                    exportStartDate: exportStart,
                    earliestSample: first)
                configs.append(aggregate)
            case .failure(let error):
                issues.append(ExportIssue(
                    type: type,
                    message: "Aggregate \(aggregate.summaryLabel): "
                        + ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit)))
            case .success(nil), nil:
                continue
            }
        }
        return (configs, issues)
    }

    private static func outcome(
        of engine: HealthSyncEngine, config: SyncConfiguration
    ) async -> ExportPlan.Outcome {
        let store = engine.store
        var outcome = ExportPlan.Outcome()
        for identifier in config.enabledTypes {
            outcome.typeStates[identifier] = await store.state(for: identifier)
        }
        for aggregate in config.aggregates {
            outcome.aggregateStates[aggregate.id] = await store.aggregateState(for: aggregate.id)
        }
        outcome.activitySummary = await store.activitySummaryState
        outcome.workoutRoutes = await store.workoutRoutesState
        outcome.workoutStreams = await store.workoutStreamsState
        return outcome
    }

    private static func named(_ counts: [ExportDataset: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }

    /// `20260921-143000`, device-local: the name is for the person who will
    /// find the file in Files, and the manifest has the instant.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Engine seam

extension HealthSyncEngine {
    /// Start of the oldest sample of a type, or nil when HealthKit holds none
    /// (or — indistinguishably, by design — read access was denied).
    func earliestSampleDate(ofType identifier: String) async throws -> Date? {
        guard let sampleType = HealthTypeCatalog.descriptor(for: identifier)?.sampleType else {
            throw SyncError.unknownType(identifier)
        }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: sampleType)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: 1)
        return try await descriptor.result(for: healthStore).first?.startDate
    }
}

// MARK: - Event collection

/// Watches the throwaway engine's event log for the length of a run and keeps
/// its warnings and errors, each tagged with the phase it was logged in.
///
/// A live subscription rather than a read of `recent()` afterwards: the log is
/// a 2,000-entry ring and the raw sweep logs a line per page, so on an export
/// of any size the one error that mattered has been evicted long before the
/// run ends. Phase boundaries and the end of the run travel *through* the log
/// as marker events, so they are ordered with everything else and `finish`
/// returns only once every earlier event has been seen — no sleeping, no race
/// with the consuming task.
struct ExportEventCollector: Sendable {
    /// Newest entries kept. Only a run where nearly everything is going wrong
    /// reaches this, and what matters then is the last word on each type.
    static let retained = 1_000

    private let log: SyncEventLog
    private let nonce: String
    private let task: Task<[ExportPlan.PhasedEvent], Never>

    static func start(on log: SyncEventLog) async -> ExportEventCollector {
        let nonce = UUID().uuidString
        // Subscribed before this returns: `stream()` registers its
        // continuation synchronously on the log's actor.
        let stream = await log.stream()
        let task = Task {
            var phase = ExportProgress.Phase.preparing
            var kept: [ExportPlan.PhasedEvent] = []
            for await event in stream {
                if event.message.hasSuffix(nonce) {
                    let words = event.message.split(separator: " ")
                    guard words.count == 4, let next = ExportProgress.Phase(rawValue: String(words[2]))
                    else { break } // the end marker
                    phase = next
                    continue
                }
                guard event.level == .warn || event.level == .error else { continue }
                kept.append(ExportPlan.PhasedEvent(phase: phase, event: event))
                if kept.count > retained { kept.removeFirst(kept.count - retained) }
            }
            return kept
        }
        return ExportEventCollector(log: log, nonce: nonce, task: task)
    }

    func mark(_ phase: ExportProgress.Phase) async {
        await log.log(.debug, "Export phase \(phase.rawValue) \(nonce)")
    }

    func finish() async -> [ExportPlan.PhasedEvent] {
        await log.log(.debug, "Export finished \(nonce)")
        return await task.value
    }

    func cancel() { task.cancel() }
}
