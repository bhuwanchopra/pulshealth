import Foundation

/// Recent history first, while a type is still backfilling.
///
/// An anchored query from a nil anchor returns a type's history in the order
/// HealthKit stored it, which for most history is roughly oldest first, so a
/// backfill delivers the newest data last. After a reinstall on 2026-09-26 the
/// server's heart rate and steps stayed stuck on the day the old install
/// stopped, for as long as the re-sync took, while a year of samples the
/// server already had went up ahead of them.
///
/// So each run first sends the last `span` of a still-backfilling type through
/// a second anchor of its own (`TypeSyncState.recentAnchorData`), over samples
/// starting at a window start fixed when the stream begins. The first run
/// sends the whole window; later ones only what is new in it, including late
/// Watch data, because the stream is anchored. The sweep then carries on
/// oldest-first and sends those samples again when it reaches them — the
/// server ignores the repeats. Once the backfill completes the stream is
/// dropped and the type's own anchor carries everything.
///
/// The stream's anchor is never used for the sweep, nor the sweep's for the
/// stream: an anchor read under a date-bounded predicate would skip every
/// older sample if it stood in for the type's own (see CLAUDE.md, the
/// aggregate priority window — this is its raw twin).
enum RecentSampleWindow {
    /// A month, the same reach as the aggregate priority window, so the
    /// viewer's daily charts have one when the first minute is over.
    static let span: TimeInterval = AggregateSchedule.priorityWindowSpan

    /// Where a type's recent stream begins, or nil when the sync range is too
    /// short for one to be worth it: under two windows long, the stream would
    /// send most of the backfill twice to get ahead of very little.
    static func start(syncingFrom startDate: Date, now: Date) -> Date? {
        guard startDate < now.addingTimeInterval(-2 * span) else { return nil }
        return now.addingTimeInterval(-span)
    }
}

/// Which of a type's two streams a merged run advances.
enum SweepPass: Sendable {
    /// The type's own anchor, from the configured start date. Its acks are
    /// progress, and a clean drain completes the backfill.
    case main
    /// The recent-window stream of a type still backfilling. Its acks move
    /// only its own anchor; it never completes anything.
    case recent
}
