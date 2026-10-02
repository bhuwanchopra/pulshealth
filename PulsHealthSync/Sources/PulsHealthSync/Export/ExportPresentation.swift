import Foundation

// What the app's export screen says, decided away from SwiftUI so it can be
// tested: which instant a "Last 90 days" starts at, what a selection amounts
// to, and — the part that matters — what each way an export can fail is
// called. Like `PairingConfirmation`, the wording is the contract: "no data"
// and "access was declined" are the same answer from HealthKit, and a screen
// that says only one of them sends half its readers the wrong way.

/// The time ranges the export screen offers. `startDate` is what goes into
/// `ExportRequest.startDate`.
public enum ExportRange: String, Sendable, CaseIterable, Identifiable {
    case last30Days, last90Days, lastYear, allTime

    public var id: String { rawValue }

    /// A year: long enough to be what "my data" usually means, and bounded, so
    /// a first export is not also the largest one the phone can produce. All
    /// time is one tap away, with its size warning (`sizeNote`).
    public static let `default` = ExportRange.lastYear

    public var title: String {
        switch self {
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .lastYear: "Last year"
        case .allTime: "All time"
        }
    }

    /// Earliest sample start to export, or nil for all time.
    ///
    /// The start of the local day N days back, not `now − N × 86,400 s`: day
    /// buckets and activity rings are whole local days, and a range that begins
    /// mid-afternoon would open every daily series with a partial first day
    /// that looks like a bad day rather than a cut.
    public func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: today)
        case .last90Days: return calendar.date(byAdding: .day, value: -90, to: today)
        case .lastYear: return calendar.date(byAdding: .year, value: -1, to: today)
        case .allTime: return nil
        }
    }

    /// Shown under the picker. Only all time needs one.
    ///
    /// "Hundreds of megabytes" is arithmetic over measured rows: 340,000 samples came
    /// to 41 MB as CSV and 212 MB as JSONL (about 120 and 620 bytes a row — the
    /// wire format carries each sample's time-zone context and source), and a
    /// Watch records a few thousand heart-rate samples a day.
    public var sizeNote: String? {
        switch self {
        case .allTime:
            "Can be hundreds of megabytes and take several minutes."
        default:
            nil
        }
    }
}

public extension ExportFormat {
    var title: String {
        switch self {
        case .csv: "CSV"
        case .jsonl: "JSONL"
        }
    }
}

public extension ExportDataset {
    /// Row label on the result screen.
    var displayName: String {
        switch self {
        case .samples: "Samples"
        case .workouts: "Workouts"
        case .activity: "Activity ring days"
        case .stateOfMind: "State of Mind entries"
        case .aggregates: "Aggregate buckets"
        case .workoutRoutes: "Workout route points"
        case .workoutSeries: "Workout stream points"
        case .medicationDoses: "Medication doses"
        case .ecg: "ECG recordings"
        case .heartbeatSeries: "Heartbeat series"
        case .deletions: "Deletion records"
        }
    }
}

public extension ExportProgress.Phase {
    /// What the running screen says it is doing.
    var label: String {
        switch self {
        case .preparing: "Preparing…"
        case .activity: "Reading activity rings…"
        case .samples: "Reading samples…"
        case .aggregates: "Computing aggregates…"
        case .workoutRoutes: "Reading workout routes…"
        case .workoutStreams: "Reading workout streams…"
        case .finishing: "Finishing…"
        case .archiving: "Zipping…"
        }
    }
}

/// What an export of a selection would cover, for the screen's "what's
/// included" rows. Counts what `ExportPlan` will actually run: every aggregate
/// in the selection is exported, and the route and stream switches only mean
/// something when Workouts is selected.
public struct ExportSelectionSummary: Sendable, Equatable {
    public let typeCount: Int
    public let aggregateCount: Int
    public let includesWorkoutRoutes: Bool
    public let includesWorkoutStreams: Bool

    public init(selection: ExportSelection) {
        typeCount = selection.types.count
        aggregateCount = selection.aggregates.count
        let workouts = selection.types.contains(HealthTypeCatalog.workoutIdentifier)
        includesWorkoutRoutes = workouts && selection.includeWorkoutRoutes
        includesWorkoutStreams = workouts && selection.includeWorkoutEnhancedData
    }

    /// The applied selection: disabled aggregate configs are not counted.
    public init(configuration: SyncConfiguration) {
        self.init(selection: ExportSelection(configuration: configuration))
    }

    /// Mirrors `ExportPlan.hasAnythingToExport`, which is what makes
    /// `HealthExporter.run` throw `.nothingSelected`.
    public var isEmpty: Bool { typeCount == 0 && aggregateCount == 0 }
}

/// An export that produced no files, in words.
///
/// `suggestion` says which way out the screen should offer, because the two
/// commonest failures are fixed in different places and neither is inside the
/// export screen.
public struct ExportFailureCopy: Sendable, Equatable {
    public enum Suggestion: Sendable, Equatable {
        case none
        /// iOS Settings → Privacy & Security → Health.
        case healthAccess
        /// The Export tab's Data Types picker.
        case dataTypes
    }

    public let title: String
    public let message: String
    public let suggestion: Suggestion
    /// Per-type reasons, when the error carried any (`.failed`).
    public let issues: [ExportIssue]

    public init(title: String, message: String, suggestion: Suggestion = .none, issues: [ExportIssue] = []) {
        self.title = title
        self.message = message
        self.suggestion = suggestion
        self.issues = issues
    }

    /// Nil for cancellation: the user asked for that, and it is not a failure.
    public init?(error: Error) {
        if error is CancellationError { return nil }
        guard let exportError = error as? HealthExportError else {
            self.init(
                title: "The Export Didn't Finish",
                message: ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit)
                    + "\n\nNothing was kept. You can try again.")
            return
        }
        switch exportError {
        case .healthDataUnavailable:
            self.init(
                title: "Health Isn't Available Here",
                message: "This device has no Apple Health data to read, so there is nothing to export.")
        case .deviceLocked:
            self.init(
                title: "iPhone Is Locked",
                message: "Health data can't be read while the iPhone is locked. "
                    + "Unlock it, keep PulsHealth open, and try again.")
        case .nothingSelected:
            self.init(
                title: "Nothing Selected",
                message: "No data types are selected. Choose some under Data Types on the Export tab.",
                suggestion: .dataTypes)
        case .noData:
            // HealthKit answers a declined read exactly like an empty one, so
            // both readings are given, the innocent one first.
            self.init(
                title: "Nothing to Export",
                message: "Apple Health returned no data for the selected types in this time range. "
                    + "Try a longer range — or, if you expected data, Health access may be off for "
                    + "these types: iOS doesn't tell apps which. Check Settings → Privacy & "
                    + "Security → Health → PulsHealth.",
                suggestion: .healthAccess)
        case .failed(let issues):
            self.init(
                title: "Nothing Could Be Read",
                message: "Every selected type failed, so no file was written. If the iPhone locked "
                    + "during the export, unlock it and try again; otherwise check Health access "
                    + "under Settings → Privacy & Security → Health → PulsHealth.",
                suggestion: .healthAccess,
                issues: issues)
        case .writeFailed(let reason):
            self.init(
                title: "The Files Couldn't Be Written",
                message: "\(reason)\n\nThe usual cause is a full iPhone. The partial files were "
                    + "removed; free some space, or choose a shorter time range.")
        }
    }
}

public extension ExportResult {
    /// Rows that are actually in `files`, per dataset. `rowCounts` counts what
    /// HealthKit returned — for a CSV export that includes the ECG, heartbeat
    /// and deletion rows the format has no file for, which `notRepresented`
    /// lists separately. A screen that says "what's in it" wants this one, or
    /// it lists three heartbeat series as exported and then, a section later,
    /// as left out.
    var writtenRowCounts: [ExportDataset: Int] {
        rowCounts.filter { notRepresented[$0.key] == nil }
    }

    var writtenRows: Int { writtenRowCounts.values.reduce(0, +) }
}

public extension ExportIssue {
    /// The catalog's name for `type`, or nil when the issue concerns no one
    /// type. An identifier the catalog does not know is shown as it is.
    var typeDisplayName: String? {
        type.map { HealthTypeCatalog.descriptor(for: $0)?.displayName ?? $0 }
    }
}
