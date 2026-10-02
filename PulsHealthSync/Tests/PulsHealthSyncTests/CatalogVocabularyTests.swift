import Foundation
import HealthKit
import Testing
@testable import PulsHealthSync

// MARK: - Renderer

/// Renders the published type vocabulary, `docs/protocol/catalog.json`, from
/// the live catalog. See `docs/protocol/catalog.md` for the file's contract.
///
/// The layout is fixed so the file diffs cleanly and any stock JSON parser
/// reads it: one object per `HealthTypeCatalog.definitions` entry sorted by
/// identifier, keys in a fixed order, 2-space indentation, a trailing newline,
/// and no escaping beyond what JSON requires — byte-for-byte what Node's
/// `JSON.stringify(value, null, 2) + "\n"` produces for the same value, which
/// is how `web/scripts/gen-catalog.mjs` can round-trip it.
enum CatalogVocabulary {
    static let relativePath = "docs/protocol/catalog.json"

    /// The one-line regeneration recipe, printed by every failure. The
    /// `TEST_RUNNER_` prefix is xcodebuild's: an environment variable of the
    /// xcodebuild process so named reaches the test runner with the prefix
    /// stripped (a build-setting argument of the same name does not).
    static let regenerateCommand = """
        cd PulsHealthSync && TEST_RUNNER_PULS_WRITE_CATALOG=1 xcodebuild test \
        -scheme PulsHealthSync -destination 'platform=iOS Simulator,name=iPhone 17' \
        -only-testing:PulsHealthSyncTests/CatalogVocabularyTests
        """

    /// True when this runtime has every catalog quantity type, so HealthKit
    /// can answer `aggregationStyle` for all of them. Below the newest gate
    /// (HRV RMSSD, iOS 27) the rendering tests are skipped — CI's Xcode 27
    /// job runs them — unless `PULS_WRITE_CATALOG=1` asks for a rewrite, which
    /// then fails with `RenderError` naming the runtime it needs.
    static var isRenderableHere: Bool {
        HealthTypeCatalog.definitions.allSatisfy { $0.kind != .quantity || $0.isAvailableOnThisOS }
            || ProcessInfo.processInfo.environment["PULS_WRITE_CATALOG"] == "1"
    }

    struct RenderError: Error, CustomStringConvertible {
        let description: String
    }

    /// A JSON value whose object keys keep insertion order.
    indirect enum JSON {
        case null
        case int(Int)
        case string(String)
        case array([JSON])
        case object([(String, JSON)])
    }

    static func render() throws -> String {
        serialize(try document(), indent: 0) + "\n"
    }

    static func document() throws -> JSON {
        let definitions = HealthTypeCatalog.definitions.sorted { $0.identifier < $1.identifier }
        return .object([
            ("protocol", .int(PulsProtocol.version)),
            ("source", .string("PulsHealthSync/Sources/PulsHealthSync/Models/HealthTypeCatalog.swift")),
            ("groups", .array(HealthTypeDescriptor.Group.allCases.map { group in
                .object([("key", .string(group.key)), ("label", .string(group.rawValue))])
            })),
            ("types", .array(try definitions.map(entry))),
        ])
    }

    static func entry(_ descriptor: HealthTypeDescriptor) throws -> JSON {
        let style = try aggregationStyle(of: descriptor)
        let functions = HealthTypeCatalog.allowedAggregateFunctions(for: descriptor.identifier)
        return .object([
            ("identifier", .string(descriptor.identifier)),
            ("kind", .string(descriptor.kind.rawValue)),
            ("unit", descriptor.unitString.map(JSON.string) ?? .null),
            ("aggregationStyle", style.map(JSON.string) ?? .null),
            ("allowedAggregateFunctions", .array(functions.map { .string($0.rawValue) })),
            ("minimumIOS", .string(descriptor.minimumIOS.description)),
            ("displayName", .string(descriptor.displayName)),
            ("group", .string(descriptor.group.key)),
            ("estimatedSamplesPerDay", .int(descriptor.estimatedSamplesPerDay)),
        ])
    }

    /// HealthKit's aggregation style for a quantity type, named after the
    /// `HKQuantityAggregationStyle` case; nil for every other kind. Read from
    /// HealthKit, like `allowedAggregateFunctions(for:)`, so the catalog never
    /// hand-maintains a copy — which means a quantity type gated above the
    /// rendering runtime cannot be published until the test runs on that OS.
    static func aggregationStyle(of descriptor: HealthTypeDescriptor) throws -> String? {
        guard descriptor.kind == .quantity else { return nil }
        guard descriptor.isAvailableOnThisOS else {
            throw RenderError(description: """
                \(descriptor.identifier) needs iOS \(descriptor.minimumIOS) and this runtime is \
                \(ProcessInfo.processInfo.operatingSystemVersionString): its aggregation style and \
                allowed functions come from HealthKit, so render the vocabulary on a simulator \
                that has the type.
                """)
        }
        let type = HKQuantityType(HKQuantityTypeIdentifier(rawValue: descriptor.identifier))
        switch type.aggregationStyle {
        case .cumulative: return "cumulative"
        case .discreteArithmetic: return "discreteArithmetic"
        case .discreteTemporallyWeighted: return "discreteTemporallyWeighted"
        case .discreteEquivalentContinuousLevel: return "discreteEquivalentContinuousLevel"
        @unknown default:
            throw RenderError(description:
                "\(descriptor.identifier) has an aggregation style this renderer does not name")
        }
    }

    // JSON.stringify(value, null, 2) layout: nested values indented two spaces
    // per level, `"key": value`, empty containers as `[]` / `{}`.
    static func serialize(_ value: JSON, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch value {
        case .null: return "null"
        case .int(let n): return String(n)
        case .string(let s): return quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { inner + serialize($0, indent: indent + 2) }
            return "[\n" + body.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            let body = members.map { inner + quote($0.0) + ": " + serialize($0.1, indent: indent + 2) }
            return "{\n" + body.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    /// JSON.stringify's string escaping: quotes, backslashes and C0 controls
    /// only — `/` and non-ASCII (`VO₂ Max`) stay literal.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The repository root, found from this file's path (`<root>/PulsHealthSync/
    /// Tests/PulsHealthSyncTests/CatalogVocabularyTests.swift`).
    static func repositoryRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent() // PulsHealthSyncTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PulsHealthSync
            .deletingLastPathComponent() // <root>
    }

    /// A human-readable account of where two renderings first diverge.
    static func firstDifference(committed: String, generated: String) -> String {
        let a = committed.components(separatedBy: "\n")
        let b = generated.components(separatedBy: "\n")
        for (index, (x, y)) in zip(a, b).enumerated() where x != y {
            return "line \(index + 1):\n  committed: \(x)\n  catalog:   \(y)"
        }
        if a.count != b.count {
            let longer = a.count > b.count ? "committed file" : "catalog rendering"
            return "line \(min(a.count, b.count) + 1): the \(longer) has \(abs(a.count - b.count)) more line(s)"
        }
        return "identical text, different bytes (line endings or a missing trailing newline?)"
    }
}

// MARK: - Tests

@Suite struct CatalogVocabularyTests {
    /// The committed `docs/protocol/catalog.json` must equal, byte for byte,
    /// what the live catalog renders. With `PULS_WRITE_CATALOG=1` in the test
    /// runner's environment (`TEST_RUNNER_PULS_WRITE_CATALOG=1` on the
    /// xcodebuild command line) the test rewrites the file instead.
    @Test(.enabled(if: CatalogVocabulary.isRenderableHere, "a catalog quantity type is gated above this runtime; rendered on the newest simulator"))
    func publishedVocabularyMatchesTheCatalog() throws {
        let root = CatalogVocabulary.repositoryRoot()
        let url = root.appendingPathComponent(CatalogVocabulary.relativePath)
        let docs = root.appendingPathComponent("docs/protocol", isDirectory: true)
        try #require(
            FileManager.default.fileExists(atPath: docs.path),
            "cannot find docs/protocol under \(root.path) — is the package inside the repository?")

        let generated = try CatalogVocabulary.render()

        if ProcessInfo.processInfo.environment["PULS_WRITE_CATALOG"] == "1" {
            try generated.write(to: url, atomically: true, encoding: .utf8)
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written == generated, "wrote \(url.path) but reading it back differs")
            print("PULS_WRITE_CATALOG: wrote \(url.path) (\(generated.utf8.count) bytes)")
            return
        }

        let committed = try String(contentsOf: url, encoding: .utf8)
        let matches = committed == generated
        if !matches {
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("catalog.generated.json")
            try? generated.write(to: scratch, atomically: true, encoding: .utf8)
            #expect(matches, Comment(rawValue: """
                \(CatalogVocabulary.relativePath) is out of date with HealthTypeCatalog.
                First difference at \(CatalogVocabulary.firstDifference(committed: committed, generated: generated))
                Fresh rendering written to \(scratch.path); diff it against the committed file, or regenerate:
                  \(CatalogVocabulary.regenerateCommand)
                then run `npm run gen:catalog` in web/ and commit both.
                """))
        }
    }

    @Test(.enabled(if: CatalogVocabulary.isRenderableHere, "a catalog quantity type is gated above this runtime; rendered on the newest simulator"))
    func renderingIsValidJSONSortedByIdentifier() throws {
        let text = try CatalogVocabulary.render()
        #expect(text.hasSuffix("}\n"))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let document = try #require(object)
        #expect(document["protocol"] as? Int == PulsProtocol.version)

        let types = try #require(document["types"] as? [[String: Any]])
        let identifiers = types.compactMap { $0["identifier"] as? String }
        #expect(identifiers.count == HealthTypeCatalog.definitions.count)
        #expect(identifiers == identifiers.sorted())
        #expect(Set(identifiers).count == identifiers.count)

        let groups = try #require(document["groups"] as? [[String: String]])
        #expect(groups.map { $0["key"] } == HealthTypeDescriptor.Group.allCases.map(\.key))
        let groupKeys = Set(groups.compactMap { $0["key"] })
        for type in types {
            #expect(groupKeys.contains(type["group"] as? String ?? ""), "\(type["identifier"] ?? "?") has an unknown group")
        }
    }

    @Test(.enabled(if: CatalogVocabulary.isRenderableHere, "a catalog quantity type is gated above this runtime; rendered on the newest simulator"))
    func entriesCarryTheCatalogFacts() throws {
        let text = try CatalogVocabulary.render()
        let document = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let types = try #require(document["types"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: types.map { ($0["identifier"] as! String, $0) })

        let steps = try #require(byID["HKQuantityTypeIdentifierStepCount"])
        #expect(steps["kind"] as? String == "quantity")
        #expect(steps["unit"] as? String == "count")
        #expect(steps["aggregationStyle"] as? String == "cumulative")
        #expect(steps["allowedAggregateFunctions"] as? [String] == ["sum", "mostRecent", "duration"])
        #expect(steps["minimumIOS"] as? String == "17.0")
        #expect(steps["group"] as? String == "activity")
        #expect(steps["displayName"] as? String == "Steps")
        #expect(steps["estimatedSamplesPerDay"] as? Int == 250)

        let heartRate = try #require(byID["HKQuantityTypeIdentifierHeartRate"])
        #expect(heartRate["aggregationStyle"] as? String == "discreteTemporallyWeighted")
        #expect(heartRate["allowedAggregateFunctions"] as? [String] == ["average", "min", "max", "mostRecent", "duration"])

        // Non-quantity kinds: no unit, no style, no functions; gates are declarative.
        let sleep = try #require(byID["HKCategoryTypeIdentifierSleepAnalysis"])
        #expect(sleep["unit"] is NSNull)
        #expect(sleep["aggregationStyle"] is NSNull)
        #expect(sleep["allowedAggregateFunctions"] as? [String] == [])
        #expect(byID[HealthTypeCatalog.sleepApneaEventIdentifier]?["minimumIOS"] as? String == "18.0")
        #expect(byID[HealthTypeCatalog.stateOfMindIdentifier]?["minimumIOS"] as? String == "18.0")
        #expect(byID[HealthTypeCatalog.medicationDoseIdentifier]?["minimumIOS"] as? String == "26.0")
        #expect(byID[HealthTypeCatalog.activitySummaryIdentifier]?["kind"] as? String == "activitySummary")
        #expect(byID[HealthTypeCatalog.workoutIdentifier]?["kind"] as? String == "workout")
    }

    @Test func serializerMatchesJSONStringify() {
        // Exactly JSON.stringify(value, null, 2): two-space nesting, `"key": value`,
        // empty containers inline, `/` and non-ASCII unescaped, controls escaped.
        let value = CatalogVocabulary.JSON.object([
            ("a", .array([.int(1), .null])),
            ("b", .object([])),
            ("c", .array([])),
            ("d", .string("m/s \"q\" VO₂\t\u{01}")),
        ])
        let expected = """
            {
              "a": [
                1,
                null
              ],
              "b": {},
              "c": [],
              "d": "m/s \\"q\\" VO₂\\t\\u0001"
            }
            """
        #expect(CatalogVocabulary.serialize(value, indent: 0) == expected)
    }
}
