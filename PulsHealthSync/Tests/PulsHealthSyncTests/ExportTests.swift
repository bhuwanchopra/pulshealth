import Compression
import Foundation
import Testing
@testable import PulsHealthSync

// HealthKit cannot be driven from a unit test, so `HealthExporter.run` itself
// is exercised in the app. Everything it delegates to is tested here by
// feeding hand-built `SyncBatch` values to the same transport and writers a
// real export uses, and hand-built store states to the completion check.

// MARK: - Fixtures

private enum Fixture {
    static let heartRate = "HKQuantityTypeIdentifierHeartRate"
    static let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
    static let workoutA = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    static let workoutB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!

    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1_000) }

    static func quantity(
        _ i: Int, value: Double? = 72, source: String? = "Apple Watch"
    ) -> SyncSample {
        SyncSample(
            uuid: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!,
            type: heartRate, kind: .quantity,
            start: date(1_750_000_000_000 + Double(i) * 1_000),
            end: date(1_750_000_000_000 + Double(i) * 1_000),
            value: value, unit: "count/min", sourceName: source,
            metadata: ["HKMetadataKeyHeartRateMotionContext": .number(1)])
    }

    static func category(_ i: Int, value: Int) -> SyncSample {
        SyncSample(
            uuid: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", i))!,
            type: sleep, kind: .category,
            start: date(1_750_000_000_000), end: date(1_750_000_360_000),
            category: value, sourceName: "Apple Watch")
    }

    static func workout(_ uuid: UUID, distance: Double? = 5_012.5) -> SyncSample {
        SyncSample(
            uuid: uuid, type: HealthTypeCatalog.workoutIdentifier, kind: .workout,
            start: date(1_750_000_000_000), end: date(1_750_001_800_000),
            sourceName: "Apple Watch",
            workout: WorkoutDetail(
                activityType: "running", duration: 1_800,
                totalEnergyKcal: 312.25, totalDistanceMeters: distance))
    }

    static func batch(
        type: String = heartRate, samples: [SyncSample] = [], deletions: [SyncDeletion] = [],
        routes: [RoutePayload] = [], series: [WorkoutSeriesPayload] = [],
        aggregates: [AggregateSampleRow] = [], activitySummaries: [ActivitySummaryRow] = []
    ) -> SyncBatch {
        SyncBatch(
            deviceID: "throwaway-device", type: type, reason: .manual,
            samples: samples, deletions: deletions, routes: routes, series: series,
            aggregates: aggregates, activitySummaries: activitySummaries)
    }

    static func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func object(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

// MARK: - CSV cells

@Suite struct CSVFieldTests {
    @Test func quotesExactlyWhatGoEncodingCSVQuotes() {
        #expect(CSVField.escape("plain") == "plain")
        #expect(CSVField.escape("") == "")
        #expect(CSVField.escape("a,b") == "\"a,b\"")
        #expect(CSVField.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVField.escape("two\nlines") == "\"two\nlines\"")
        #expect(CSVField.escape("cr\rhere") == "\"cr\rhere\"")
        // "\r\n" is one Character; a Character scan would have let it through.
        #expect(CSVField.escape("crlf\r\nhere") == "\"crlf\r\nhere\"")
        #expect(CSVField.escape(" leading space") == "\" leading space\"")
        #expect(CSVField.escape("trailing space ") == "trailing space ")
        #expect(CSVField.escape("\\.") == "\"\\.\"")
    }

    /// The server writes cells verbatim and documents the spreadsheet-formula
    /// caveat instead of rewriting values (`docs/export.md`); so does the device.
    @Test func formulaLookingValuesAreWrittenVerbatim() {
        for value in ["=SUM(A1)", "+1", "-3.5", "@handle"] {
            #expect(CSVField.escape(value) == value)
        }
        #expect(CSVField.escape("=HYPERLINK(\"x\",\"y\")") == "\"=HYPERLINK(\"\"x\"\",\"\"y\"\")\"")
    }

    @Test func numbersMatchGoFormatFloatFMinusOne() {
        #expect(CSVField.number(72.0) == "72")
        #expect(CSVField.number(-3.5) == "-3.5")
        #expect(CSVField.number(0.1 + 0.2) == "0.30000000000000004")
        #expect(CSVField.number(0.00001) == "0.00001")
        #expect(CSVField.number(1.5e-7) == "0.00000015")
        #expect(CSVField.number(1e16) == "10000000000000000")
        #expect(CSVField.number(1.25e20) == "125000000000000000000")
        #expect(CSVField.number(-2e-5) == "-0.00002")
        #expect(CSVField.number(0) == "0")
        #expect(CSVField.number(Double?.none) == "")
        #expect(CSVField.number(Int?.none) == "")
        #expect(CSVField.number(Int?.some(3)) == "3")
    }

    @Test func instantsAreWholeFlooredEpochMilliseconds() {
        #expect(CSVField.epochMilliseconds(Fixture.date(1_750_000_000_123.9)) == "1750000000123")
        #expect(CSVField.epochMilliseconds(Fixture.date(0)) == "0")
        #expect(CSVField.epochMilliseconds(Date?.none) == "")
    }

    @Test func rowIsCommaJoinedAndLFTerminated() {
        #expect(CSVField.row(["a", "", "b,c"]) == "a,,\"b,c\"\n")
    }
}

// MARK: - Columns

@Suite struct ExportColumnTests {
    /// Every dataset's header row, as `docs/export.md` publishes it. The four
    /// the product API also serves must equal its column lists exactly; this
    /// reads the document so that editing either side without the other fails.
    @Test func columnsEqualTheDocumentedLists() throws {
        let url = CatalogVocabulary.repositoryRoot().appendingPathComponent("docs/export.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let names = Set(ExportDataset.allCases.map(\.rawValue))
        var documented: [String: [String]] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| `") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = cells.first?.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                  names.contains(name), cells.count == 3,
                  let columns = cells.last, columns.contains("`") else { continue }
            let parsed = columns.split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
            }
            // The server table comes first in the file; the on-device table
            // repeats the shared names and must agree with it.
            if let existing = documented[name] {
                #expect(existing == parsed, "docs/export.md lists two different column sets for \(name)")
            }
            documented[name] = parsed
        }
        for dataset in ExportDataset.allCases {
            guard let columns = dataset.csvColumns else { continue }
            #expect(
                documented[dataset.rawValue] == columns,
                "\(dataset.rawValue): docs/export.md says \(documented[dataset.rawValue] ?? []), the writer says \(columns)")
        }
    }

    @Test func serverDatasetColumnsArePinned() {
        #expect(ExportDataset.samples.csvColumns
            == ["type", "unit", "uuid", "start", "end", "value", "label", "source"])
        #expect(ExportDataset.workouts.csvColumns
            == ["uuid", "activityType", "start", "end", "durationS", "distanceM", "energyKcal",
                "hasRoute", "availableMetrics"])
        #expect(ExportDataset.activity.csvColumns
            == ["date", "moveKcal", "moveGoalKcal", "exerciseMin", "exerciseGoalMin", "standHours",
                "standGoalHours", "moveMode", "moveTimeMin", "moveTimeGoalMin"])
        #expect(ExportDataset.stateOfMind.csvColumns
            == ["uuid", "date", "timestamp", "kind", "valence", "valenceClassification", "labels",
                "associations"])
    }

    @Test func threeKindsHaveNoCSVFile() {
        let unwritten = ExportDataset.allCases.filter { !$0.isWrittenToCSV }
        #expect(Set(unwritten) == [.ecg, .heartbeatSeries, .deletions])
    }
}

// MARK: - CSV writer

@Suite struct CSVExportWriterTests {
    @Test func headerIsWrittenOnceAcrossBatchesAndNullsAreEmptyCells() throws {
        let dir = try Fixture.tempDirectory()
        let writer = CSVExportWriter(directory: dir, baseName: "t")
        _ = try writer.write(Fixture.batch(samples: [Fixture.quantity(1), Fixture.quantity(2, value: 61.5)]))
        _ = try writer.write(Fixture.batch(samples: [Fixture.quantity(3, value: nil, source: nil)]))
        _ = try writer.write(Fixture.batch(type: Fixture.sleep, samples: [Fixture.category(1, value: 3)]))
        let files = try writer.finish()

        #expect(files.map(\.url.lastPathComponent) == ["t-samples.csv"])
        let lines = try Fixture.lines(of: files[0].url)
        #expect(lines.count == 5)
        #expect(lines[0] == "type,unit,uuid,start,end,value,label,source")
        #expect(lines.filter { $0.hasPrefix("type,") }.count == 1)
        // Lowercase UUID, whole epoch ms, no trailing ".0", empty label.
        #expect(lines[1] == "\(Fixture.heartRate),count/min,00000000-0000-4000-8000-000000000001,1750000001000,1750000001000,72,,Apple Watch")
        #expect(lines[2].hasSuffix(",61.5,,Apple Watch"))
        // Null value and null source are empty cells, never 0 or "nil".
        #expect(lines[3].hasSuffix(",1750000003000,1750000003000,,,"))
        // A category sample's value is its raw HealthKit integer; no unit.
        #expect(lines[4] == "\(Fixture.sleep),,10000000-0000-4000-8000-000000000001,1750000000000,1750000360000,3,,Apple Watch")
        #expect(files[0].bytes == Int64(try Data(contentsOf: files[0].url).count))
    }

    @Test func sourceNamesAreEscapedButNeverRewritten() throws {
        let dir = try Fixture.tempDirectory()
        let writer = CSVExportWriter(directory: dir, baseName: "t")
        _ = try writer.write(Fixture.batch(samples: [
            Fixture.quantity(1, source: "Scale, \"Pro\""),
            Fixture.quantity(2, source: "=cmd|' /C calc'!A0"),
            Fixture.quantity(3, source: "two\nlines"),
        ]))
        let text = try String(contentsOf: try writer.finish()[0].url, encoding: .utf8)
        #expect(text.contains(",\"Scale, \"\"Pro\"\"\"\n"))
        #expect(text.contains(",=cmd|' /C calc'!A0\n"))
        #expect(text.contains(",\"two\nlines\"\n"))
    }

    /// Workout rows arrive in the raw sweep; routes and streams two phases
    /// later. `hasRoute` and `availableMetrics` must still describe them.
    @Test func workoutsLearnTheirRoutesAndStreamsFromLaterBatches() throws {
        let dir = try Fixture.tempDirectory()
        let writer = CSVExportWriter(directory: dir, baseName: "t")
        let workoutType = HealthTypeCatalog.workoutIdentifier
        _ = try writer.write(Fixture.batch(type: workoutType, samples: [
            Fixture.workout(Fixture.workoutA), Fixture.workout(Fixture.workoutB, distance: nil),
        ]))
        _ = try writer.write(Fixture.batch(type: workoutType, routes: [
            RoutePayload(workoutUUID: Fixture.workoutA, points: [
                RoutePoint(t: Fixture.date(1_750_000_000_500), lat: 40.5, lon: -111.25, alt: 1_400, speed: 3.2),
                RoutePoint(t: Fixture.date(1_750_000_001_500), lat: 40.6, lon: -111.26),
            ]),
        ]))
        _ = try writer.write(Fixture.batch(type: workoutType, series: [
            WorkoutSeriesPayload(workoutUUID: Fixture.workoutA, type: "HKQuantityTypeIdentifierRunningPower",
                                 unit: "W", points: [SeriesPoint(t: Fixture.date(1_750_000_000_000), value: 250)]),
            WorkoutSeriesPayload(workoutUUID: Fixture.workoutA, type: Fixture.heartRate,
                                 unit: "count/min", points: [SeriesPoint(t: Fixture.date(1_750_000_000_000), value: 151.5)]),
        ]))
        let files = try writer.finish()

        // Stable order: ExportDataset.allCases.
        #expect(files.map(\.dataset) == [.workouts, .workoutRoutes, .workoutSeries])
        let workouts = try Fixture.lines(of: files[0].url)
        #expect(workouts[0] == "uuid,activityType,start,end,durationS,distanceM,energyKcal,hasRoute,availableMetrics")
        // The list is sorted and comma-joined inside one quoted cell.
        #expect(workouts[1] == "aaaaaaaa-0000-4000-8000-000000000001,running,1750000000000,1750001800000,1800,5012.5,312.25,true,\"\(Fixture.heartRate),HKQuantityTypeIdentifierRunningPower\"")
        // No route, no streams, no distance: false, empty list, empty cell.
        #expect(workouts[2] == "bbbbbbbb-0000-4000-8000-000000000002,running,1750000000000,1750001800000,1800,,312.25,false,")

        let routes = try Fixture.lines(of: files[1].url)
        #expect(routes[0] == "workoutUUID,t,lat,lon,alt,hAcc,vAcc,speed,course")
        #expect(routes[1] == "aaaaaaaa-0000-4000-8000-000000000001,1750000000500,40.5,-111.25,1400,,,3.2,")
        #expect(routes.count == 3)

        let series = try Fixture.lines(of: files[2].url)
        #expect(series[0] == "workoutUUID,type,unit,t,value")
        #expect(series[1] == "aaaaaaaa-0000-4000-8000-000000000001,HKQuantityTypeIdentifierRunningPower,W,1750000000000,250")
    }

    @Test func activityAggregatesStateOfMindAndMedication() throws {
        let dir = try Fixture.tempDirectory()
        let writer = CSVExportWriter(
            directory: dir, baseName: "t", timeZone: try #require(TimeZone(identifier: "America/Denver")))
        let mood = SyncSample(
            uuid: Fixture.workoutA, type: "HKDataTypeStateOfMind", kind: .stateOfMind,
            // 2025-06-15T04:30:00Z is still the 14th in Denver.
            start: Fixture.date(1_749_961_800_000), end: Fixture.date(1_749_961_800_000),
            stateOfMind: StateOfMindDetail(
                kind: "momentaryEmotion", valence: -0.25, valenceClassification: "slightlyUnpleasant",
                labels: ["stressed", "worried"], associations: []))
        let dose = SyncSample(
            uuid: Fixture.workoutB, type: "HKMedicationDoseEvent", kind: .medicationDose,
            start: Fixture.date(1_750_000_000_000), end: Fixture.date(1_750_000_000_000),
            sourceName: "Health",
            medicationDose: MedicationDoseDetail(
                medication: "Ibuprofen, 200 mg", status: "taken",
                scheduledAt: nil, doseQuantity: 2, doseUnit: "tablet"))
        _ = try writer.write(Fixture.batch(
            samples: [mood, dose],
            aggregates: [
                AggregateSampleRow(
                    type: Fixture.heartRate, function: .average, intervalValue: 1, intervalUnit: .hour,
                    deviceFilter: .watch, bucketStart: Fixture.date(1_750_000_000_000),
                    bucketEnd: Fixture.date(1_750_003_600_000), value: nil, unit: "count/min"),
            ],
            activitySummaries: [
                ActivitySummaryRow(
                    date: Fixture.date(1_749_967_200_000), localDate: "2025-06-15",
                    moveKcal: 512.5, moveGoalKcal: 600, exerciseMin: 31, exerciseGoalMin: 30,
                    standHours: 11, standGoalHours: nil, moveMode: 0),
            ]))
        let files = try writer.finish()
        #expect(files.map(\.dataset) == [.activity, .stateOfMind, .aggregates, .medicationDoses])

        #expect(try Fixture.lines(of: files[0].url)[1] == "2025-06-15,512.5,600,31,30,11,,0,,")
        #expect(try Fixture.lines(of: files[1].url)[1]
            == "aaaaaaaa-0000-4000-8000-000000000001,2025-06-14,1749961800000,momentaryEmotion,-0.25,slightlyUnpleasant,\"stressed,worried\",")
        // An empty bucket is an empty value cell, not a zero.
        #expect(try Fixture.lines(of: files[2].url)[1]
            == "\(Fixture.heartRate),average,1,hour,watch,1750000000000,1750003600000,,count/min")
        #expect(try Fixture.lines(of: files[3].url)[1]
            == "bbbbbbbb-0000-4000-8000-000000000002,1750000000000,1750000000000,\"Ibuprofen, 200 mg\",taken,,2,tablet,Health")
    }

    @Test func datasetsWithNoRowsGetNoFileAndAbortRemovesEverything() throws {
        let dir = try Fixture.tempDirectory()
        let empty = CSVExportWriter(directory: dir, baseName: "empty")
        _ = try empty.write(Fixture.batch(deletions: [SyncDeletion(uuid: UUID(), type: Fixture.heartRate)]))
        #expect(try empty.finish().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

        let aborted = CSVExportWriter(directory: dir, baseName: "aborted")
        _ = try aborted.write(Fixture.batch(samples: [Fixture.quantity(1)]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["aborted-samples.csv"])
        aborted.abort()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}

// MARK: - Transport

@Suite struct ExportFileTransportTests {
    /// The JSONL file is the wire format, batch after batch: every line is a
    /// JSON object, each header's counts equal the lines that follow it, and
    /// the device ID the caller asked for replaces the throwaway engine's.
    @Test func multiBatchJSONLIsAConcatenationOfValidBatches() async throws {
        let dir = try Fixture.tempDirectory()
        let transport = ExportFileTransport(
            format: .jsonl, directory: dir, baseName: "puls-export-test", deviceID: "real-device")
        let batches = [
            Fixture.batch(
                samples: (1...3).map { Fixture.quantity($0) },
                deletions: [SyncDeletion(uuid: UUID(), type: Fixture.heartRate)]),
            Fixture.batch(type: HealthTypeCatalog.workoutIdentifier, samples: [Fixture.workout(Fixture.workoutA)]),
            Fixture.batch(
                type: HealthTypeCatalog.workoutIdentifier,
                routes: [RoutePayload(workoutUUID: Fixture.workoutA, points: [
                    RoutePoint(t: Fixture.date(1_750_000_000_500), lat: 40.5, lon: -111.25),
                    RoutePoint(t: Fixture.date(1_750_000_001_500), lat: 40.6, lon: -111.26),
                ])]),
            Fixture.batch(aggregates: [AggregateSampleRow(
                type: Fixture.heartRate, function: .average, intervalValue: 1, intervalUnit: .day,
                deviceFilter: .all, bucketStart: Fixture.date(1_749_967_200_000),
                bucketEnd: Fixture.date(1_750_053_600_000), value: nil, unit: "count/min")]),
            Fixture.batch(
                type: HealthTypeCatalog.activitySummaryIdentifier,
                activitySummaries: [ActivitySummaryRow(
                    date: Fixture.date(1_749_967_200_000), localDate: "2025-06-15", moveKcal: 500)]),
        ]
        for batch in batches {
            let result = try await transport.upload(batch)
            #expect(result.bytesSent > 0)
            #expect(result.receipt == nil)
        }
        let files = try await transport.finish()
        #expect(files.map(\.url.lastPathComponent) == ["puls-export-test.jsonl"])
        let lines = try Fixture.lines(of: files[0].url)

        var headers = 0
        var index = 0
        while index < lines.count {
            let header = try Fixture.object(lines[index])
            #expect(header["batchID"] != nil, "line \(index + 1) should be a batch header")
            #expect(header["schemaVersion"] as? Int == PulsProtocol.version)
            #expect(header["deviceID"] as? String == "real-device")
            #expect(header["reason"] as? String == "manual")
            let counts = ["sampleCount", "deletionCount", "routeCount", "seriesCount",
                          "aggregateCount", "activitySummaryCount", "profileCount"]
                .map { header[$0] as? Int ?? 0 }
            let body = try lines[(index + 1)..<(index + 1 + counts.reduce(0, +))].map(Fixture.object)
            // Header lines are the only ones with a batchID: the split rule.
            #expect(body.allSatisfy { $0["batchID"] == nil })
            #expect(body.filter { $0["uuid"] != nil }.count == counts[0])
            #expect(body.filter { $0["deleted"] != nil }.count == counts[1])
            #expect(body.filter { $0["route"] != nil }.count == counts[2])
            #expect(body.filter { $0["aggregate"] != nil }.count == counts[4])
            #expect(body.filter { $0["activitySummary"] != nil }.count == counts[5])
            headers += 1
            index += 1 + body.count
        }
        #expect(headers == batches.count)
        #expect(index == lines.count)
        // Epoch milliseconds on every line, as on the wire.
        #expect(try Fixture.object(lines[1])["start"] as? Double == 1_750_000_001_000)
        // An empty bucket keeps its explicit null.
        #expect(lines.contains { $0.contains("\"aggregate\"") && $0.contains("\"value\":null") })

        let tally = await transport.tally
        #expect(tally.batches == 5)
        #expect(tally.rows == [
            .samples: 3, .deletions: 1, .workouts: 1, .workoutRoutes: 2, .aggregates: 1, .activity: 1,
        ])
        #expect(tally.notRepresented(in: .jsonl).isEmpty)
        #expect(tally.bytes == files[0].bytes)

        // TEST_RUNNER_PULS_EXPORT_SAMPLE_DIR=<dir> on the xcodebuild command
        // line keeps a copy, for running tools/protocol-check over by hand.
        if let keep = ProcessInfo.processInfo.environment["PULS_EXPORT_SAMPLE_DIR"] {
            let target = URL(fileURLWithPath: keep, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let copy = target.appendingPathComponent("sample-export.jsonl")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: files[0].url, to: copy)
        }
    }

    /// CSV has no file for an ECG trace, a heartbeat series or a tombstone.
    /// They are counted, never dropped without a word.
    @Test func csvCountsWhatItCannotRepresent() async throws {
        let dir = try Fixture.tempDirectory()
        let transport = ExportFileTransport(format: .csv, directory: dir, baseName: "t")
        let ecg = SyncSample(
            uuid: UUID(), type: "HKDataTypeIdentifierElectrocardiogram", kind: .ecg,
            start: Fixture.date(0), end: Fixture.date(30_000),
            ecg: ECGDetail(classification: "sinusRhythm", symptomsStatus: "none", voltagesUV: [1, 2, 3]))
        let beats = SyncSample(
            uuid: UUID(), type: HealthTypeCatalog.heartbeatSeriesIdentifier, kind: .heartbeatSeries,
            start: Fixture.date(0), end: Fixture.date(60_000),
            heartbeats: [Heartbeat(timeSinceSeriesStart: 0.8, precededByGap: false)])
        _ = try await transport.upload(Fixture.batch(
            samples: [Fixture.quantity(1), ecg, ecg, beats],
            deletions: [SyncDeletion(uuid: UUID(), type: Fixture.heartRate)]))
        let files = try await transport.finish()

        #expect(files.map(\.dataset) == [.samples])
        #expect(try Fixture.lines(of: files[0].url).count == 2)
        let tally = await transport.tally
        #expect(tally.written(in: .csv) == [.samples: 1])
        #expect(tally.notRepresented(in: .csv) == [.ecg: 2, .heartbeatSeries: 1, .deletions: 1])
    }

    @Test func progressReportsWrittenRowsPhaseAndType() async throws {
        let dir = try Fixture.tempDirectory()
        let seen = ProgressBox()
        let transport = ExportFileTransport(
            format: .csv, directory: dir, baseName: "t", progress: { seen.append($0) })
        await transport.setPhase(.samples)
        _ = try await transport.upload(Fixture.batch(
            samples: [Fixture.quantity(1), Fixture.quantity(2)],
            deletions: [SyncDeletion(uuid: UUID(), type: Fixture.heartRate)]))
        let updates = seen.values
        #expect(updates.count == 2)
        #expect(updates[0] == ExportProgress(phase: .samples))
        #expect(updates[1].phase == .samples)
        #expect(updates[1].currentType == Fixture.heartRate)
        // The deletion is not a written row in a CSV export.
        #expect(updates[1].rowsWritten == 2)
        #expect(updates[1].bytesWritten > 0)
    }

    @Test func abortRemovesFilesAndRefusesFurtherWrites() async throws {
        let dir = try Fixture.tempDirectory()
        let transport = ExportFileTransport(format: .jsonl, directory: dir, baseName: "t")
        _ = try await transport.upload(Fixture.batch(samples: [Fixture.quantity(1)]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["t.jsonl"])
        await transport.abort()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        await #expect(throws: HealthExportError.self) {
            _ = try await transport.upload(Fixture.batch(samples: [Fixture.quantity(2)]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// A cancelled export must stop growing its files at the next batch.
    @Test func cancelledTaskWritesNothingMore() async throws {
        let dir = try Fixture.tempDirectory()
        let transport = ExportFileTransport(format: .jsonl, directory: dir, baseName: "t")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.upload(Fixture.batch(samples: [Fixture.quantity(1)]))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await transport.finish().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// A write that fails is remembered: later batches fail fast with the same
    /// reason instead of each type rediscovering a full disk.
    @Test func aWriteFailureIsStickyAndReported() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-test-missing-\(UUID().uuidString)", isDirectory: true)
        let transport = ExportFileTransport(format: .jsonl, directory: missing, baseName: "t")
        await #expect(throws: HealthExportError.self) {
            _ = try await transport.upload(Fixture.batch(samples: [Fixture.quantity(1)]))
        }
        #expect(await transport.writeFailure != nil)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        await #expect(throws: HealthExportError.self) {
            _ = try await transport.upload(Fixture.batch(samples: [Fixture.quantity(2)]))
        }
        #expect(await transport.tally.batches == 0)
    }
}

/// Collects progress callbacks, which arrive on the transport's executor.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExportProgress] = []
    func append(_ progress: ExportProgress) { lock.withLock { storage.append(progress) } }
    var values: [ExportProgress] { lock.withLock { storage } }
}

// MARK: - Plan, completion, manifest

@Suite struct ExportPlanTests {
    private func request(_ config: SyncConfiguration, start: Date? = nil) -> ExportRequest {
        ExportRequest(configuration: config, startDate: start, format: .jsonl)
    }

    /// The export engine must have no server to reach and no identity to
    /// write: no URL/token means `configure` builds no transport, and an empty
    /// profile means no `{"profile":…}` line rides a workout batch.
    @Test func exportConfigurationHasNoServerAndNoIdentity() throws {
        var config = SyncConfiguration(
            enabledTypes: [Fixture.heartRate],
            serverURL: URL(string: "https://example.invalid"), authToken: "secret",
            aggregates: [
                AggregateConfig(typeIdentifier: Fixture.heartRate, function: .average),
                AggregateConfig(typeIdentifier: Fixture.heartRate, function: .max, enabled: false),
            ],
            userID: "11111111-2222-4333-8444-555555555555",
            userName: "A Person", userEmail: "person@example.invalid",
            userDateOfBirth: Fixture.date(0), userBiologicalSex: "female")
        config.batchSize = 500
        let floor = Fixture.date(978_307_200_000)

        let allTime = ExportPlan.configuration(for: request(config), floor: floor)
        #expect(allTime.serverURL == nil)
        #expect(allTime.authToken == nil)
        #expect(allTime.userProfilePayload.isEmpty)
        #expect(allTime.userID == config.userID)
        #expect(allTime.startDate == floor)
        #expect(allTime.enabledTypes == config.enabledTypes)
        #expect(allTime.batchSize == 500)
        #expect(allTime.aggregates.map(\.function) == [.average])

        let since = Fixture.date(1_700_000_000_000)
        #expect(ExportPlan.configuration(for: request(config, start: since), floor: floor).startDate == since)

        #expect(ExportPlan.hasAnythingToExport(ExportSelection(configuration: config)))
        #expect(!ExportPlan.hasAnythingToExport(ExportSelection(configuration: SyncConfiguration())))
    }

    /// The export's selection is the export's, not the app's: a type the
    /// configuration does not sync and a series it does not compute are
    /// exported when the selection names them, and its own are left out when
    /// it does not. A bounded export has nothing to settle, an unbounded one
    /// keeps its settle delays.
    @Test func selectionOverridesTheAppliedConfiguration() throws {
        var config = SyncConfiguration(
            enabledTypes: [Fixture.heartRate],
            aggregates: [AggregateConfig(typeIdentifier: Fixture.heartRate, function: .average)])
        config.includeWorkoutRoutes = true
        config.includeWorkoutEnhancedData = false
        config.batchSize = 250

        var chosen = AggregateConfig(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum, settleDelay: 900)
        chosen.enabled = false // presence is the decision; the flag is ignored
        let selection = ExportSelection(
            types: [Fixture.sleep, HealthTypeCatalog.workoutIdentifier],
            aggregates: [chosen],
            includeWorkoutRoutes: false,
            includeWorkoutEnhancedData: true)
        let end = Fixture.date(1_750_000_000_000)

        let bounded = ExportPlan.configuration(for: ExportRequest(
            selection: selection, configuration: config, endDate: end, format: .csv))
        #expect(bounded.enabledTypes == selection.types)
        #expect(!bounded.enabledTypes.contains(Fixture.heartRate))
        #expect(bounded.aggregates.map(\.id) == [chosen.id])
        #expect(bounded.aggregates.map(\.enabled) == [true])
        #expect(bounded.aggregates.map(\.settleDelay) == [0])
        #expect(!bounded.includeWorkoutRoutes)
        #expect(bounded.includeWorkoutEnhancedData)
        #expect(bounded.batchSize == 250)
        #expect(bounded.userID == config.userID)

        let unbounded = ExportPlan.configuration(for: ExportRequest(
            selection: selection, configuration: config, endDate: nil, format: .csv))
        #expect(unbounded.aggregates.map(\.settleDelay) == [900])

        // The back-compat initialiser is the applied selection.
        let applied = ExportRequest(configuration: config, format: .jsonl)
        #expect(applied.selection == ExportSelection(configuration: config))
        #expect(applied.endDate == nil)
        #expect(ExportPlan.configuration(for: applied).enabledTypes == [Fixture.heartRate])
    }

    /// An export that reaches further back than the sync's start date must
    /// stay on the sync's bucket grid, or a replay upserts a second,
    /// interleaved set of buckets beside the server's.
    @Test func aggregateStartSnapsToTheRealSyncGrid() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Denver"))
        func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
        }
        let syncStart = day(2025, 6, 11, hour: 15) // a Wednesday afternoon
        let weekly = AggregateConfig(
            typeIdentifier: Fixture.heartRate, function: .average, intervalValue: 1, intervalUnit: .week)

        // First sample on a Saturday two years earlier: start on the Wednesday
        // at or before it — the sync grid's weekday — at local midnight.
        let earlier = ExportPlan.alignedAggregateStart(
            for: weekly, syncStartDate: syncStart, exportStartDate: day(2001, 1, 1),
            earliestSample: day(2023, 3, 4, hour: 9), calendar: calendar)
        #expect(earlier == day(2023, 3, 1))
        let weeks = calendar.dateComponents([.day], from: earlier, to: day(2025, 6, 11)).day!
        #expect(weeks % 7 == 0)

        // A requested start later than the first sample wins, still snapped.
        let bounded = ExportPlan.alignedAggregateStart(
            for: weekly, syncStartDate: syncStart, exportStartDate: day(2025, 7, 4),
            earliestSample: day(2023, 3, 4), calendar: calendar)
        #expect(bounded == day(2025, 7, 2))

        // The series' own start date is both its anchor and its floor.
        var monthly = AggregateConfig(
            typeIdentifier: Fixture.heartRate, function: .average, intervalValue: 1, intervalUnit: .month)
        monthly.startDate = day(2024, 1, 17)
        let own = ExportPlan.alignedAggregateStart(
            for: monthly, syncStartDate: syncStart, exportStartDate: day(2001, 1, 1),
            earliestSample: day(2020, 5, 5), calendar: calendar)
        #expect(own == day(2024, 1, 17))
        let midMonth = ExportPlan.alignedAggregateStart(
            for: monthly, syncStartDate: syncStart, exportStartDate: day(2024, 9, 1),
            earliestSample: day(2020, 5, 5), calendar: calendar)
        #expect(midMonth == day(2024, 8, 17))
    }

    /// The engine logs and carries on when it cannot read something. The
    /// completion check is what turns that back into a reported failure.
    @Test func unfinishedUnitsAreReportedWithTheEnginesReason() {
        let steps = "HKQuantityTypeIdentifierStepCount"
        let average = AggregateConfig(typeIdentifier: Fixture.heartRate, function: .average, intervalUnit: .hour)
        let maximum = AggregateConfig(typeIdentifier: Fixture.heartRate, function: .max)
        let config = SyncConfiguration(
            enabledTypes: [
                Fixture.heartRate, steps, HealthTypeCatalog.workoutIdentifier,
                HealthTypeCatalog.activitySummaryIdentifier,
            ],
            includeWorkoutRoutes: true, includeWorkoutEnhancedData: false,
            aggregates: [average, maximum])

        var outcome = ExportPlan.Outcome()
        var done = TypeSyncState(identifier: Fixture.heartRate)
        done.backfillComplete = true
        outcome.typeStates[Fixture.heartRate] = done
        var denied = TypeSyncState(identifier: steps)
        denied.lastError = "Health access not granted"
        outcome.typeStates[steps] = denied
        // Workouts: no state at all — the locked path records nothing.
        outcome.activitySummary.computedThrough = Date()
        var computed = AggregateSyncState(configID: average.id)
        computed.lastFullRecomputeAt = Date()
        outcome.aggregateStates[average.id] = computed

        let workout = HealthTypeCatalog.workoutIdentifier
        let events = [
            ExportPlan.PhasedEvent(phase: .samples, event: SyncEvent(
                level: .warn, type: workout, message: "Health database locked (device locked) — will retry on next wake")),
            ExportPlan.PhasedEvent(phase: .aggregates, event: SyncEvent(
                level: .error, type: Fixture.heartRate, message: "Aggregate \(maximum.summaryLabel) failed: boom")),
            ExportPlan.PhasedEvent(phase: .aggregates, event: SyncEvent(
                level: .warn, type: Fixture.heartRate, message: "Aggregate \(average.summaryLabel): something unrelated")),
            ExportPlan.PhasedEvent(phase: .workoutRoutes, event: SyncEvent(
                level: .warn, type: workout, message: "Workout routes: Health database locked — will retry on next wake")),
            ExportPlan.PhasedEvent(phase: .samples, event: SyncEvent(
                level: .warn, type: Fixture.heartRate, message: "3 of 9 heartbeat series unreadable")),
        ]

        let failures = ExportPlan.failures(config: config, outcome: outcome, events: events)
        #expect(failures == [
            ExportIssue(type: steps, message: "Health access not granted"),
            ExportIssue(type: workout, message: "Health database locked (device locked) — will retry on next wake"),
            ExportIssue(type: Fixture.heartRate, message: "Aggregate \(maximum.summaryLabel) failed: boom"),
            ExportIssue(type: workout, message: "Workout routes: Health database locked — will retry on next wake"),
        ])

        // Warnings are what is left once the failures have quoted theirs.
        let warnings = ExportPlan.warnings(from: events, excluding: failures)
        #expect(warnings.map(\.message) == [
            "Aggregate \(average.summaryLabel): something unrelated",
            "3 of 9 heartbeat series unreadable",
        ])
        let flood = (0..<60).map {
            ExportPlan.PhasedEvent(phase: .samples, event: SyncEvent(level: .warn, message: "w\($0)"))
        }
        let capped = ExportPlan.warnings(from: flood, excluding: [], limit: 50)
        #expect(capped.count == 51)
        #expect(capped.last?.message == "…and 10 more warnings")
    }

    @Test func aFullyFinishedSweepHasNoFailures() {
        let config = SyncConfiguration(
            enabledTypes: [Fixture.heartRate, HealthTypeCatalog.workoutIdentifier],
            includeWorkoutRoutes: true, includeWorkoutEnhancedData: true)
        var outcome = ExportPlan.Outcome()
        for id in config.enabledTypes {
            var state = TypeSyncState(identifier: id)
            state.backfillComplete = true
            outcome.typeStates[id] = state
        }
        outcome.workoutRoutes.lastFullRecomputeAt = Date()
        outcome.workoutStreams.lastFullRecomputeAt = Date()
        #expect(ExportPlan.failures(config: config, outcome: outcome, events: []).isEmpty)
    }

    /// The collector sees every warning however long the run — the log itself
    /// is a 2,000-entry ring that a real export overflows many times over.
    @Test func collectorOutlivesTheEventLogRingAndTagsPhases() async throws {
        let log = SyncEventLog(directory: try Fixture.tempDirectory())
        let collector = await ExportEventCollector.start(on: log)
        await collector.mark(.samples)
        await log.log(.error, type: Fixture.heartRate, "first failure")
        for page in 0..<(SyncEventLog.capacity + 50) { await log.log(.debug, "Page \(page)") }
        await collector.mark(.aggregates)
        await log.log(.warn, type: Fixture.heartRate, "late warning")
        await log.log(.info, "not kept")
        let events = await collector.finish()

        #expect(await log.recent(limit: .max).contains { $0.message == "first failure" } == false)
        #expect(events.map(\.phase) == [.samples, .aggregates])
        #expect(events.map(\.event.message) == ["first failure", "late warning"])
    }

    @Test func manifestRecordsWhoWhenAndWhatIsMissing() throws {
        let dir = try Fixture.tempDirectory()
        let url = dir.appendingPathComponent("t-manifest.json")
        let manifest = ExportManifest(
            format: .csv, schemaVersion: PulsProtocol.version, clientVersion: "1.5 (16)",
            createdAt: Fixture.date(1_750_000_000_000), startDate: nil, endDate: nil,
            userID: PulsDefaultUser.id, deviceID: "real-device", timeZone: "America/Denver",
            complete: false, types: [Fixture.heartRate],
            aggregates: ["HKQuantityTypeIdentifierHeartRate|average|1|day|all"],
            files: [.init(name: "t-samples.csv", dataset: "samples", rows: 2, bytes: 120)],
            rows: ["samples": 2, "ecg": 1], batches: 1, notRepresented: ["ecg": 1],
            unmappableSamples: [:],
            failures: [ExportIssue(type: Fixture.sleep, message: "Health access not granted")])
        let bytes = try manifest.write(to: url)
        let data = try Data(contentsOf: url)
        #expect(bytes == Int64(data.count))

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["userID"] as? String == PulsDefaultUser.id)
        #expect(object["createdAt"] as? Double == 1_750_000_000_000) // epoch ms
        #expect(object["startDate"] is NSNull)                       // explicit: all time
        #expect(object["endDate"] is NSNull)                         // explicit: now
        #expect((object["aggregates"] as? [String]) == ["HKQuantityTypeIdentifierHeartRate|average|1|day|all"])
        #expect(object["complete"] as? Bool == false)
        #expect(object["schemaVersion"] as? Int == PulsProtocol.version)
        #expect((object["notRepresented"] as? [String: Int]) == ["ecg": 1])
        #expect(try JSONDecoder.puls.decode(ExportManifest.self, from: data) == manifest)
    }

    @Test func fileNamesCarryALocalSortableTimestamp() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(HealthExporter.timestamp(Fixture.date(1_750_000_000_000), timeZone: utc) == "20250615-150640")
    }
}

// MARK: - Zipping

/// Serialized, and the only suite that touches the temporary directory's
/// `CoordinatedZipFile…` scratch: `removeAllExports()` sweeps it, and run
/// beside a zip in flight it would pull the archive out from under the
/// coordinator.
@Suite(.serialized) struct ExportZipTests {
    @Test func aFolderBecomesOneDeflatedArchiveUnderItsName() async throws {
        let dir = try Fixture.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("puls-export-20260930-120000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csv = Data(("type,unit,uuid,start,end,value,label,source\n" + (0..<5_000).map {
            "\(Fixture.heartRate),count/min,\(UUID().uuidString.lowercased()),\(1_767_225_600_000 + $0 * 60_000),"
                + "\(1_767_225_600_000 + $0 * 60_000),\(60 + $0 % 40),,Apple Watch\n"
        }.joined()).utf8)
        let manifest = Data(#"{"complete":true}"#.utf8)
        try csv.write(to: folder.appendingPathComponent("puls-export-20260930-120000-samples.csv"))
        try manifest.write(to: folder.appendingPathComponent("puls-export-20260930-120000-manifest.json"))

        let destination = dir.appendingPathComponent("puls-export-20260930-120000.zip")
        let zipped = try await ExportZipper.zip(folder: folder, to: destination)

        let archive = try Data(contentsOf: destination)
        #expect(zipped.bytes == Int64(archive.count))
        #expect(zipped.bytes < Int64(csv.count) / 2)
        let entries = try ZipReader.entries(archive)
        #expect(Set(entries.map(\.name)) == [
            "puls-export-20260930-120000/puls-export-20260930-120000-samples.csv",
            "puls-export-20260930-120000/puls-export-20260930-120000-manifest.json",
        ])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let samples = try #require(byName["puls-export-20260930-120000/puls-export-20260930-120000-samples.csv"])
        #expect(samples.method == 8) // deflate
        #expect(samples.contents == csv)
        #expect(byName["puls-export-20260930-120000/puls-export-20260930-120000-manifest.json"]?.contents == manifest)

        // The sweep in `removeAllExports()` finds a crashed zip by this name,
        // under the temporary directory. If iOS renames it, this is the alarm.
        #expect(zipped.scratchDirectory.lastPathComponent.hasPrefix(ExportZipper.scratchPrefix))
        #expect(zipped.scratchDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
            == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        #expect(!FileManager.default.fileExists(atPath: zipped.scratchDirectory.path))
    }

    @Test func removeAllExportsClearsTheStagingRootAndAnInterruptedZip() throws {
        let fm = FileManager.default
        let staged = HealthExporter.stagingRoot.appendingPathComponent("leftover", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staged.appendingPathComponent("puls-export-old.jsonl"))
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("\(ExportZipper.scratchPrefix)test\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("PK".utf8).write(to: scratch.appendingPathComponent("puls-export-old.zip"))
        let bystander = try Fixture.tempDirectory()
        defer { try? fm.removeItem(at: bystander) }

        #expect(HealthExporter.removeAllExports())
        #expect(!fm.fileExists(atPath: HealthExporter.stagingRoot.path))
        #expect(!fm.fileExists(atPath: scratch.path))
        #expect(fm.fileExists(atPath: bystander.path))
        // Idempotent: nothing staged is not a failure.
        #expect(HealthExporter.removeAllExports())
    }
}

/// Just enough of a zip reader to check what the coordinator wrote: the
/// central directory's entries, each inflated back to its bytes.
private enum ZipReader {
    struct Entry {
        var name: String
        var method: UInt16
        var contents: Data
    }

    struct Malformed: Error {}

    static func entries(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        // End of central directory: the last "PK\u{5}\u{6}".
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1)
            .first(where: { u32($0) == 0x0605_4b50 }) else { throw Malformed() }
        var at = u32(eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<u16(eocd + 10) {
            guard u32(at) == 0x0201_4b50 else { throw Malformed() }
            let method = UInt16(u16(at + 10))
            let compressed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32)
            let local = u32(at + 42)
            let name = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            at += 46 + nameLength + extra + comment

            guard u32(local) == 0x0403_4b50 else { throw Malformed() }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let payload = Array(bytes[start..<(start + compressed)])
            entries.append(Entry(name: name, method: method, contents: try inflate(payload, method: method, size: size)))
        }
        return entries
    }

    private static func inflate(_ payload: [UInt8], method: UInt16, size: Int) throws -> Data {
        switch method {
        case 0:
            return Data(payload)
        case 8:
            var out = [UInt8](repeating: 0, count: max(size, 1))
            let count = compression_decode_buffer(&out, out.count, payload, payload.count, nil, COMPRESSION_ZLIB)
            guard count == size else { throw Malformed() }
            return Data(out.prefix(count))
        default:
            throw Malformed()
        }
    }
}
