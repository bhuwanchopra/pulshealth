import Foundation
import HealthKit

// iOS 27 limited history access, engine side: asking HealthKit for each
// type's earliest readable date, and re-sweeping a raw type whose access has
// widened. The rules themselves, and why each pass is clamped, are in
// `ReadableHistory`.

/// What HealthKit says one type's earliest readable date is, for a pass
/// about to read it.
struct ReadableLimit: Sendable, Equatable {
    /// The date to stay at or after; nil = unlimited.
    var since: Date?
    /// False when HealthKit could not be asked (device locked, query failed)
    /// and `since` is what the pass last ran under instead. A widening is
    /// never inferred from a stale answer.
    var isFresh: Bool
    /// True when HealthKit listed the type with a date just now: iOS 27
    /// names only types the app may read (a type set to None drops out of
    /// the answer exactly like one with full access), so this is the one
    /// positive proof of read access there is. Reconciliation deletes
    /// orphans from a month the device returned nothing for only with it
    /// (`ReconcileDigest.orphanVerdict`). Never set from a stale answer, and
    /// never before iOS 27.
    var isConfirmed: Bool = false
}

extension HealthSyncEngine {
    /// How often the automatic paths — `syncAllEnabled`, observer wakes,
    /// the per-type entry points — re-read the earliest readable dates. One
    /// HealthKit round trip each; the app forces one on every foreground,
    /// which is when someone may just have changed access in Settings.
    static let readableHistoryInterval: Duration = .seconds(15 * 60)

    /// For the enabled types — raw sync, aggregate series and the rings —
    /// the earliest date iOS 27's limited Health access lets this app read
    /// each one from, by catalog identifier. Only limited types are listed:
    /// empty means unlimited, and is always the answer before iOS 27 or when
    /// built with the iOS 26 SDK (`ReadableHistory.isSupported`).
    ///
    /// Never throws. A locked device or a failed HealthKit query answers with
    /// what the last successful look found, so a caller can show it but must
    /// not treat an empty answer as proof of full access.
    public func earliestAuthorizedDates() async -> [String: Date] {
        let identifiers = await store.configuration.observedTypeIdentifiers
        if let dates = await currentReadableHistory(for: identifiers) { return dates }
        return readableHistory.filter { identifiers.contains($0.key) }
    }

    /// One HealthKit round trip for `identifiers`, or nil when the answer is
    /// unknown: the device is locked, or HealthKit failed (logged, scrubbed).
    func currentReadableHistory(for identifiers: Set<String>) async -> [String: Date]? {
        guard ReadableHistory.isSupported, !identifiers.isEmpty else { return [:] }
        guard await ProtectedData.isAvailable else { return nil }
        do {
            return try await ReadableHistory.query(identifiers, in: healthStore)
        } catch {
            await eventLog.log(.warn, "Could not read how much Health history is readable: \(error)")
            return nil
        }
    }

    /// The limit a pass over `identifier` must stay within: HealthKit's
    /// answer now, or — when it cannot give one — `recorded`, the date the
    /// pass last ran under, so a pass that was clamped stays clamped. A
    /// widening HealthKit reports stands only once it has returned a sample
    /// older than `recorded` (`confirmedLimit`).
    func readableLimit(for identifier: String, recorded: Date?) async -> ReadableLimit {
        guard let dates = await currentReadableHistory(for: [identifier]) else {
            return ReadableLimit(since: recorded, isFresh: false)
        }
        return ReadableLimit(
            since: await confirmedLimit(for: identifier, recorded: recorded, reported: dates[identifier]),
            isFresh: true,
            isConfirmed: dates[identifier] != nil)
    }

    /// `reported`, unless it is a widening HealthKit cannot back with a
    /// sample older than `recorded` — then `recorded`
    /// (`ReadableHistory.resolve`). Access switched to None looks exactly
    /// like a lifted limit in `earliestAuthorizedSampleDate(for:)`, and
    /// acting on it would reset a series with nothing left to clamp it.
    func confirmedLimit(for identifier: String, recorded: Date?, reported: Date?) async -> Date? {
        guard let recorded, ReadableHistory.change(from: recorded, to: reported) == .widened else {
            return reported
        }
        let older = await ReadableHistory.hasHistory(
            of: identifier, endingBefore: recorded, in: healthStore)
        let resolved = ReadableHistory.resolve(recorded: recorded, reported: reported, olderHistoryFound: older)
        if !older {
            await eventLog.log(
                .debug, type: identifier,
                "Health access reports a wider limit (\(Self.day(reported))), but nothing older than \(Self.day(recorded)) can be read — access may be set to None; still reading only from \(Self.day(recorded))")
        }
        return resolved
    }

    /// Re-read every enabled type's earliest readable date, note what moved,
    /// and re-sweep raw types whose access has widened. Returns the dates.
    ///
    /// A widening — the date moved earlier, or the limit went away, and
    /// HealthKit returns a sample older than the recorded date to prove it
    /// (`confirmedLimit`; access set to None reports no limit too) — means
    /// history the sync could not read is readable now. A raw type's anchor
    /// is past everything it has read and would never return those samples
    /// (an anchor taken under a limit returns nothing older after the limit
    /// is lifted — measured on the iOS 27.0 simulator), so a type with
    /// progress has its anchors reset and its backfill reopened
    /// (`SyncStateStore.restartBackfillForWidenedAccess`) and the next sweep
    /// reads the whole history again; the server keeps what it already has.
    /// The same date again resets nothing, and a narrowing only records the
    /// new date. Aggregates, the rings and the workout phases keep their own
    /// record and act on it when they next run.
    ///
    /// A widened type another run holds is left alone — not even its new
    /// date is written, or that run could ack a page read under the old
    /// limit after the record says there is none — for the next refresh,
    /// which is then not rate-limited. At most every `readableHistoryInterval` unless
    /// `force`; call it before claiming types. Does nothing before iOS 27.
    @discardableResult
    public func refreshReadableHistory(force: Bool = false) async -> [String: Date] {
        guard ReadableHistory.isSupported else { return [:] }
        if !force, let checkedAt = readableHistoryCheckedAt,
           ContinuousClock.now - checkedAt < Self.readableHistoryInterval {
            return readableHistory
        }
        let config = await store.configuration
        guard let current = await currentReadableHistory(for: config.observedTypeIdentifiers) else {
            return readableHistory
        }
        var deferred = false
        for identifier in config.enabledTypes.sorted()
        where HealthTypeCatalog.descriptor(for: identifier)?.sampleType != nil {
            let state = await store.state(for: identifier)
            let since = await confirmedLimit(
                for: identifier, recorded: state.readableSince,
                reported: ReadableHistory.effectiveLimit(current[identifier], readingFrom: config.startDate))
            let change = ReadableHistory.change(from: state.readableSince, to: since)
            switch ReadableHistory.refreshAction(
                change: change, hasProgress: ReadableHistory.hasRawProgress(state),
                isActive: activeSyncs.contains(identifier)) {
            case .none:
                continue
            case .deferUntilReleased:
                deferred = true
            case .record:
                await store.recordReadableSince(identifier, since)
                if change == .narrowed {
                    await eventLog.log(
                        .info, type: identifier,
                        "Health access is limited to data from \(Self.day(since)) on"
                            + (ReadableHistory.hasRawProgress(state)
                                ? " — what was already synced stays on the server"
                                : " — older history is not read until access is widened"))
                }
            case .resweep:
                // Held for the reset, like `resetType`: a run that started
                // now would persist its old anchor over it.
                activeSyncs.insert(identifier)
                await store.restartBackfillForWidenedAccess(identifier, readableSince: since)
                activeSyncs.remove(identifier)
                await eventLog.log(
                    .info, type: identifier,
                    "Health access widened (data from \(Self.day(state.readableSince)) → \(Self.day(since))) — re-reading this type's whole history; the server keeps what it already has")
            }
        }
        readableHistory = current
        readableHistoryCheckedAt = deferred ? nil : .now
        notifyChanged()
        return current
    }

    /// "Sep 1, 2026", or "all of it" for no limit — for log lines.
    static func day(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "all of it"
    }
}
