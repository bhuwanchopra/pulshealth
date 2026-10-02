import Foundation

/// Outcome of one `HealthSyncEngine.reconcile(type:)` run.
public struct ReconciliationReport: Sendable, Equatable {
    public var type: String
    public var windowsChecked: Int = 0
    public var windowsMismatched: Int = 0
    public var samplesReuploaded: Int = 0
    public var orphanDeletionsSent: Int = 0
    /// Months the server has rows for and HealthKit returned nothing for,
    /// where the orphan deletions were withheld (`ReconcileDigest.OrphanVerdict`):
    /// an empty answer is what a type whose Health access is off returns too,
    /// and nothing tells the two apart. Not counted in `windowsMismatched`:
    /// nothing was repaired there.
    public var windowsUnverified: Int = 0
    /// Server rows in those months — what would have been deleted.
    public var orphanDeletionsWithheld: Int = 0
    /// Set when iOS 27's limited history access kept the comparison from
    /// reaching the sync's start date: where it began instead. Nothing older
    /// was checked, and nothing older was deleted.
    public var readableSince: Date?

    public init(type: String) {
        self.type = type
    }

    public var summary: String {
        var counts = windowsMismatched == 0
            ? "\(windowsChecked) windows in sync"
            : "\(windowsMismatched)/\(windowsChecked) windows repaired: +\(samplesReuploaded) samples, -\(orphanDeletionsSent) orphans"
        if windowsUnverified > 0 {
            counts += "; \(windowsUnverified) \(windowsUnverified == 1 ? "window" : "windows") left alone: Health returned nothing where the database has \(orphanDeletionsWithheld) rows"
        }
        guard let readableSince else { return counts }
        return counts + " (from \(readableSince.formatted(date: .abbreviated, time: .omitted)); Health access is limited to recent history)"
    }
}

/// Pure helpers shared with tests: the digest must XOR-fold UUID bytes exactly like
/// the server (per UTC month over sample start dates).
enum ReconcileDigest {
    struct MonthWindow: Sendable, Equatable {
        /// First instant of the UTC month. The server uses this as the digest key
        /// even when the requested range covers only part of that month.
        var monthStart: Date
        /// Exact query bounds, clamped to the configured reconciliation range.
        var start: Date
        var end: Date
    }

    /// Lowercase hex of the byte-wise XOR of all UUIDs (order independent).
    /// All-zero (the empty digest) when the sequence is empty.
    static func hexDigest(of uuids: some Sequence<UUID>) -> String {
        var acc = [UInt8](repeating: 0, count: 16)
        for uuid in uuids {
            withUnsafeBytes(of: uuid.uuid) { bytes in
                for i in 0..<16 { acc[i] ^= bytes[i] }
            }
        }
        return acc.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a month's server orphans — rows the device did not return —
    /// may be deleted.
    enum OrphanVerdict: Sendable, Equatable {
        /// The device returned samples for the month (or the server has
        /// none): what it lacks is gone from Health, and the server follows.
        case delete
        /// The device returned nothing and the server has rows. A type whose
        /// Health read access is off answers every query with exactly that —
        /// no error, no samples — and `HKHealthStore.authorizationStatus(for:)`
        /// reports only *sharing* (write) status, so nothing tells a denied
        /// type from a month the user cleared. Deleting here would wipe the
        /// server copy of a type the user merely switched off, so the rows
        /// stay and the month is reported as unverified.
        case withhold
    }

    /// The deletion rule for one month. `readAccessConfirmed` is the one
    /// case HealthKit can vouch for: iOS 27 listed the type with an earliest
    /// readable date just now (`ReadableLimit.isConfirmed`), which a type set
    /// to None never is, so an empty answer from that date on is the truth
    /// and the orphans go.
    static func orphanVerdict(localCount: Int, serverRows: Int64, readAccessConfirmed: Bool) -> OrphanVerdict {
        guard localCount == 0, serverRows > 0, !readAccessConfirmed else { return .delete }
        return .withhold
    }

    /// Whether a whole run looks like a type the app cannot read: HealthKit
    /// returned nothing in any month while the server has rows, and no
    /// confirmed limit says the device truly has nothing. Nothing was sent
    /// in that case (no samples to re-upload, every deletion withheld), so
    /// the run fails with `SyncError.reconciliationUnreadable` instead of
    /// recording "N windows in sync".
    static func looksUnreadable(localTotal: Int, serverTotal: Int64, readAccessConfirmed: Bool) -> Bool {
        orphanVerdict(localCount: localTotal, serverRows: serverTotal, readAccessConfirmed: readAccessConfirmed) == .withhold
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Consecutive UTC month windows covering exactly [from, to). The first and
    /// last windows are partial when the requested bounds fall inside a month.
    /// An upper bound on a month boundary does not create an empty terminal window.
    static func monthWindows(from: Date, to: Date) -> [MonthWindow] {
        guard from < to else { return [] }
        let calendar = utcCalendar
        var cursor = from
        var out: [MonthWindow] = []
        while cursor < to {
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: cursor))!
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let end = min(nextMonth, to)
            out.append(MonthWindow(monthStart: monthStart, start: cursor, end: end))
            cursor = end
        }
        return out
    }
}
