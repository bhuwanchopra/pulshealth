import Foundation
import os

/// What caused the app to do work — i.e. how it got execution time. This is the
/// dimension a background-time field study actually wants: `reason` (on the wire)
/// describes *what kind of sync* ran; `WakeTrigger` describes *what woke us up*.
public enum WakeTrigger: String, Codable, Sendable, CaseIterable {
    /// HKObserverQuery background delivery relaunched/notified the app.
    case observer
    /// Periodic BGProcessingTask safety-net catch-up.
    case backgroundProcessing
    /// iOS 26 BGContinuedProcessingTask (user-initiated backfill, system UI).
    case backgroundContinued
    /// The user brought the app to the foreground (scenePhase → active).
    case foreground
    /// The user tapped Sync Now / pull-to-refresh / Start Backfill.
    case manual

    public var displayName: String {
        switch self {
        case .observer: return "Observer"
        case .backgroundProcessing: return "BG Processing"
        case .backgroundContinued: return "Continued"
        case .foreground: return "Foreground"
        case .manual: return "Manual"
        }
    }

    /// True for the triggers that represent the system granting us background
    /// execution time (the thing the field study counts), as opposed to the user
    /// actively driving the app.
    public var isBackground: Bool {
        switch self {
        case .observer, .backgroundProcessing, .backgroundContinued: return true
        case .foreground, .manual: return false
        }
    }
}

/// Ambient identity of the wake currently doing work, propagated to every nested
/// sync task and the transport via Swift's task-local inheritance. Set once at
/// each wake entry point (`WakeScope.$current.withValue { … }`); read deep in the
/// engine to attribute uploaded batches, and in `HTTPSyncTransport` to stamp the
/// `X-Wake-ID` / `X-Wake-Trigger` headers so the server's `batches` rows join
/// back to the device's wake records.
public enum WakeScope {
    @TaskLocal public static var current: WakeContext?
}

/// The handle returned by `HealthSyncEngine.beginWake` — pass it to
/// `WakeScope.$current.withValue` and to `finishWake`.
public struct WakeContext: Sendable, Equatable {
    public let id: UUID
    public let trigger: WakeTrigger
    public let startedAt: Date

    public init(id: UUID = UUID(), trigger: WakeTrigger, startedAt: Date = Date()) {
        self.id = id
        self.trigger = trigger
        self.startedAt = startedAt
    }
}

/// One durable record of a single wake: when the app got execution time, why,
/// what it did with it, and how it ended. This is the primary artifact of the
/// background-time study — append-only, survives launches/crashes, and exports
/// to CSV/JSON for offline analysis.
public struct WakeRecord: Identifiable, Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// In flight (only seen transiently, or after a crash — see `.interrupted`).
        case running
        /// Work completed normally.
        case completed
        /// A background task hit its expiration handler before finishing.
        case expired
        /// The wake threw before finishing.
        case failed
        /// Loaded from disk still `.running`: the app was killed mid-wake (force
        /// quit, OOM, or the system reclaimed the background task) before it could
        /// record completion. A useful signal in its own right.
        case interrupted
        /// The device was locked, so HealthKit was unreadable and the wake did
        /// no work on purpose. Distinct from `.completed` so the Background
        /// Activity screen can show "this wake was never going to work" rather
        /// than reporting a successful sync that moved nothing.
        case skippedLocked
    }

    public let id: UUID
    public let trigger: WakeTrigger
    public let startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome
    /// Free-form context captured at the wake (e.g. the types an observer fired for).
    public var detail: String?
    /// Seconds since the *previous* wake started — the inter-wake gap that answers
    /// "how often do I get background time". Nil for the first recorded wake.
    public var gapSinceLastWake: TimeInterval?

    // Work done during this wake (accumulated across all of its uploaded batches).
    public var batches: Int
    public var samples: Int
    public var deletions: Int
    public var bytes: Int
    /// Distinct type identifiers (and `agg:<id>` / activity-summary keys) touched.
    public var types: [String]

    // Device conditions at the start of the wake — background behaviour differs a
    // lot under Low Power Mode / thermal pressure.
    public var lowPowerMode: Bool
    public var thermalState: String

    public init(context: WakeContext, detail: String?, gapSinceLastWake: TimeInterval?,
                lowPowerMode: Bool, thermalState: String) {
        self.id = context.id
        self.trigger = context.trigger
        self.startedAt = context.startedAt
        self.endedAt = nil
        self.outcome = .running
        self.detail = detail
        self.gapSinceLastWake = gapSinceLastWake
        self.batches = 0
        self.samples = 0
        self.deletions = 0
        self.bytes = 0
        self.types = []
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }

    /// Wall-clock execution time, once finished.
    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// One-line human summary for the event log.
    public var summary: String {
        var parts = ["\(batches) batch\(batches == 1 ? "" : "es")", "\(samples) samples"]
        if deletions > 0 { parts.append("\(deletions) deletions") }
        if let d = duration { parts.append(String(format: "%.1fs", d)) }
        parts.append(bytes.wakeByteString)
        if outcome != .completed { parts.append(outcome.rawValue) }
        return parts.joined(separator: ", ")
    }
}

/// Durable, append-only log of wake records, parallel to `SyncEventLog`. Unlike
/// the event log's fast-rolling 2k ring buffer, this keeps a much larger window
/// (`capacity` wakes ≈ months) so a 1–2 week field study never loses early data,
/// and persists immediately on begin/finish so background kills don't lose the
/// record.
public actor WakeLog {
    /// At a few dozen wakes/day this is several months of history.
    public static let capacity = 10_000

    private(set) var records: [WakeRecord] = []
    private let logger = Logger(subsystem: PulsLog.subsystem, category: "wakes")
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulsHealthSync", isDirectory: true)
        ProtectedStateFile.prepareDirectory(dir)
        self.fileURL = dir.appendingPathComponent("wake-log.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.puls.decode([WakeRecord].self, from: data) {
            records = decoded
            // Anything still "running" means we died before finishing it — a real
            // signal (force-quit / OOM / background reclamation mid-wake).
            var changed = false
            for i in records.indices where records[i].outcome == .running {
                records[i].outcome = .interrupted
                if records[i].endedAt == nil { records[i].endedAt = records[i].startedAt }
                changed = true
            }
            // Can't call the isolated persistNow() from the nonisolated init;
            // write inline (same atomic encode).
            if changed, let data = try? JSONEncoder.puls.encode(records) {
                try? ProtectedStateFile.write(data, to: fileURL)
            }
        }
    }

    /// Open a new wake record. Persisted immediately so it survives a mid-wake
    /// kill (it'll be recovered as `.interrupted` on the next launch).
    public func begin(_ context: WakeContext, detail: String?) {
        let gap = records.last.map { context.startedAt.timeIntervalSince($0.startedAt) }
        let record = WakeRecord(
            context: context, detail: detail, gapSinceLastWake: gap,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: Self.thermalLabel(ProcessInfo.processInfo.thermalState))
        records.append(record)
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
        persistNow()
    }

    /// Attribute one uploaded batch to the open wake. Debounced to disk — losing
    /// the last second of counters on a crash is harmless (the record still exists).
    public func record(wakeID: UUID, type: String, samples: Int, deletions: Int, bytes: Int) {
        guard let i = records.lastIndex(where: { $0.id == wakeID }) else { return }
        records[i].batches += 1
        records[i].samples += samples
        records[i].deletions += deletions
        records[i].bytes += bytes
        if !records[i].types.contains(type) { records[i].types.append(type) }
        scheduleSave()
    }

    /// Close the open wake. Persisted immediately. Returns the finished record so
    /// the caller can log a summary. Idempotent: only the *first* finish wins, so
    /// a background task's expiration handler (`.expired`) and its work task's
    /// trailing completion can't clobber each other — the expiration fires first
    /// and is the truthful outcome.
    @discardableResult
    public func finish(wakeID: UUID, outcome: WakeRecord.Outcome) -> WakeRecord? {
        guard let i = records.lastIndex(where: { $0.id == wakeID }) else { return nil }
        guard records[i].outcome == .running else { return nil }
        records[i].endedAt = Date()
        records[i].outcome = outcome
        persistNow()
        return records[i]
    }

    public func recent(limit: Int = 500) -> [WakeRecord] {
        Array(records.suffix(limit))
    }

    public func clear() {
        records = []
        persistNow()
    }

    // MARK: - Export

    /// Full history as pretty JSON, for the share sheet.
    public func exportJSON() -> Data {
        let encoder = JSONEncoder.puls
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(records)) ?? Data()
    }

    /// Full history as CSV (one row per wake) — the most analysis-friendly form
    /// (open in any spreadsheet / pandas) for the field study.
    public func exportCSV() -> String {
        var out = "started_at,ended_at,trigger,outcome,duration_s,gap_since_last_s,"
            + "is_background,batches,samples,deletions,bytes,types,low_power_mode,thermal_state,wake_id\n"
        let iso = ISO8601DateFormatter()
        for r in records {
            let fields: [String] = [
                iso.string(from: r.startedAt),
                r.endedAt.map { iso.string(from: $0) } ?? "",
                r.trigger.rawValue,
                r.outcome.rawValue,
                r.duration.map { String(format: "%.3f", $0) } ?? "",
                r.gapSinceLastWake.map { String(format: "%.3f", $0) } ?? "",
                r.trigger.isBackground ? "1" : "0",
                String(r.batches),
                String(r.samples),
                String(r.deletions),
                String(r.bytes),
                r.types.joined(separator: " "),
                r.lowPowerMode ? "1" : "0",
                r.thermalState,
                r.id.uuidString,
            ]
            out += CSVField.row(fields)
        }
        return out
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            saveTask = nil
            persistNow()
        }
    }

    private func persistNow() {
        if let data = try? JSONEncoder.puls.encode(records) {
            try? ProtectedStateFile.write(data, to: fileURL)
        }
    }

    // MARK: - Helpers

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

extension Int {
    /// Byte string without importing the app's Int extension into the library.
    fileprivate var wakeByteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
