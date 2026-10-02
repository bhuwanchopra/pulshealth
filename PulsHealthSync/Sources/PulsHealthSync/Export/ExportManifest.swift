import Foundation

/// `…-manifest.json`, written beside the data files of both formats.
///
/// It exists for what the data files cannot say. On the wire the user is an
/// HTTP header (`X-User-ID`), not part of the NDJSON body, so a JSONL export
/// alone does not record whose data it is — and a replay needs to send that
/// header. Neither format records the range that was asked for, whether the
/// run reached the end, or what could not be written; a file that stops short
/// looks exactly like a file of someone with less data.
///
/// Dates are epoch milliseconds like everything else (`JSONEncoder.puls`).
struct ExportManifest: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        var name: String
        /// Dataset name (`ExportDataset.rawValue`); absent for the JSONL file,
        /// which holds all of them.
        var dataset: String?
        var rows: Int?
        var bytes: Int64
    }

    var format: ExportFormat
    /// `PulsProtocol.version` — the wire format a JSONL export is written in,
    /// and the vocabulary (type identifiers, canonical units) of a CSV one.
    var schemaVersion: Int
    /// `"<marketing version> (<build>)"` of the app that wrote the export.
    var clientVersion: String
    var createdAt: Date
    /// Nil (an explicit JSON `null`) = all time.
    var startDate: Date?
    /// Exclusive end of the range asked for. Nil (an explicit JSON `null`) =
    /// now, i.e. `createdAt`.
    var endDate: Date?
    /// The `X-User-ID` a replay should send.
    var userID: String
    var deviceID: String
    /// The zone local days were computed in (`activity.date`,
    /// `state_of_mind.date`, day-grain aggregate buckets).
    var timeZone: String
    /// False when anything is listed in `failures`, `unmappableSamples` or
    /// `limitedHistory`.
    var complete: Bool
    var types: [String]
    /// The exported aggregate series, each as its `seriesIdentity`
    /// (`type|func|intervalValue|intervalUnit|deviceFilter`), sorted.
    var aggregates: [String]
    var files: [File]
    /// Rows per dataset, written or not.
    var rows: [String: Int]
    /// JSONL: how many batches (header lines) the file holds.
    var batches: Int
    var notRepresented: [String: Int]
    var unmappableSamples: [String: Int]
    /// iOS 27 limited history access: types HealthKit let this export read
    /// only from the given date, which is later than `startDate`. Whatever
    /// they hold before it is in no file — and the files cannot show that.
    var limitedHistory: [String: Date] = [:]
    var failures: [ExportIssue]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(clientVersion, forKey: .clientVersion)
        try c.encode(createdAt, forKey: .createdAt)
        // Explicit null, not omitted: "all time" is a statement, and a reader
        // should not have to tell it from a manifest that forgot the field.
        if let startDate {
            try c.encode(startDate, forKey: .startDate)
        } else {
            try c.encodeNil(forKey: .startDate)
        }
        if let endDate {
            try c.encode(endDate, forKey: .endDate)
        } else {
            try c.encodeNil(forKey: .endDate)
        }
        try c.encode(userID, forKey: .userID)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(complete, forKey: .complete)
        try c.encode(types, forKey: .types)
        try c.encode(aggregates, forKey: .aggregates)
        try c.encode(files, forKey: .files)
        try c.encode(rows, forKey: .rows)
        try c.encode(batches, forKey: .batches)
        try c.encode(notRepresented, forKey: .notRepresented)
        try c.encode(unmappableSamples, forKey: .unmappableSamples)
        try c.encode(limitedHistory, forKey: .limitedHistory)
        try c.encode(failures, forKey: .failures)
    }

    /// Pretty-printed with sorted keys: it is the one file of an export a
    /// person is likely to open in a text editor.
    func write(to url: URL) throws -> Int64 {
        let encoder = JSONEncoder.puls
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let file = try ExportFile(url: url)
        do {
            try file.append(data)
            try file.close()
        } catch {
            file.delete()
            throw error
        }
        return Int64(data.count)
    }
}
