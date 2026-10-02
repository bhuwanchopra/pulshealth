import Foundation

/// What an export wrote, counted from the batches themselves rather than from
/// the files — so a CSV export knows how many ECGs it had no file for, and a
/// JSONL export's counts mean the same thing as a CSV export's.
struct ExportTally: Sendable, Equatable {
    /// Rows per dataset. Route and series datasets count points, not payloads:
    /// a payload is a framing detail (≤4,000 points per line), a point is a row.
    var rows: [ExportDataset: Int] = [:]
    var batches = 0
    var bytes: Int64 = 0

    mutating func add(_ batch: SyncBatch, bytes written: Int) {
        for sample in batch.samples {
            guard let dataset = Self.dataset(for: sample.kind) else { continue }
            rows[dataset, default: 0] += 1
        }
        add(batch.deletions.count, to: .deletions)
        add(batch.routes.reduce(0) { $0 + $1.points.count }, to: .workoutRoutes)
        add(batch.series.reduce(0) { $0 + $1.points.count }, to: .workoutSeries)
        add(batch.aggregates.count, to: .aggregates)
        add(batch.activitySummaries.count, to: .activity)
        batches += 1
        bytes += Int64(written)
    }

    private mutating func add(_ count: Int, to dataset: ExportDataset) {
        guard count > 0 else { return }
        rows[dataset, default: 0] += count
    }

    static func dataset(for kind: SampleKind) -> ExportDataset? {
        switch kind {
        case .quantity, .category: return .samples
        case .workout: return .workouts
        case .stateOfMind: return .stateOfMind
        case .medicationDose: return .medicationDoses
        case .ecg: return .ecg
        case .heartbeatSeries: return .heartbeatSeries
        // Rings ride `activitySummaries`, never a sample line.
        case .activitySummary: return nil
        }
    }

    /// Rows the format actually put in a file.
    func written(in format: ExportFormat) -> [ExportDataset: Int] {
        format == .jsonl ? rows : rows.filter { $0.key.isWrittenToCSV }
    }

    /// Rows the format had no file for. Empty for JSONL.
    func notRepresented(in format: ExportFormat) -> [ExportDataset: Int] {
        format == .jsonl ? [:] : rows.filter { !$0.key.isWrittenToCSV }
    }
}

/// The `SyncTransport` behind an on-device export: every batch the engine
/// would have uploaded is appended to files instead.
///
/// A normal return is the engine's ack, exactly as a 2xx is for
/// `HTTPSyncTransport` — and the engine advances anchors and watermarks on it.
/// That is harmless **only because the engine on the other side is a throwaway
/// with its own state directory** (`HealthExporter`). Never hand this transport
/// to the app's real engine: anchors are keyed per type with no destination
/// dimension, so everything written here would count as delivered and the
/// server would never receive it.
///
/// An actor because the raw sweep runs `maxConcurrentTypes` type pipelines at
/// once and they all upload here; serialising them is what keeps each batch's
/// lines contiguous in the JSONL file and each CSV row whole.
actor ExportFileTransport: SyncTransport {
    private let format: ExportFormat
    private let writer: any ExportWriter
    private let deviceID: String?
    private let progress: ExportProgressHandler?
    private var phase: ExportProgress.Phase = .preparing
    private var isFinished = false
    private(set) var tally = ExportTally()
    /// The first write that failed. Once set, every later upload fails fast
    /// with the same text: a full disk does not recover, and letting each
    /// remaining type discover it for itself only makes the run slower to end.
    private(set) var writeFailure: String?

    /// - Parameters:
    ///   - baseName: File name stem, e.g. `puls-export-20260921-143000`.
    ///   - deviceID: Overrides the header `deviceID` of every batch. The
    ///     throwaway engine's state store mints a random one; the app passes
    ///     its real one so a replayed export is attributed to this install.
    init(
        format: ExportFormat, directory: URL, baseName: String,
        deviceID: String? = nil, progress: ExportProgressHandler? = nil
    ) {
        self.format = format
        self.deviceID = deviceID
        self.progress = progress
        switch format {
        case .jsonl: writer = JSONLExportWriter(directory: directory, baseName: baseName)
        case .csv: writer = CSVExportWriter(directory: directory, baseName: baseName)
        }
    }

    func upload(_ batch: SyncBatch) async throws -> UploadResult {
        // A cancelled export must stop growing its files at once, not after
        // the page already in flight has been appended.
        try Task.checkCancellation()
        if let writeFailure { throw HealthExportError.writeFailed(writeFailure) }
        guard !isFinished else { throw HealthExportError.writeFailed("the export is already closed") }

        let start = ContinuousClock.now
        var batch = batch
        if let deviceID { batch.deviceID = deviceID }
        let written: Int
        do {
            written = try writer.write(batch)
        } catch {
            let reason = ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit)
            writeFailure = reason
            throw HealthExportError.writeFailed(reason)
        }
        tally.add(batch, bytes: written)
        report(currentType: batch.type)
        return UploadResult(bytesSent: written, duration: (ContinuousClock.now - start).seconds)
    }

    func setPhase(_ phase: ExportProgress.Phase) {
        self.phase = phase
        report(currentType: nil)
    }

    /// Close the files. After this every `upload` is refused.
    func finish() throws -> [ExportedFile] {
        isFinished = true
        do {
            return try writer.finish()
        } catch {
            throw HealthExportError.writeFailed(
                ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit))
        }
    }

    /// Close and delete everything written so far.
    func abort() {
        isFinished = true
        writer.abort()
    }

    private func report(currentType: String?) {
        guard let progress else { return }
        progress(ExportProgress(
            phase: phase, currentType: currentType,
            rowsWritten: tally.written(in: format).values.reduce(0, +),
            bytesWritten: tally.bytes))
    }
}
