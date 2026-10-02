import Foundation

/// One finished data file, as the manifest records it.
struct ExportedFile: Sendable, Equatable {
    var url: URL
    /// Nil for the JSONL file, which holds every dataset.
    var dataset: ExportDataset?
    var bytes: Int64
}

/// Turns batches into bytes on disk. Implementations are not thread-safe and
/// do not need to be: `ExportFileTransport` (an actor) owns exactly one and is
/// the only thing that calls it, which is also what keeps a batch's lines
/// contiguous while four type pipelines upload at once.
protocol ExportWriter: AnyObject {
    /// Append one batch. Returns the bytes written for it.
    func write(_ batch: SyncBatch) throws -> Int
    /// Flush whatever was held back, close every file and report them in
    /// their stable order. Files with no rows are never created.
    func finish() throws -> [ExportedFile]
    /// Close and delete everything written so far.
    func abort()
}

/// An append-only file, created on first use.
///
/// Protection is `.completeUntilFirstUserAuthentication`, set explicitly
/// rather than inherited: an export of years of heart rate runs for minutes,
/// and if the user locks the phone meanwhile a `.complete` file (the class an
/// app gets when it opts into full data protection) would start refusing
/// writes ten seconds later. It is deliberately *not* run through
/// `ProtectedStateFile`: that also excludes the file from backup and is the
/// policy for the package's private state, whereas these files exist to be
/// handed to a share sheet and leave the app. By default they are staged under
/// the temporary directory, which iOS neither backs up nor keeps.
final class ExportFile {
    let url: URL
    private let handle: FileHandle
    private(set) var bytesWritten: Int64 = 0

    init(url: URL) throws {
        self.url = url
        let created = FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        guard created else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        bytesWritten += Int64(data.count)
    }

    func close() throws { try handle.close() }

    func delete() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - JSONL

/// Writes every batch as the uncompressed NDJSON the HTTP transport would have
/// gzipped and POSTed: the header line, then the batch's lines. The file is
/// therefore a concatenation of valid Puls Sync Protocol v1 batches —
/// specified in `docs/protocol/README.md`, schema-checked, fixture-tested —
/// and an export is *replayable*: split it on header lines (the only lines
/// whose top-level object has a `batchID`) and POST each piece to
/// `/v1/batches`. Nothing about the format is export-specific, so nothing
/// about it can drift from the wire.
///
/// One `write` per batch, so a batch is never interleaved with another and is
/// never held in memory alongside a second one; the export as a whole is never
/// in memory at all.
final class JSONLExportWriter: ExportWriter {
    private let url: URL
    private let clientVersion: String
    private var file: ExportFile?

    init(directory: URL, baseName: String, clientVersion: String = PulsProtocol.clientVersion) {
        url = directory.appendingPathComponent("\(baseName).jsonl")
        self.clientVersion = clientVersion
    }

    func write(_ batch: SyncBatch) throws -> Int {
        let data = try BatchSerializer.ndjson(for: batch, clientVersion: clientVersion)
        if file == nil { file = try ExportFile(url: url) }
        try file?.append(data)
        return data.count
    }

    func finish() throws -> [ExportedFile] {
        guard let file else { return [] }
        try file.close()
        return [ExportedFile(url: file.url, dataset: nil, bytes: file.bytesWritten)]
    }

    func abort() {
        file?.delete()
        file = nil
    }
}

// MARK: - CSV

/// Writes one CSV file per dataset, header first, rows appended as batches
/// arrive — so a dataset's header is written once however many batches feed
/// it, and a dataset with no rows gets no file.
///
/// A flattened view, on purpose: metadata, device, temporal context, workout
/// statistics and events have no column here, and three kinds have no file at
/// all (`ExportDataset.isWrittenToCSV`). JSONL is the complete format.
///
/// `workouts` is the one dataset held back until `finish`. Its `hasRoute` and
/// `availableMetrics` columns describe rows that arrive in *later* phases —
/// the sweep uploads workout rows first and their routes and streams last —
/// so the rows wait in memory (a few hundred bytes each, and workouts number
/// in the thousands, not the millions) while route and stream batches fill in
/// which workouts have what. The server computes the same two columns the
/// same way, from which route points and streams it holds.
final class CSVExportWriter: ExportWriter {
    private struct WorkoutRow {
        var uuid: UUID
        var activityType: String
        var start: Date
        var end: Date
        var duration: TimeInterval
        var distanceMeters: Double?
        var energyKcal: Double?
    }

    private let directory: URL
    private let baseName: String
    /// `state_of_mind.date` is the entry's local calendar day. The server
    /// derives it in `PULS_TIME_ZONE`, which is required to match the phone's
    /// zone; here it *is* the phone's zone. Gregorian regardless of the
    /// device's calendar, because the column is an ISO `YYYY-MM-DD`.
    private let dayCalendar: Calendar
    private var files: [ExportDataset: ExportFile] = [:]
    private var workouts: [WorkoutRow] = []
    private var workoutsWithRoute: Set<UUID> = []
    private var workoutMetrics: [UUID: Set<String>] = [:]

    init(directory: URL, baseName: String, timeZone: TimeZone = .current) {
        self.directory = directory
        self.baseName = baseName
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        dayCalendar = calendar
    }

    func write(_ batch: SyncBatch) throws -> Int {
        var rows: [ExportDataset: String] = [:]

        for sample in batch.samples {
            switch sample.kind {
            case .quantity, .category:
                rows[.samples, default: ""] += Self.sampleRow(sample)
            case .workout:
                guard let detail = sample.workout else { continue }
                workouts.append(WorkoutRow(
                    uuid: sample.uuid, activityType: detail.activityType,
                    start: sample.start, end: sample.end, duration: detail.duration,
                    distanceMeters: detail.totalDistanceMeters, energyKcal: detail.totalEnergyKcal))
            case .stateOfMind:
                guard let detail = sample.stateOfMind else { continue }
                rows[.stateOfMind, default: ""] += stateOfMindRow(sample, detail)
            case .medicationDose:
                guard let detail = sample.medicationDose else { continue }
                rows[.medicationDoses, default: ""] += Self.medicationDoseRow(sample, detail)
            case .ecg, .heartbeatSeries, .activitySummary:
                // No tabular shape. Not dropped silently: the transport counts
                // these per dataset and `ExportResult.notRepresented` reports
                // them. (`.activitySummary` never reaches a sample line.)
                continue
            }
        }
        for route in batch.routes where !route.points.isEmpty {
            workoutsWithRoute.insert(route.workoutUUID)
            let id = route.workoutUUID.uuidString.lowercased()
            rows[.workoutRoutes, default: ""] += route.points.map { point in
                CSVField.row([
                    id, CSVField.epochMilliseconds(point.t),
                    CSVField.number(point.lat), CSVField.number(point.lon),
                    CSVField.number(point.alt), CSVField.number(point.hAcc),
                    CSVField.number(point.vAcc), CSVField.number(point.speed),
                    CSVField.number(point.course),
                ])
            }.joined()
        }
        for series in batch.series where !series.points.isEmpty {
            workoutMetrics[series.workoutUUID, default: []].insert(series.type)
            let id = series.workoutUUID.uuidString.lowercased()
            rows[.workoutSeries, default: ""] += series.points.map { point in
                CSVField.row([
                    id, series.type, series.unit ?? "",
                    CSVField.epochMilliseconds(point.t), CSVField.number(point.value),
                ])
            }.joined()
        }
        for bucket in batch.aggregates {
            rows[.aggregates, default: ""] += CSVField.row([
                bucket.type, bucket.function.rawValue, String(bucket.intervalValue),
                bucket.intervalUnit.rawValue, bucket.deviceFilter.rawValue,
                CSVField.epochMilliseconds(bucket.bucketStart),
                CSVField.epochMilliseconds(bucket.bucketEnd),
                CSVField.number(bucket.value), bucket.unit ?? "",
            ])
        }
        for day in batch.activitySummaries {
            rows[.activity, default: ""] += CSVField.row([
                // The wire's own local day, never re-derived from the instant:
                // shifting it through another zone splits a day across two rows.
                day.localDate ?? Self.isoDay(day.date, calendar: dayCalendar),
                CSVField.number(day.moveKcal), CSVField.number(day.moveGoalKcal),
                CSVField.number(day.exerciseMin), CSVField.number(day.exerciseGoalMin),
                CSVField.number(day.standHours), CSVField.number(day.standGoalHours),
                CSVField.number(day.moveMode),
                CSVField.number(day.moveTimeMin), CSVField.number(day.moveTimeGoalMin),
            ])
        }
        // Deletions are not written: a tombstone is an instruction to a
        // receiver ("forget this UUID"), and a CSV reader has no store to
        // forget it from. Counted by the transport like the other kinds.

        var written = 0
        for dataset in ExportDataset.allCases {
            guard let text = rows[dataset] else { continue }
            written += try append(text, to: dataset)
        }
        return written
    }

    func finish() throws -> [ExportedFile] {
        if !workouts.isEmpty {
            var text = ""
            for workout in workouts {
                text += CSVField.row([
                    workout.uuid.uuidString.lowercased(), workout.activityType,
                    CSVField.epochMilliseconds(workout.start), CSVField.epochMilliseconds(workout.end),
                    CSVField.number(workout.duration), CSVField.number(workout.distanceMeters),
                    CSVField.number(workout.energyKcal),
                    workoutsWithRoute.contains(workout.uuid) ? "true" : "false",
                    // Sorted, like the server's array_agg(DISTINCT … ORDER BY …).
                    (workoutMetrics[workout.uuid] ?? []).sorted().joined(separator: ","),
                ])
            }
            _ = try append(text, to: .workouts)
            workouts = []
        }
        var out: [ExportedFile] = []
        for dataset in ExportDataset.allCases {
            guard let file = files[dataset] else { continue }
            try file.close()
            out.append(ExportedFile(url: file.url, dataset: dataset, bytes: file.bytesWritten))
        }
        return out
    }

    func abort() {
        for file in files.values { file.delete() }
        files = [:]
        workouts = []
    }

    /// Append rows to a dataset's file, creating it — header first — on the
    /// first call. Returns the bytes written, header included.
    private func append(_ text: String, to dataset: ExportDataset) throws -> Int {
        guard let columns = dataset.csvColumns else { return 0 }
        var data = Data()
        let file: ExportFile
        if let open = files[dataset] {
            file = open
        } else {
            file = try ExportFile(
                url: directory.appendingPathComponent("\(baseName)-\(dataset.rawValue).csv"))
            files[dataset] = file
            data.append(Data(CSVField.row(columns).utf8))
        }
        data.append(Data(text.utf8))
        try file.append(data)
        return data.count
    }

    // MARK: Rows

    /// `uuid` is lowercased in every CSV: the server's export prints
    /// PostgreSQL's `uuid::text`, which is lowercase, while Swift (and so the
    /// wire, and the JSONL export) spells a UUID in capitals.
    private static func sampleRow(_ sample: SyncSample) -> String {
        CSVField.row([
            sample.type, sample.unit ?? "", sample.uuid.uuidString.lowercased(),
            CSVField.epochMilliseconds(sample.start), CSVField.epochMilliseconds(sample.end),
            // A category sample's value is its raw HealthKit integer, as on the
            // server (`category_samples.value`).
            sample.kind == .category ? CSVField.number(sample.category) : CSVField.number(sample.value),
            // `label` is the server's name for a category value ("asleepCore"),
            // joined from `category_labels` (db/migrations/010). The client has
            // no such table, and inventing a second vocabulary here would be
            // worse than an empty cell: the column stays, for the shared
            // header, and is always empty on the device.
            "",
            sample.sourceName ?? "",
        ])
    }

    private func stateOfMindRow(_ sample: SyncSample, _ detail: StateOfMindDetail) -> String {
        CSVField.row([
            sample.uuid.uuidString.lowercased(),
            Self.isoDay(sample.start, calendar: dayCalendar),
            CSVField.epochMilliseconds(sample.start),
            detail.kind, CSVField.number(detail.valence), detail.valenceClassification,
            detail.labels.joined(separator: ","), detail.associations.joined(separator: ","),
        ])
    }

    private static func medicationDoseRow(_ sample: SyncSample, _ detail: MedicationDoseDetail) -> String {
        CSVField.row([
            sample.uuid.uuidString.lowercased(),
            CSVField.epochMilliseconds(sample.start), CSVField.epochMilliseconds(sample.end),
            detail.medication ?? "", detail.status,
            CSVField.epochMilliseconds(detail.scheduledAt),
            CSVField.number(detail.doseQuantity), detail.doseUnit ?? "",
            sample.sourceName ?? "",
        ])
    }

    private static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
