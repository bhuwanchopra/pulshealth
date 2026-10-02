import Foundation

/// The pure half of an export: what configuration the throwaway engine runs,
/// where each aggregate series starts, and — afterwards — which parts of the
/// sweep did not finish. Kept free of HealthKit so the tests can exercise it.
enum ExportPlan {
    /// What "all time" means as a query bound: 1900-01-01T00:00:00Z.
    ///
    /// Not `.distantPast`, and not `HKHealthStore.earliestPermittedSampleDate()`
    /// — which, measured on the iOS 26 simulator, *is* 0001-01-01. The sweep
    /// does calendar arithmetic on its start date (`startOfDay`, and the rings
    /// query is built from era/year/month/day components), and the local day of
    /// that instant is 31 December, 1 BC in every zone west of Greenwich: era 0,
    /// handed to a HealthKit predicate nobody has ever tested there. 1900 is
    /// before any sample a living person's devices or imports can hold, and is
    /// an ordinary Gregorian date everywhere.
    static let allTimeFloor = Date(timeIntervalSince1970: -2_208_988_800)

    /// True when the selection names anything an export could read. The
    /// applied configuration's version is `ExportSelection(configuration:)`.
    static func hasAnythingToExport(_ selection: ExportSelection) -> Bool {
        !selection.isEmpty
    }

    /// The configuration the throwaway engine runs. Everything that ties the
    /// app's configuration to a server or to a person is removed:
    ///
    /// - no server URL and no token, so `configure` builds no HTTP transport
    ///   and no API client — there is nothing the export engine *could* reach;
    /// - no name, e-mail, date of birth or sex, so `enrich` attaches no
    ///   `{"profile":…}` line to workout batches. That line is the app's
    ///   settings, not HealthKit data, and on a replay it would overwrite the
    ///   server's `users` row with whatever the phone held on export day.
    ///
    /// The selection replaces the configuration's own: `enabledTypes` and the
    /// two workout switches are the request's, and its aggregate list is the
    /// request's with every config enabled — presence in the selection is the
    /// decision, so the completion check below has nothing to wonder about.
    /// Each series gets its start from `alignedAggregateStart` once HealthKit
    /// has said where its data begins. A bounded export (`endDate` set) zeroes
    /// every `settleDelay`: the bound is in the past, and there is nothing
    /// for late Watch data to settle into that the export should wait for.
    static func configuration(
        for request: ExportRequest, floor: Date = allTimeFloor
    ) -> SyncConfiguration {
        var config = request.configuration
        config.serverURL = nil
        config.authToken = nil
        config.userName = nil
        config.userEmail = nil
        config.userDateOfBirth = nil
        config.userBiologicalSex = nil
        config.startDate = request.startDate ?? floor
        config.enabledTypes = request.selection.types
        config.includeWorkoutRoutes = request.selection.includeWorkoutRoutes
        config.includeWorkoutEnhancedData = request.selection.includeWorkoutEnhancedData
        config.aggregates = request.selection.aggregates.map { aggregate in
            var aggregate = aggregate
            aggregate.enabled = true
            if request.endDate != nil { aggregate.settleDelay = 0 }
            return aggregate
        }
        return config
    }

    /// Where an aggregate series should start for this export: the latest of
    /// the export's start, the config's own start and the type's first sample,
    /// floored to a bucket boundary **of the grid the app's real sync uses**.
    ///
    /// Two separate problems are solved here.
    ///
    /// *Extent.* A statistics query returns a bucket for every interval in its
    /// range, data or not. "All time" starts in 1900, so an hourly series
    /// started there is a million null buckets and five hundred queries before
    /// the first real value. Starting at the type's first sample costs one
    /// `limit: 1` query instead.
    ///
    /// *Alignment.* Bucket boundaries are `startOfDay(start) + N × interval`,
    /// so a different start date is a different grid for anything coarser than
    /// a day: weeks begin on another weekday, 17th-to-17th months become
    /// 1st-to-1st. An export on its own grid would still be a valid file, but
    /// replayed into the server that already holds the series it would upsert
    /// a second, interleaved set of buckets beside the first. Snapping to the
    /// real grid keeps a replay an overwrite of the same rows.
    ///
    /// The engine re-anchors on `startOfDay` of whatever this returns, so the
    /// grids agree for day, week and month buckets and for hour/minute
    /// intervals that divide a day evenly. They can still differ for intervals
    /// that do not (5 hours, 7 minutes) and for month series anchored on the
    /// 29th–31st — `docs/export.md` says so rather than this pretending.
    static func alignedAggregateStart(
        for aggregate: AggregateConfig,
        syncStartDate: Date,
        exportStartDate: Date,
        earliestSample: Date,
        calendar: Calendar = .current
    ) -> Date {
        let desired = max(exportStartDate, aggregate.startDate ?? exportStartDate, earliestSample)
        let bucketing = AggregateBucketing(
            anchor: calendar.startOfDay(for: aggregate.startDate ?? syncStartDate),
            intervalValue: aggregate.intervalValue,
            intervalUnit: aggregate.intervalUnit,
            calendar: calendar)
        // Not `floorBoundary`, which clamps to the anchor: an export routinely
        // reaches further back than the sync's start date, and negative bucket
        // indices are ordinary calendar arithmetic.
        return bucketing.start(ofBucket: bucketing.index(of: desired))
    }

    /// The types whose earliest readable date (iOS 27 limited history
    /// access, `HealthSyncEngine.earliestAuthorizedDates`) falls after the
    /// export's start: the ones the files cover only in part. A date at or
    /// before the start cuts nothing off and is left out.
    static func limitedHistory(_ readable: [String: Date], exportStart: Date) -> [String: Date] {
        readable.filter { ReadableHistory.effectiveLimit($0.value, readingFrom: exportStart) != nil }
    }

    /// The issue for an export whose limits HealthKit could not report
    /// (`HealthSyncEngine.currentReadableHistory` answered nil: it failed or
    /// timed out). Nothing failed to read, but nothing says the files reach
    /// back as far as the range asked for either, so the export is not
    /// complete — the honest answer when a limit cannot be ruled out. Nil
    /// when the dates are known, an empty answer included.
    static func readableHistoryIssue(_ readable: [String: Date]?) -> ExportIssue? {
        guard readable == nil else { return nil }
        return ExportIssue(
            message: "iOS could not say how much Health history PulsHealth may read, so these files may start later than the range asked for. Export again to check.")
    }

    // MARK: - Completion

    /// The throwaway store's view of the finished sweep.
    struct Outcome: Sendable {
        var typeStates: [String: TypeSyncState] = [:]
        var aggregateStates: [UUID: AggregateSyncState] = [:]
        var activitySummary = ActivitySummaryState()
        var workoutRoutes = WorkoutEnrichmentState()
        var workoutStreams = WorkoutEnrichmentState()
    }

    /// A warning or error the engine logged, and the phase it was logged in
    /// (`ExportEventCollector`). The phase is what tells a raw type's failure
    /// from its aggregate's: both are logged under the same type identifier.
    struct PhasedEvent: Sendable, Equatable {
        var phase: ExportProgress.Phase
        var event: SyncEvent
    }

    /// Every part of the sweep that did not run to the end.
    ///
    /// The engine reports almost nothing by throwing: a type it cannot read is
    /// logged and skipped, because for a background sync the next wake simply
    /// retries. An export has no next wake, so silence would mean a short file
    /// presented as a whole one. Rather than read intent out of log prose, this
    /// asks the state store the same question the engine asks itself — did the
    /// unit reach its completion marker? — which every failure path (access not
    /// determined, database locked, cancellation, a thrown query, a missing
    /// transport, an unknown identifier) fails the same way, including ones
    /// added later. The store starts empty, so a marker can only have been set
    /// by this run:
    ///
    /// - a raw type: `backfillComplete`, set when its anchored query drained;
    /// - an aggregate series: `lastFullRecomputeAt`, set when the full pass
    ///   (always a full pass, on an empty store) reached its last chunk;
    /// - the rings: `computedThrough`, set even when the query returned no days;
    /// - routes and streams: `lastFullRecomputeAt`, as for aggregates.
    ///
    /// The log supplies only the *wording*: the store's `lastError` when it
    /// recorded one, else the last thing the engine logged for that type in
    /// that phase (the locked-database path logs a warning and records nothing).
    static func failures(
        config: SyncConfiguration, outcome: Outcome, events: [PhasedEvent]
    ) -> [ExportIssue] {
        var issues: [ExportIssue] = []

        func lastMessage(
            in phase: ExportProgress.Phase, type: String, mentioning label: String? = nil
        ) -> String? {
            let candidates = events.filter { $0.phase == phase && $0.event.type == type }
            // Several aggregate series can share a type; the engine names the
            // series in each message, so prefer the one that names this one.
            if let label, let named = candidates.last(where: { $0.event.message.contains(label) }) {
                return named.event.message
            }
            return candidates.last?.event.message
        }

        for identifier in config.enabledTypes.sorted() {
            if HealthTypeCatalog.isActivitySummary(identifier) {
                guard outcome.activitySummary.computedThrough == nil else { continue }
                issues.append(ExportIssue(
                    type: identifier,
                    message: outcome.activitySummary.lastError
                        ?? lastMessage(in: .activity, type: identifier)
                        ?? "Activity rings were not read to the end"))
                continue
            }
            let state = outcome.typeStates[identifier]
            guard state?.backfillComplete != true else { continue }
            issues.append(ExportIssue(
                type: identifier,
                message: state?.lastError
                    ?? lastMessage(in: .samples, type: identifier)
                    ?? "This type was not read to the end"))
        }

        for aggregate in config.aggregates where aggregate.enabled {
            let state = outcome.aggregateStates[aggregate.id]
            guard state?.lastFullRecomputeAt == nil else { continue }
            let label = aggregate.summaryLabel
            let reason = state?.lastError
                ?? lastMessage(in: .aggregates, type: aggregate.typeIdentifier, mentioning: label)
                ?? "not computed to the end"
            // The engine's own sentence already opens with the series label.
            issues.append(ExportIssue(
                type: aggregate.typeIdentifier,
                message: reason.contains(label) ? reason : "Aggregate \(label): \(reason)"))
        }

        if config.enabledTypes.contains(HealthTypeCatalog.workoutIdentifier) {
            let workout = HealthTypeCatalog.workoutIdentifier
            let phases: [(Bool, WorkoutEnrichmentState, ExportProgress.Phase, String)] = [
                (config.includeWorkoutRoutes, outcome.workoutRoutes, .workoutRoutes, "Workout routes"),
                (config.includeWorkoutEnhancedData, outcome.workoutStreams, .workoutStreams, "Workout streams"),
            ]
            for (enabled, state, phase, name) in phases where enabled && state.lastFullRecomputeAt == nil {
                let reason = state.lastError
                    ?? lastMessage(in: phase, type: workout)
                    ?? "not read to the end"
                issues.append(ExportIssue(
                    type: workout,
                    message: reason.hasPrefix(name) ? reason : "\(name): \(reason)"))
            }
        }
        return issues
    }

    /// Warnings worth showing: what the engine logged at `.warn`, minus
    /// anything already quoted as a failure's reason, capped so one bad day in
    /// HealthKit cannot turn a result into a log dump.
    static func warnings(
        from events: [PhasedEvent], excluding failures: [ExportIssue], limit: Int = 50
    ) -> [ExportIssue] {
        // Suffix, not equality: aggregate and workout-phase failures may prefix
        // the engine's sentence with which series or phase it was.
        let quoted = failures.map(\.message)
        let all = events.map(\.event)
            .filter { event in
                event.level == .warn && !quoted.contains { $0.hasSuffix(event.message) }
            }
            .map { ExportIssue(type: $0.type, message: $0.message) }
        guard all.count > limit else { return all }
        return Array(all.prefix(limit))
            + [ExportIssue(message: "…and \(all.count - limit) more warnings")]
    }
}
