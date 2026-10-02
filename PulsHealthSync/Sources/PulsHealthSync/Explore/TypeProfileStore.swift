import Foundation
import os

/// On-disk cache of `TypeProfile`s, one JSON file per type under
/// `Application Support/PulsHealthSync/profiles/`.
///
/// A profile is a scan of every sample of a type — seconds for most types,
/// minutes for heart rate — so it is worth keeping between launches, and it
/// is a summary, not data: no sample, UUID or metadata is in it, which is why
/// it may live on disk at all under the privacy claims the app makes. It is
/// still *about* health data, so it gets the same treatment as the package's
/// other state files (`ProtectedStateFile`: unreadable until first unlock,
/// excluded from backup) and the same epoch-millisecond encoding.
///
/// Separate from `SyncStateStore` by design, not convenience: the sync store
/// holds anchors and watermarks, and this layer must never be in a position
/// to move one. Nothing here is read by the engine.
public actor TypeProfileStore {
    private let directory: URL
    private let logger = Logger(subsystem: PulsLog.subsystem, category: "profiles")
    private var cache: [String: TypeProfile] = [:]

    /// `directory` defaults to `Application Support/PulsHealthSync/profiles/`;
    /// tests pass a temporary one.
    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulsHealthSync", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        ProtectedStateFile.prepareDirectory(dir)
        self.directory = dir
    }

    /// The stored profile for a type, or nil when there is none, it cannot be
    /// decoded, or it was written by another `TypeProfile.currentVersion` —
    /// the last two are deleted on the way out rather than left to fail again.
    public func profile(for identifier: String) -> TypeProfile? {
        if let cached = cache[identifier] { return cached }
        let url = fileURL(for: identifier)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let profile = try? JSONDecoder.puls.decode(TypeProfile.self, from: data),
              profile.version == TypeProfile.currentVersion,
              profile.typeIdentifier == identifier
        else {
            logger.notice("Dropping unreadable or outdated profile for \(identifier)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        cache[identifier] = profile
        return profile
    }

    /// Every readable, current profile, in identifier order.
    public func allProfiles() -> [TypeProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
            .compactMap { profile(for: $0) }
    }

    public func save(_ profile: TypeProfile) throws {
        let data = try JSONEncoder.puls.encode(profile)
        try ProtectedStateFile.write(data, to: fileURL(for: profile.typeIdentifier))
        cache[profile.typeIdentifier] = profile
    }

    public func remove(_ identifier: String) {
        cache[identifier] = nil
        try? FileManager.default.removeItem(at: fileURL(for: identifier))
    }

    public func removeAll() {
        cache = [:]
        try? FileManager.default.removeItem(at: directory)
        ProtectedStateFile.prepareDirectory(directory)
    }

    /// Whether a stored profile still describes what HealthKit holds, judged
    /// from `TypeQuickFacts` (three cheap queries) rather than a rescan.
    ///
    /// Stale when any of: it was computed under another version or a
    /// different catalog unit (the numbers would mean something else); the
    /// oldest or newest sample HealthKit reports has moved — compared only
    /// on the side the profile's range left open, since a bounded profile
    /// never saw the samples outside its range; the caller wants a
    /// different range or lookback; it is older than `maxAge`; the scan did not
    /// finish (a partial profile is worth showing, not worth keeping); or
    /// iOS 27's limited history access cuts the range at another date than
    /// the one the scan ran under (`facts.readableSince`) — a widened grant
    /// above all, which makes history readable that the profile never saw.
    public nonisolated static func isStale(
        _ profile: TypeProfile,
        facts: TypeQuickFacts,
        options: HealthExplorer.ProfileOptions,
        maxAge: TimeInterval? = nil,
        now: Date = Date()
    ) -> Bool {
        guard profile.version == TypeProfile.currentVersion else { return true }
        guard profile.isComplete else { return true }
        if profile.unitString != HealthTypeCatalog.descriptor(for: profile.typeIdentifier)?.unitString {
            return true
        }
        guard profile.lookbackDays == options.lookbackDays, profile.rangeEnd == options.rangeEnd else {
            return true
        }
        // A lookback's start is the day the scan ran, so it moves; `maxAge`
        // is what retires such a profile as the window slides.
        if options.lookbackDays == nil, profile.rangeStart != options.rangeStart { return true }
        if profile.rangeStart == nil, profile.earliestStart != facts.earliestStart { return true }
        if options.rangeEnd == nil, profile.latestStart != facts.latestStart { return true }
        if let maxAge, now.timeIntervalSince(profile.computedAt) > maxAge { return true }
        let limit = ReadableHistory.effectiveLimit(
            facts.readableSince, readingFrom: options.effectiveRangeStart(now: now) ?? ExportPlan.allTimeFloor)
        if ReadableHistory.change(from: profile.readableSince, to: limit) != .unchanged { return true }
        return false
    }

    private func fileURL(for identifier: String) -> URL {
        directory.appendingPathComponent("\(identifier).json")
    }
}
