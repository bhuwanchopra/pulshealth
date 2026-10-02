import Foundation
import HealthKit

// The last two phases of `syncAllEnabled`: GPS routes, then intra-workout
// streams, run *after* all basic data is synced.
//
// Two failures motivated this design, both seen on real devices:
//
//   1. CONTENTION. Attaching routes + series inline to every workout batch starved
//      the rest of the sync: a workout batch couldn't upload until many per-workout
//      HealthKit queries finished, so the server idled waiting on the phone
//      (parse_ms ballooned, throughput collapsed). Fix: move enrichment to its own
//      late phases so basic data finishes first.
//
//   2. OVERSIZED BATCHES → INFINITE RETRY. Uploading an entire page of workouts'
//      streams as one atomic batch produced batches too big to upload+insert inside
//      the client request timeout. The phone cancelled mid-insert ("context
//      canceled"), the server transaction rolled back (nothing committed), the
//      watermark never advanced, and the resync re-sent the SAME oversized batch —
//      forever. Fix (this file): chunk enrichment by a *point budget*, split a
//      single workout's points across as many batches as needed, upload
//      sequentially, and advance the watermark per fully-acked workout.
//
// No wire/server changes are needed for either fix. Routes and series already ride
// their own NDJSON lines (`{"route":...}` / `{"series":...}`) carrying the workout
// UUID, and the server inserts them by joining on that UUID with
// `ON CONFLICT DO NOTHING`. So a workout row can land in the raw sweep, and its
// routes/series can arrive split across many later batches — fully idempotent
// end-to-end.
//
// Like activity summaries (see ActivitySummarySync) these have no HKQueryAnchor:
// each phase enumerates workouts ascending by `endDate`, uploads point-capped
// route-/series-only batches, and advances a singleton `computedThrough` watermark
// to each workout's `endDate` only after *all* of that workout's chunks are acked
// (anchor-after-ack). A trailing lookback re-covers recent workouts that gained
// late Watch data, and a ~monthly full pass repairs older edits.

/// A workout-enrichment payload (route or series) whose points can be split so a
/// single workout's data never exceeds one batch's point budget.
protocol EnrichmentPayload {
    var pointCount: Int { get }
    /// A copy of this payload carrying only `points[range]` (same workout UUID /
    /// type / unit), so splitting stays idempotent server-side.
    func slice(_ range: Range<Int>) -> Self
}

extension RoutePayload: EnrichmentPayload {
    var pointCount: Int { points.count }
    func slice(_ range: Range<Int>) -> RoutePayload {
        RoutePayload(workoutUUID: workoutUUID, points: Array(points[range]))
    }
}

extension WorkoutSeriesPayload: EnrichmentPayload {
    var pointCount: Int { points.count }
    func slice(_ range: Range<Int>) -> WorkoutSeriesPayload {
        WorkoutSeriesPayload(workoutUUID: workoutUUID, type: type, unit: unit, points: Array(points[range]))
    }
}

enum WorkoutEnrichmentSchedule {
    /// Pick the lower bound for one enrichment run. Any initial, monthly, or
    /// forced full pass resumes from its own persisted per-workout cursor.
    static func window(
        startDate: Date,
        computedThrough: Date?,
        lastFullRecomputeAt: Date?,
        fullRecomputeStartedAt: Date?,
        fullRecomputeThrough: Date?,
        now: Date
    ) -> (from: Date, fullPass: Bool) {
        let fullPass = fullRecomputeStartedAt != nil || computedThrough == nil
            || lastFullRecomputeAt.map {
                now.timeIntervalSince($0) > AggregateSchedule.fullRecomputeInterval
            } ?? true
        if fullPass {
            if let fullRecomputeThrough {
                // Re-cover one second so workouts sharing the cursor's end time
                // cannot be skipped by boundary semantics. Uploads are idempotent.
                return (max(startDate, fullRecomputeThrough.addingTimeInterval(-1)), true)
            }
            return (startDate, true)
        }
        let lookback = AggregateSchedule.lookback(intervalSeconds: 86_400)
        let cursor = computedThrough ?? startDate
        return (max(startDate, cursor.addingTimeInterval(-lookback)), false)
    }
}

extension HealthSyncEngine {
    /// Pack point-bearing payloads into batches whose total point count never
    /// exceeds `budget`, splitting an individual payload (and thus a single
    /// pathological workout) across batches when it alone exceeds the budget.
    /// Shared by both enrichment phases. Empty payloads are dropped.
    static func packByPointBudget<T: EnrichmentPayload>(_ payloads: [T], budget: Int) -> [[T]] {
        let cap = max(1, budget)
        var batches: [[T]] = []
        var current: [T] = []
        var currentCount = 0
        for payload in payloads {
            let total = payload.pointCount
            guard total > 0 else { continue }
            var offset = 0
            while offset < total {
                if currentCount >= cap {
                    batches.append(current)
                    current = []
                    currentCount = 0
                }
                let take = min(total - offset, cap - currentCount)
                current.append(payload.slice(offset ..< offset + take))
                currentCount += take
                offset += take
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// `HKWorkoutActivityType`s that record a GPS route — outdoor, location-based.
    /// Used only as the "definitely query" half of `mayHaveWorkoutRoute`; missing
    /// one is harmless (it falls through to the conservative default).
    static let routeCapableActivityTypes: Set<HKWorkoutActivityType> = [
        .walking, .running, .cycling, .hiking, .swimming,
        .wheelchairWalkPace, .wheelchairRunPace,
        .crossCountrySkiing, .downhillSkiing, .snowboarding, .skatingSports,
        .paddleSports, .rowing, .sailing, .surfingSports, .golf, .hunting, .fishing,
    ]

    /// `HKWorkoutActivityType`s that are stationary / indoor and never record a GPS
    /// route — the only types we skip the route query for. Kept deliberately small
    /// and unambiguous; ambiguous types (could be indoor or outdoor) are left off so
    /// they're still queried.
    static let nonRouteActivityTypes: Set<HKWorkoutActivityType> = [
        .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining,
        .yoga, .pilates, .barre, .flexibility, .cooldown, .mindAndBody,
        .preparationAndRecovery, .stairClimbing, .elliptical, .jumpRope, .stepTraining,
    ]

    /// Whether to bother running the route query for a workout. Conservative: only
    /// the explicit `nonRouteActivityTypes` are skipped; route-capable and every
    /// other (unknown / ambiguous) type is queried, so a real route is never dropped.
    static func mayHaveWorkoutRoute(_ type: HKWorkoutActivityType) -> Bool {
        if routeCapableActivityTypes.contains(type) { return true }
        if nonRouteActivityTypes.contains(type) { return false }
        return true // unsure → query rather than risk dropping a route
    }

    /// Routes phase: fetch and upload GPS routes for workouts. Overlap-guarded.
    public func syncWorkoutRoutes(reason: SyncReason = .incremental) async {
        await runGuardedWorkoutEnrichment(.routes, reason: reason)
    }

    /// Streams phase: fetch and upload the intra-workout streams (HR/power/cadence/…).
    /// Overlap-guarded.
    public func syncWorkoutStreams(reason: SyncReason = .incremental) async {
        await runGuardedWorkoutEnrichment(.streams, reason: reason)
    }

    func runGuardedWorkoutEnrichment(
        _ kind: WorkoutEnrichmentKind,
        reason: SyncReason,
        queueResyncWhenActive: Bool = true
    ) async {
        let key = "workout-enrich:\(kind.rawValue)"
        guard !activeSyncs.contains(key) else {
            // Ordinary observer/manual requests coalesce in memory. Forced
            // requests are already durable and the active loop checks the store
            // before exiting, so adding a second wake-up is unnecessary.
            if queueResyncWhenActive { pendingResync.insert(key) }
            return
        }
        activeSyncs.insert(key)
        defer { activeSyncs.remove(key) }

        var nextReason = reason
        while true {
            // This one store operation clears pending intent and resets the
            // durable full-pass cursor. A crash on either side is recoverable.
            let forcedRestart = await store.consumeForcedWorkoutEnrichmentFullRecompute(kind)
            await runWorkoutEnrichmentSync(
                kind, reason: forcedRestart ? .reconciliation : nextReason)
            nextReason = .incremental
            let pending = pendingResync.remove(key) != nil
            let forcedPending = await store.hasForcedWorkoutEnrichmentFullRecompute(kind)
            if !pending && !forcedPending { break }
        }
    }

    private func runWorkoutEnrichmentSync(
        _ kind: WorkoutEnrichmentKind, reason: SyncReason
    ) async {
        await ensureTransport()
        let typeID = HealthTypeCatalog.workoutIdentifier
        guard let transport else {
            await eventLog.log(.error, type: typeID, "No transport configured — set server URL and token")
            return
        }

        let config = await store.configuration
        // Self-gate on the relevant config flag; a disabled phase is a no-op.
        switch kind {
        case .routes: guard config.includeWorkoutRoutes else { return }
        case .streams: guard config.includeWorkoutEnhancedData else { return }
        }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: config.startDate)
        let now = Date()
        let budget = config.maxEnrichmentPointsPerBatch
        var state = await store.workoutEnrichmentState(kind)
        // iOS 27 limited history access: nothing to clamp here — this phase
        // only follows workouts HealthKit returns, and routes and streams
        // insert without overwriting — but the workouts older than the
        // earliest readable date were invisible to it, and its watermark is
        // past them. A widened grant therefore starts the phase over from
        // the start date (`ReadableHistory`).
        let readable = await readableLimit(for: typeID, recorded: state.readableSince)
        let since = ReadableHistory.effectiveLimit(readable.since, readingFrom: startDay)
        if readable.isFresh {
            switch ReadableHistory.change(from: state.readableSince, to: since) {
            case .widened:
                await store.resetWorkoutEnrichment(kind)
                await eventLog.log(
                    .info, type: typeID,
                    "Workout \(kind.rawValue): Health access widened — re-reading every workout from the start date")
                fallthrough
            case .narrowed:
                await store.updateWorkoutEnrichment(kind) { $0.readableSince = since }
                state = await store.workoutEnrichmentState(kind)
            case .unchanged:
                break
            }
        }
        let fullPassDue = state.computedThrough == nil
            || state.lastFullRecomputeAt.map {
                now.timeIntervalSince($0) > AggregateSchedule.fullRecomputeInterval
            } ?? true
        let fullPass = state.fullRecomputeStartedAt != nil || fullPassDue
        if fullPass, state.fullRecomputeStartedAt == nil {
            let legacyCursor = FullRecomputeMigration.legacyInitialCursor(
                computedThrough: state.computedThrough,
                lastFullRecomputeAt: state.lastFullRecomputeAt,
                fullRecomputeStartedAt: state.fullRecomputeStartedAt)
            await store.beginWorkoutEnrichmentFullRecompute(
                kind, at: now, resumeThrough: legacyCursor)
            state = await store.workoutEnrichmentState(kind)
        }

        // Window [from, now]: a full pass goes to the start date; otherwise trail
        // the watermark by a lookback so recent workouts that gained late Watch
        // route/HR data self-heal. Reuse the day-interval lookback (7 days) that
        // activity summaries use — workouts are at least as sparse as days.
        let schedule = WorkoutEnrichmentSchedule.window(
            startDate: startDay,
            computedThrough: state.computedThrough,
            lastFullRecomputeAt: state.lastFullRecomputeAt,
            fullRecomputeStartedAt: state.fullRecomputeStartedAt,
            fullRecomputeThrough: state.fullRecomputeThrough,
            now: now
        )
        let from = schedule.from
        guard from <= now else { return }

        let runStart = ContinuousClock.now
        let enricher = SeriesEnricher(healthStore: healthStore)
        do {
            // Ascending by endDate: the watermark advances workout-by-workout, so a
            // mid-phase timeout loses at most the in-flight workout.
            let workouts = try await fetchWorkouts(endedAfter: from)
            var totalWorkouts = 0
            var totalBatches = 0
            for workout in workouts {
                try Task.checkCancellation()
                let batches = try await enrichmentBatches(
                    kind, for: workout, enricher: enricher, budget: budget, reason: reason)
                if batches.isEmpty {
                    // No enrichment (no GPS / no streamable curves) — trivially
                    // complete; still advance the watermark past it.
                    await store.advanceWorkoutEnrichmentWatermark(kind, to: workout.endDate, workouts: 1)
                } else {
                    try await uploadWorkoutEnrichment(
                        kind, batches: batches, workoutEnd: workout.endDate, transport: transport)
                    totalBatches += batches.count
                    notifyChanged()
                }
                totalWorkouts += 1
            }
            // Tail: nudge the watermark to now so a later run's lookback starts
            // after the last workout rather than rescanning from its endDate.
            await store.advanceWorkoutEnrichmentWatermark(kind, to: now)
            if fullPass {
                await store.markWorkoutEnrichmentFullRecompute(kind, at: now)
            }
            let elapsed = (ContinuousClock.now - runStart).seconds
            await eventLog.log(
                .info, type: typeID,
                "Workout \(kind.rawValue): \(totalWorkouts) workout(s), \(totalBatches) batch(es), \(String(format: "%.1f", elapsed))s\(fullPass ? " (full recompute)" : "")")
            notifyChanged()
        } catch let error as HKError where error.code == .errorAuthorizationNotDetermined {
            await store.recordWorkoutEnrichmentError(kind, error: SyncError.authorizationNotDetermined)
            await eventLog.log(.error, type: typeID, "Workout \(kind.rawValue): Health access not determined")
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            // Device locked — expected in background; watermark untouched.
            await eventLog.log(.warn, type: typeID, "Workout \(kind.rawValue): Health database locked — will retry on next wake")
        } catch is CancellationError {
            // Background time expired mid-phase. Not a failure: the watermark
            // sits at the last fully-acked workout and the next wake resumes.
            await eventLog.log(.debug, type: typeID, "Workout \(kind.rawValue): cancelled — will resume on next wake")
        } catch {
            await store.recordWorkoutEnrichmentError(kind, error: error)
            await eventLog.log(.error, type: typeID, "Workout \(kind.rawValue) sync failed: \(error)")
        }
        notifyChanged()
    }

    /// Build one workout's point-capped enrichment batches (route- or series-only).
    /// A single workout that exceeds the budget yields several batches; one with no
    /// enrichment yields none. Best-effort for *data* problems: a workout whose
    /// route or stream query fails on its own yields nothing rather than failing
    /// the phase. Errors that mean HealthKit could not be read at all (locked
    /// device, undetermined access, cancellation) propagate instead — an empty
    /// result there is not "no enrichment", and the caller advances the watermark
    /// past every workout that yields no batches.
    private func enrichmentBatches(
        _ kind: WorkoutEnrichmentKind, for workout: HKWorkout,
        enricher: SeriesEnricher, budget: Int, reason: SyncReason
    ) async throws -> [SyncBatch] {
        let deviceID = store.deviceID
        let typeID = HealthTypeCatalog.workoutIdentifier
        switch kind {
        case .routes:
            // Skip the HKWorkoutRoute query entirely for activity types that can't
            // record GPS (indoor strength/yoga/elliptical/…) — querying them just
            // returns empty. Conservative: anything not known-indoor is still
            // queried, so we never drop a real route for a new/unanticipated type.
            guard Self.mayHaveWorkoutRoute(workout.workoutActivityType) else { return [] }
            let payloads: [RoutePayload]
            do {
                payloads = try await enricher.routePayloads(for: workout)
            } catch {
                if SeriesEnricher.isPhaseAbortingError(error) { throw error }
                // No sample UUID in the log: it is persisted and exported.
                await eventLog.log(
                    .warn, type: typeID,
                    "Workout route unavailable for a \(workout.workoutActivityType.rawValue) workout ending \(workout.endDate.formatted(date: .numeric, time: .omitted)): \(error) — skipping routes for this workout")
                payloads = []
            }
            return Self.packByPointBudget(payloads, budget: budget).map {
                SyncBatch(deviceID: deviceID, type: typeID, reason: reason,
                          samples: [], deletions: [], routes: $0, series: [])
            }
        case .streams:
            let payloads = try await enricher.seriesPayloads(for: workout)
            return Self.packByPointBudget(payloads, budget: budget).map {
                SyncBatch(deviceID: deviceID, type: typeID, reason: reason,
                          samples: [], deletions: [], routes: [], series: $0)
            }
        }
    }

    /// Upload all of one workout's enrichment batches sequentially (low
    /// concurrency, by design — enrichment must not recreate the contention that
    /// starved basic data), recording each, then advance the watermark to
    /// `workoutEnd`. Throws *without advancing* if any chunk fails, so a timeout
    /// mid-workout leaves the watermark at the previous fully-acked workout and the
    /// next run simply retries this one (idempotent server-side). Internal so the
    /// regression test can exercise the advance-after-last-chunk guarantee without
    /// a live HealthKit store.
    func uploadWorkoutEnrichment(
        _ kind: WorkoutEnrichmentKind, batches: [SyncBatch], workoutEnd: Date,
        transport: SyncTransport
    ) async throws {
        for batch in batches {
            try Task.checkCancellation()
            let result = try await transport.upload(batch)
            let points = batch.routes.reduce(0) { $0 + $1.points.count }
                + batch.series.reduce(0) { $0 + $1.points.count }
            await store.recordWorkoutEnrichmentBatch(kind, payloads: points, bytes: result.bytesSent)
        }
        await store.advanceWorkoutEnrichmentWatermark(kind, to: workoutEnd, workouts: 1)
    }

    /// All workouts whose `endDate` is at or after `endedAfter`, ascending by end
    /// date. Routes/series aren't anchored, so this is a plain sample query (not an
    /// anchored one) over `HKWorkoutType`; the enrichment phases re-cover a trailing
    /// window each run for self-heal.
    private func fetchWorkouts(endedAfter: Date) async throws -> [HKWorkout] {
        var predicates = [
            HKQuery.predicateForSamples(withStart: endedAfter, end: nil, options: .strictEndDate),
        ]
        if let readEnd {
            // An export's engine: follow only the workouts its raw sweep
            // exported, which are the ones that started before the bound.
            predicates.append(
                HKQuery.predicateForSamples(withStart: nil, end: readEnd, options: .strictStartDate))
        }
        let predicate = HKSamplePredicate<HKSample>.sample(
            type: HKWorkoutType.workoutType(),
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\.endDate, order: .forward)]
        )
        let results = try await descriptor.result(for: healthStore)
        return results.compactMap { $0 as? HKWorkout }
    }
}
