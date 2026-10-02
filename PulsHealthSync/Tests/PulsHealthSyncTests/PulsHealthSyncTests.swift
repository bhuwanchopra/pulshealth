import Compression
import Foundation
import HealthKit
import Testing
@testable import PulsHealthSync

// MARK: - Catalog

@Suite struct CatalogTests {
    @Test func identifiersAreUnique() {
        let ids = HealthTypeCatalog.all.map(\.identifier)
        #expect(Set(ids).count == ids.count)
        let defined = HealthTypeCatalog.definitions.map(\.identifier)
        #expect(Set(defined).count == defined.count)
    }

    /// `all` is exactly the definitions the running OS reaches — declarative
    /// `minimumIOS` gates, not `#available`, so the published vocabulary can
    /// list every definition.
    @Test func availableTypesAreTheDefinitionsThisOSReaches() {
        let expected = HealthTypeCatalog.definitions.filter { descriptor in
            descriptor.minimumIOS <= HealthTypeDescriptor.IOSVersion(
                ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                ProcessInfo.processInfo.operatingSystemVersion.minorVersion)
        }
        #expect(HealthTypeCatalog.all == expected)
        #expect(HealthTypeCatalog.all.count + HealthTypeCatalog.definitions.filter {
            !$0.isAvailableOnThisOS
        }.count == HealthTypeCatalog.definitions.count)
        for descriptor in HealthTypeCatalog.definitions where !descriptor.isAvailableOnThisOS {
            #expect(HealthTypeCatalog.descriptor(for: descriptor.identifier) == nil)
            #expect(descriptor.sampleType == nil)
        }
        #expect(HealthTypeCatalog.definitions.filter { $0.minimumIOS < .baseline }.isEmpty)
        if #available(iOS 27.0, *) {
            #expect(HealthTypeCatalog.all.count == HealthTypeCatalog.definitions.count)
        }
    }

    /// Gated quantity/category entries spell their identifiers as strings (the
    /// SDK constants are `@available`-restricted); pin them to the constants
    /// where the SDK has them. The special kinds' identifiers are wire-format
    /// contracts (the server hardcodes them) rather than SDK values — State of
    /// Mind's object type, for one, reports `HKDataTypeStateOfMind` at runtime.
    @Test func gatedIdentifiersMatchTheSDK() {
        if #available(iOS 18.0, *) {
            #expect(HKCategoryTypeIdentifier.sleepApneaEvent.rawValue
                == HealthTypeCatalog.sleepApneaEventIdentifier)
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            #expect(HKQuantityTypeIdentifier.heartRateVariabilityRMSSD.rawValue
                == HealthTypeCatalog.heartRateVariabilityRMSSDIdentifier)
        }
        #endif
        for descriptor in HealthTypeCatalog.definitions where descriptor.minimumIOS > .baseline {
            #expect(
                [HealthTypeCatalog.sleepApneaEventIdentifier, HealthTypeCatalog.stateOfMindIdentifier,
                 HealthTypeCatalog.medicationDoseIdentifier,
                 HealthTypeCatalog.heartRateVariabilityRMSSDIdentifier].contains(descriptor.identifier),
                "\(descriptor.identifier) is gated above iOS \(HealthTypeDescriptor.IOSVersion.baseline); pin it here")
        }
    }

    @Test func groupKeysAreStableAndUnique() {
        let keys = HealthTypeDescriptor.Group.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
        for group in HealthTypeDescriptor.Group.allCases {
            #expect(group.key == group.key.lowercased())
            let lettersOnly = group.key.allSatisfy { $0.isLetter }
            #expect(lettersOnly, "\(group.key) is not a plain word")
        }
    }

    @Test func everyTypeResolvesToASampleType() {
        // Activity summaries are the one catalog type with no HKSampleType: they
        // are an HKObjectType exported via HKActivitySummaryQuery, not a sample.
        for descriptor in HealthTypeCatalog.all
        where !HealthTypeCatalog.isActivitySummary(descriptor.identifier) {
            #expect(descriptor.sampleType != nil, "\(descriptor.identifier) has no HKSampleType")
        }
    }

    @Test func quantityTypesHaveParseableUnits() {
        for descriptor in HealthTypeCatalog.quantityTypes {
            #expect(descriptor.unit != nil, "\(descriptor.identifier) unit failed to parse")
        }
    }

    @Test func bulkReadAuthorizationExcludesPerObjectOnlyTypes() {
        let ids = Set(HealthTypeCatalog.bulkReadAuthorizationSampleTypes.map(\.identifier))
        #expect(ids.contains(HKSeriesType.workoutRoute().identifier))
        if #available(iOS 26.0, *) {
            #expect(!ids.contains(HKObjectType.medicationDoseEventType().identifier))
            #expect(HealthTypeCatalog.descriptor(
                for: HealthTypeCatalog.medicationDoseIdentifier
            )?.needsPerObjectAuthorization == true)
        }
    }

    @Test func scopedBulkAuthTypesFollowEnabledIdentifiers() {
        let withWorkout = HealthTypeCatalog.bulkReadAuthorizationSampleTypes(
            for: [HealthTypeCatalog.workoutIdentifier, "HKQuantityTypeIdentifierStepCount"])
        let ids = Set(withWorkout.map(\.identifier))
        #expect(ids.contains(HKSeriesType.workoutRoute().identifier))
        #expect(ids.contains(HKQuantityType(.stepCount).identifier))
        #expect(withWorkout.count == 3)

        let noWorkout = HealthTypeCatalog.bulkReadAuthorizationSampleTypes(
            for: ["HKQuantityTypeIdentifierStepCount", "NotARealIdentifier"])
        #expect(noWorkout.map(\.identifier) == [HKQuantityType(.stepCount).identifier])

        if #available(iOS 26.0, *) {
            #expect(HealthTypeCatalog.bulkReadAuthorizationSampleTypes(
                for: [HealthTypeCatalog.medicationDoseIdentifier]).isEmpty)
        }
    }

    @Test func workoutRoutesExcludedFromAuthWhenDisabled() {
        let types = HealthTypeCatalog.bulkReadAuthorizationSampleTypes(
            for: [HealthTypeCatalog.workoutIdentifier, "HKQuantityTypeIdentifierStepCount"],
            includeWorkoutRoutes: false
        )
        let ids = Set(types.map(\.identifier))
        #expect(!ids.contains(HKSeriesType.workoutRoute().identifier))
        #expect(ids.contains(HKWorkoutType.workoutType().identifier))
        #expect(types.count == 2)
    }

    @Test func configDecodesStateFilesWrittenBeforeRoutesToggle() throws {
        // State file persisted by a build that predates includeWorkoutRoutes.
        let legacy = #"{"enabledTypes":[],"startDate":0,"maxConcurrentTypes":4,"batchSize":1000}"#
        let config = try JSONDecoder.puls.decode(SyncConfiguration.self, from: Data(legacy.utf8))
        #expect(config.includeWorkoutRoutes == true)
        #expect(config.batchSize == 1000)

        var disabled = config
        disabled.includeWorkoutRoutes = false
        let reencoded = try JSONDecoder.puls.decode(
            SyncConfiguration.self, from: JSONEncoder.puls.encode(disabled))
        #expect(reencoded.includeWorkoutRoutes == false)
    }

    @Test func defaultConfigurationAssumesNoIdentity() {
        // The library ships with the protocol default user id only: no name,
        // email, date of birth or sex is baked in.
        let config = SyncConfiguration()
        #expect(config.userID == PulsDefaultUser.id)
        #expect(config.userName == nil)
        #expect(config.userEmail == nil)
        #expect(config.userDateOfBirth == nil)
        #expect(config.userBiologicalSex == nil)
        #expect(config.userProfilePayload == ProfilePayload())
    }

    @Test func configMigratesPreUserAndPriorUserAwareSchemas() throws {
        // Pre-user schema: no userID or profile keys. The id falls back to the
        // protocol default user (the one the server already holds the rows
        // under); the identity fields stay nil.
        let legacy = #"{"enabledTypes":[],"startDate":0,"maxConcurrentTypes":4,"batchSize":1000}"#
        let decodedLegacy = try JSONDecoder.puls.decode(
            SyncConfiguration.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.userID == PulsDefaultUser.id)
        #expect(decodedLegacy.userName == nil)
        #expect(decodedLegacy.userEmail == nil)
        #expect(decodedLegacy.userDateOfBirth == nil)
        #expect(decodedLegacy.userBiologicalSex == nil)

        // First user-aware schema: synthesized Codable omitted nil optional keys.
        // userID presence means those omissions must remain nil after migration.
        let priorUserAware = #"{"enabledTypes":[],"startDate":0,"maxConcurrentTypes":4,"batchSize":1000,"userID":"11111111-1111-4111-8111-111111111111"}"#
        let decodedPrior = try JSONDecoder.puls.decode(
            SyncConfiguration.self, from: Data(priorUserAware.utf8))
        #expect(decodedPrior.userID == "11111111-1111-4111-8111-111111111111")
        #expect(decodedPrior.userName == nil)
        #expect(decodedPrior.userEmail == nil)
        #expect(decodedPrior.userDateOfBirth == nil)
        #expect(decodedPrior.userBiologicalSex == nil)

        let priorPartial = #"{"enabledTypes":[],"startDate":0,"maxConcurrentTypes":4,"batchSize":1000,"userID":"22222222-2222-4222-8222-222222222222","userName":"Existing Name"}"#
        let decodedPartial = try JSONDecoder.puls.decode(
            SyncConfiguration.self, from: Data(priorPartial.utf8))
        #expect(decodedPartial.userName == "Existing Name")
        #expect(decodedPartial.userEmail == nil)
        #expect(decodedPartial.userDateOfBirth == nil)
        #expect(decodedPartial.userBiologicalSex == nil)

        let cleared = SyncConfiguration(
            userName: nil, userEmail: nil,
            userDateOfBirth: nil, userBiologicalSex: nil)
        let data = try JSONEncoder.puls.encode(cleared)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["userName"] is NSNull)
        #expect(json["userEmail"] is NSNull)
        #expect(json["userDateOfBirth"] is NSNull)
        #expect(json["userBiologicalSex"] is NSNull)

        let roundTrip = try JSONDecoder.puls.decode(SyncConfiguration.self, from: data)
        #expect(roundTrip.userName == nil)
        #expect(roundTrip.userEmail == nil)
        #expect(roundTrip.userDateOfBirth == nil)
        #expect(roundTrip.userBiologicalSex == nil)
    }

    @Test func medicationTypesUsePerObjectAuthorization() {
        if #available(iOS 26.0, *) {
            let ids = Set(HealthTypeCatalog.perObjectReadAuthorizationObjectTypes.map(\.identifier))
            #expect(ids.contains(HKObjectType.userAnnotatedMedicationType().identifier))
            #expect(ids.contains(HKObjectType.medicationDoseEventType().identifier))
        }
    }

    // MARK: Backfill order

    @Test func backfillOrderStartsTheHeaviestTypeThenGoesCheapestFirst() {
        let ids = [
            HKQuantityTypeIdentifier.stepCount.rawValue,          // 250/day
            HKQuantityTypeIdentifier.heartRate.rawValue,          // 3500/day — the pole
            HKQuantityTypeIdentifier.bodyMass.rawValue,           // 1/day
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, // 700/day
        ]
        let order = HealthTypeCatalog.backfillOrder(ids)
        #expect(order == [
            HKQuantityTypeIdentifier.heartRate.rawValue,
            HKQuantityTypeIdentifier.bodyMass.rawValue,
            HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
        ])
    }

    @Test func backfillOrderIsAPermutationAndIsDeterministic() {
        let ids = HealthTypeCatalog.all.map(\.identifier)
        let order = HealthTypeCatalog.backfillOrder(ids)
        #expect(Set(order) == Set(ids), "no type may be dropped or duplicated")
        #expect(order.count == ids.count)
        // Same input in a different arrangement produces the same sweep order:
        // ties and unknown identifiers fall back to identifier order, so nothing
        // depends on how the caller happened to build its array.
        #expect(HealthTypeCatalog.backfillOrder(ids.reversed()) == order)
        #expect(HealthTypeCatalog.backfillOrder(ids.shuffled()) == order)
    }

    @Test func backfillOrderHandlesEmptySingletonAndUnknownIdentifiers() {
        #expect(HealthTypeCatalog.backfillOrder([]).isEmpty)
        let one = [HKQuantityTypeIdentifier.heartRate.rawValue]
        #expect(HealthTypeCatalog.backfillOrder(one) == one)
        // An identifier with no descriptor on this OS costs 0 — it sorts with
        // the cheap tail rather than being dropped or crashing the sweep.
        let mixed = HealthTypeCatalog.backfillOrder(
            ["zz.not.a.real.type", HKQuantityTypeIdentifier.heartRate.rawValue])
        #expect(mixed == [HKQuantityTypeIdentifier.heartRate.rawValue, "zz.not.a.real.type"])
    }
}

// MARK: - Serialization

@Suite struct SerializationTests {
    func makeSample(_ i: Int) -> SyncSample {
        SyncSample(
            uuid: UUID(), type: "HKQuantityTypeIdentifierHeartRate", kind: .quantity,
            start: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
            end: Date(timeIntervalSince1970: 1_700_000_005 + Double(i)),
            value: 62.5 + Double(i), unit: "count/min",
            sourceName: "Apple Watch", sourceBundleID: "com.apple.health",
            metadata: ["HKMetadataKeyHeartRateMotionContext": .number(1)]
        )
    }

    @Test func ndjsonHasHeaderAndOneLinePerRecord() throws {
        let batch = SyncBatch(
            deviceID: "test-device", type: "HKQuantityTypeIdentifierHeartRate",
            reason: .backfill,
            samples: (0..<10).map(makeSample),
            deletions: [SyncDeletion(uuid: UUID(), type: "HKQuantityTypeIdentifierHeartRate")]
        )
        let data = try BatchSerializer.ndjson(for: batch, clientVersion: "1.2.3 (45)")
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1 + 10 + 1)

        let header = try JSONDecoder.puls.decode(
            BatchSerializer.Header.self, from: Data(lines[0].utf8))
        #expect(header.schemaVersion == PulsProtocol.version)
        #expect(header.clientVersion == "1.2.3 (45)")
        #expect(header.sampleCount == 10)
        #expect(header.deletionCount == 1)
        #expect(header.type == "HKQuantityTypeIdentifierHeartRate")
        // The raw line is what a receiver sees: an integer, not a string.
        let headerJSON = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        #expect(headerJSON["schemaVersion"] as? Int == 1)
        #expect(headerJSON["clientVersion"] as? String == "1.2.3 (45)")

        let first = try JSONDecoder.puls.decode(SyncSample.self, from: Data(lines[1].utf8))
        #expect(first == batch.samples[0])
    }

    @Test func gzipOutputHasValidFraming() throws {
        let payload = try BatchSerializer.ndjson(for: SyncBatch(
            deviceID: "d", type: "t", reason: .manual,
            samples: (0..<100).map(makeSample), deletions: []
        ))
        let gz = BatchSerializer.gzip(payload)
        #expect(gz[0] == 0x1F && gz[1] == 0x8B && gz[2] == 0x08)
        #expect(gz.count < payload.count / 3, "expected ≥3x compression on repetitive JSON")
        // ISIZE trailer = uncompressed length mod 2^32.
        let isize = gz.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(isize == UInt32(payload.count))
    }

    /// Inflates a raw DEFLATE stream. compression_decode_buffer with
    /// COMPRESSION_ZLIB is the exact counterpart of the encoder gzip() uses, so
    /// this proves the bytes between the gzip header and trailer really are a
    /// DEFLATE stream — which a length check never did.
    private func inflate(_ deflated: Data, expecting size: Int) -> Data? {
        guard !deflated.isEmpty else { return nil }
        let capacity = max(64, size * 2 + 64)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            deflated.withUnsafeBytes { src -> Int in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                return compression_decode_buffer(
                    d.assumingMemoryBound(to: UInt8.self), capacity,
                    s.assumingMemoryBound(to: UInt8.self), deflated.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    /// Strips gzip framing and returns (deflate stream, CRC32, ISIZE).
    private func unframe(_ gz: Data) -> (deflate: Data, crc: UInt32, size: UInt32)? {
        guard gz.count >= 18, gz[gz.startIndex] == 0x1F, gz[gz.startIndex + 1] == 0x8B else {
            return nil
        }
        let body = gz.dropFirst(10).dropLast(8)
        let trailer = Array(gz.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8
            | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8
            | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        return (Data(body), crc, size)
    }

    @Test func gzipProducesADecodableDeflateStream() throws {
        let payload = Data("hello puls health sync — \(UUID())".utf8)
        let gz = BatchSerializer.gzip(payload)

        let framed = try #require(unframe(gz))
        let inflated = try #require(inflate(framed.deflate, expecting: payload.count))
        #expect(inflated == payload)
        #expect(framed.size == UInt32(payload.count))
    }

    /// The fallback taken when compression_encode_buffer declines — it returns 0
    /// both on failure and when the compressed form would not fit, which happens
    /// on incompressible input. It used to return the RAW bytes, which gzip()
    /// then framed as though they were DEFLATE: a body advertised as gzip that
    /// no reader can decode, answered 400, never retried, page stalled forever.
    @Test func storedDeflateFallbackIsValidDeflate() throws {
        let cases: [Data] = [
            Data(),
            Data("x".utf8),
            Data("hello puls health sync".utf8),
            // Larger than one 65,535-byte stored block, so this covers the
            // multi-block path and the BFINAL bit only being set on the last.
            Data((0..<70_000).map { UInt8($0 % 251) }),
        ]
        for payload in cases {
            let stored = BatchSerializer.storedDeflate(payload)
            let inflated = inflate(stored, expecting: payload.count) ?? Data()
            #expect(inflated == payload, "stored block did not round-trip at \(payload.count) bytes")
        }
    }

    /// Whatever path gzip() takes internally, the framing must describe the
    /// payload: same uncompressed size, and a stream that inflates back to it.
    @Test func gzipFramingSurvivesIncompressibleInput() throws {
        // Random bytes: the case where the encoder is most likely to decline.
        var payload = Data(count: 4096)
        payload.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8.random(in: 0...255) }
        }
        let gz = BatchSerializer.gzip(payload)
        let framed = try #require(unframe(gz))
        #expect(framed.size == UInt32(payload.count))
        let inflated = try #require(inflate(framed.deflate, expecting: payload.count))
        #expect(inflated == payload)
    }

    @Test func metadataValueRoundTrips() throws {
        let values: [String: MetadataValue] = [
            "s": .string("x"), "n": .number(1.5), "b": .bool(true),
        ]
        let data = try JSONEncoder.puls.encode(values)
        let decoded = try JSONDecoder.puls.decode([String: MetadataValue].self, from: data)
        #expect(decoded["s"] == .string("x"))
        #expect(decoded["n"] == .number(1.5))
        // Bool decodes as bool, not number.
        #expect(decoded["b"] == .bool(true))
    }

    @Test func metadataMappingKeepsIntegerZeroAndOneAsNumbers() throws {
        // HealthKit hands metadata over as NSNumbers. Swift bridges any NSNumber
        // holding 0 or 1 to Bool, so an `as Bool` cast first turned integer keys
        // such as HKMetadataKeyHeartRateMotionContext (0/1/2) into true/false/2.
        let raw: [String: Any] = [
            "int0": NSNumber(value: 0),
            "int1": NSNumber(value: 1),
            "int2": NSNumber(value: 2),
            "double1": NSNumber(value: 1.0),
            "objcTrue": NSNumber(value: true),
            "swiftFalse": false,
            "swiftInt": 1,
            "swiftDouble": 0.5,
            "string": "x",
        ]
        let mapped = try #require(SampleMapper.mapMetadata(raw))
        #expect(mapped["int0"] == .number(0))
        #expect(mapped["int1"] == .number(1))
        #expect(mapped["int2"] == .number(2))
        #expect(mapped["double1"] == .number(1))
        #expect(mapped["objcTrue"] == .bool(true))
        #expect(mapped["swiftFalse"] == .bool(false))
        #expect(mapped["swiftInt"] == .number(1))
        #expect(mapped["swiftDouble"] == .number(0.5))
        #expect(mapped["string"] == .string("x"))
        #expect(SampleMapper.mapMetadata(nil) == nil)
        #expect(SampleMapper.mapMetadata([:]) == nil)
    }

    @Test func profileEncodesAllReplacementKeysIncludingNulls() throws {
        let empty = try JSONSerialization.jsonObject(
            with: JSONEncoder.puls.encode(ProfilePayload())) as! [String: Any]
        #expect(Set(empty.keys) == ["name", "email", "dateOfBirth", "biologicalSex"])
        #expect(empty.values.allSatisfy { $0 is NSNull })

        let partial = try JSONSerialization.jsonObject(
            with: JSONEncoder.puls.encode(ProfilePayload(
                name: "Updated", email: nil,
                dateOfBirth: Date(timeIntervalSince1970: 631_152_000),
                biologicalSex: nil
            ))) as! [String: Any]
        #expect(partial["name"] as? String == "Updated")
        #expect(partial["email"] is NSNull)
        #expect(partial["dateOfBirth"] as? Double == 631_152_000_000)
        #expect(partial["biologicalSex"] is NSNull)
    }
}

// MARK: - State store

@Suite struct ProfileDateOfBirthTests {
    @Test func dateOfBirthIsSentAtLocalNoonSoTheUTCDayMatches() throws {
        // Local midnight of the birthday in any zone.
        var c = DateComponents(year: 1992, month: 9, day: 17)
        c.calendar = Calendar.current
        let midnight = try #require(c.date)
        let wire = SyncConfiguration.wireDateOfBirth(midnight)
        let local = Calendar.current.dateComponents([.year, .month, .day, .hour], from: wire)
        #expect((local.year, local.month, local.day, local.hour) == (1992, 9, 17, 12))
        // The UTC calendar day the server will store equals the local one for
        // every zone between UTC−12 and UTC+11 — which local midnight did not
        // satisfy east of UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let stored = utc.dateComponents([.year, .month, .day], from: wire)
        let offsetHours = TimeZone.current.secondsFromGMT(for: wire) / 3600
        if (-12...11).contains(offsetHours) {
            #expect((stored.year, stored.month, stored.day) == (1992, 9, 17))
        }
        let config = SyncConfiguration(userDateOfBirth: midnight)
        #expect(config.userProfilePayload.dateOfBirth == wire)
        #expect(SyncConfiguration(userDateOfBirth: nil).userProfilePayload.dateOfBirth == nil)
    }
}

/// A profile line replaces the server's copy, so sending an empty one erases
/// it. That must happen when the user empties the fields, and never merely
/// because an install has none — the reinstall case.
@Suite struct ProfileUploadPolicyTests {
    let filled = ProfilePayload(name: "A", email: nil, dateOfBirth: Date(timeIntervalSince1970: 0), biologicalSex: "female")

    @Test func aFreshInstallWithNoProfileSendsNothing() {
        #expect(!ProfilePayload.shouldUpload(ProfilePayload(), replacing: ProfilePayload()))
    }

    @Test func aFilledProfileIsAlwaysSent() {
        #expect(ProfilePayload.shouldUpload(filled, replacing: ProfilePayload()))
        #expect(ProfilePayload.shouldUpload(filled, replacing: filled))
    }

    @Test func emptyingTheFieldsStillClearsTheServer() {
        #expect(ProfilePayload.shouldUpload(ProfilePayload(), replacing: filled))
        #expect(ProfilePayload.shouldUpload(ProfilePayload(), replacing: ProfilePayload(biologicalSex: "male")))
    }

    /// The Apply after a clear that failed to upload finds an empty profile
    /// already stored; the pending flag is what keeps the clear from being
    /// dropped for good.
    @Test func aClearThatNeverArrivedIsRetried() {
        #expect(ProfilePayload.shouldUpload(ProfilePayload(), replacing: ProfilePayload(), clearPending: true))
        #expect(!ProfilePayload.shouldUpload(ProfilePayload(), replacing: ProfilePayload(), clearPending: false))
    }
}

@Suite struct StateStoreTests {
    func makeStore() -> SyncStateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        return SyncStateStore(directory: dir)
    }

    @Test func undecodableStateFileIsQuarantinedNotOverwritten() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sync-state.json")
        let garbage = Data("{\"configuration\": [not json".utf8)
        try garbage.write(to: file)

        let store = SyncStateStore(directory: dir)
        // Fresh defaults, not a crash.
        let configuration = await store.configuration
        let typeStates = await store.typeStates
        #expect(configuration.enabledTypes.isEmpty)
        #expect(typeStates.isEmpty)

        // The broken file was moved aside, byte-for-byte, before anything could
        // persist over it — it is the only copy of every anchor.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let quarantined = try #require(names.first { $0.hasPrefix("sync-state.json.corrupt-") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(quarantined)) == garbage)

        await store.persistNow()
        let rewritten = try Data(contentsOf: file)
        #expect(rewritten != garbage)
        #expect(try Data(contentsOf: dir.appendingPathComponent(quarantined)) == garbage)
    }

    @Test func recordsBatchesAndAdvancesCounters() async {
        let store = makeStore()
        let anchor = Data([1, 2, 3])
        let range = Date(timeIntervalSince1970: 1_000)...Date(timeIntervalSince1970: 2_000)
        await store.recordUploadedBatch(
            identifier: "type-a", newAnchorData: anchor, samples: 100, deletions: 2,
            bytes: 4_096, sampleDateRange: range, duration: 1.25, latency: 9.5
        )
        let state = await store.state(for: "type-a")
        #expect(state.anchorData == anchor)
        #expect(state.totalSamplesExported == 100)
        #expect(state.totalDeletionsExported == 2)
        #expect(state.totalBytesUploaded == 4_096)
        #expect(state.totalBatchesUploaded == 1)
        #expect(state.lastObservedLatency == 9.5)
        #expect(state.earliestExported == range.lowerBound)
        #expect(state.latestExported == range.upperBound)
        #expect(state.lastError == nil)
    }

    @Test func persistsAcrossInstances() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        let store = SyncStateStore(directory: dir)
        var config = await store.configuration
        config.enabledTypes = ["type-a"]
        config.batchSize = 1_234
        await store.setConfiguration(config)
        await store.recordUploadedBatch(
            identifier: "type-a", newAnchorData: Data([9]), samples: 5, deletions: 0,
            bytes: 100, sampleDateRange: nil, duration: 0.1, latency: nil
        )
        await store.persistNow()
        let deviceID = await store.deviceID

        let reloaded = SyncStateStore(directory: dir)
        let state = await reloaded.state(for: "type-a")
        let reloadedConfig = await reloaded.configuration
        #expect(state.totalSamplesExported == 5)
        #expect(state.anchorData == Data([9]))
        #expect(reloadedConfig.batchSize == 1_234)
        #expect(await reloaded.deviceID == deviceID)
    }

    @Test func deliberatelyClearedProfileFieldsPersistAcrossInstances() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        let store = SyncStateStore(directory: dir)
        var config = await store.configuration
        config.userName = nil
        config.userEmail = nil
        config.userDateOfBirth = nil
        config.userBiologicalSex = nil
        await store.setConfiguration(config)
        await store.persistNow()

        let reloaded = await SyncStateStore(directory: dir).configuration
        #expect(reloaded.userName == nil)
        #expect(reloaded.userEmail == nil)
        #expect(reloaded.userDateOfBirth == nil)
        #expect(reloaded.userBiologicalSex == nil)
    }

    @Test func errorsAreRecordedAndClearedOnSuccess() async {
        let store = makeStore()
        struct Boom: Error {}
        await store.recordError(identifier: "type-a", error: Boom())
        var state = await store.state(for: "type-a")
        #expect(state.lastError != nil)

        await store.recordUploadedBatch(
            identifier: "type-a", newAnchorData: nil, samples: 1, deletions: 0,
            bytes: 10, sampleDateRange: nil, duration: 0.1, latency: nil
        )
        state = await store.state(for: "type-a")
        #expect(state.lastError == nil)
    }

    @Test func resetDropsAnchor() async {
        let store = makeStore()
        await store.recordUploadedBatch(
            identifier: "type-a", newAnchorData: Data([1]), samples: 1, deletions: 0,
            bytes: 1, sampleDateRange: nil, duration: 0, latency: nil
        )
        await store.resetType("type-a")
        let state = await store.state(for: "type-a")
        #expect(state.anchorData == nil)
        #expect(state.totalSamplesExported == 0)
    }
}

// MARK: - Event log

@Suite struct EventLogTests {
    @Test func capsAtCapacity() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        let log = SyncEventLog(directory: dir)
        for i in 0..<(SyncEventLog.capacity + 50) {
            await log.log(.debug, "event \(i)")
        }
        let recent = await log.recent(limit: .max)
        #expect(recent.count == SyncEventLog.capacity)
        #expect(recent.last?.message == "event \(SyncEventLog.capacity + 49)")
    }

    @Test func streamDeliversNewEvents() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        let log = SyncEventLog(directory: dir)
        let stream = await log.stream()
        await log.log(.info, type: "t", "hello")
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.message == "hello")
        #expect(event?.type == "t")
    }
}

// MARK: - Transport plumbing

@Suite struct TransportTests {
    @Test func dryRunReportsCompressedBytes() async throws {
        let transport = DryRunTransport()
        let batch = SyncBatch(
            deviceID: "d", type: "t", reason: .backfill,
            samples: (0..<500).map { i in
                SyncSample(
                    uuid: UUID(), type: "t", kind: .quantity,
                    start: Date(timeIntervalSince1970: Double(i)),
                    end: Date(timeIntervalSince1970: Double(i) + 1),
                    value: Double(i), unit: "count"
                )
            },
            deletions: []
        )
        let result = try await transport.upload(batch)
        #expect(result.bytesSent > 0)
        let raw = try BatchSerializer.ndjson(for: batch)
        #expect(result.bytesSent < raw.count / 2)
    }

    @Test func serverErrorsAreClassifiedForRetry() {
        #expect(TransportError.serverError(status: 500, body: "").isRetryable)
        #expect(TransportError.serverError(status: 429, body: "").isRetryable)
        #expect(!TransportError.serverError(status: 400, body: "").isRetryable)
        #expect(!TransportError.serverError(status: 401, body: "").isRetryable)
        #expect(TransportError.network(URLError(.timedOut)).isRetryable)
        #expect(!TransportError.notConfigured.isRetryable)
        #expect(!TransportError.unsupportedProtocol(supportedVersions: [2]).isRetryable)
    }

    @Test func readRequestsCarryConfiguredUserID() {
        let userID = UUID().uuidString
        let client = ServerAPIClient(
            baseURL: URL(string: "https://example.test")!,
            authToken: "secret",
            userID: userID
        )
        let request = client.makeRequest(path: "v1/uuids", query: ["type": "steps"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "X-User-ID") == userID)
        #expect(request.value(forHTTPHeaderField: "X-Puls-Protocol") == "1")
        #expect(request.url?.absoluteString == "https://example.test/v1/uuids?type=steps")
    }
}

// MARK: - Background scheduling

#if canImport(BackgroundTasks) && !os(macOS)
@Suite struct BackgroundSchedulerIdentifierTests {
    @Test func continuedBackfillRegistersConcreteIdentifierMatchedByPermittedWildcard() {
        let bundleID = BackgroundSyncScheduler.fallbackBundleIdentifier
        #expect(bundleID == "com.pulsHealth.PulsHealth")

        #expect(BackgroundSyncScheduler.continuedBackfillPermittedIdentifier(
            bundleIdentifier: bundleID
        ) == "com.pulsHealth.PulsHealth.backfill.*")
        #expect(BackgroundSyncScheduler.continuedBackfillRegistrationIdentifier(
            bundleIdentifier: bundleID
        ) == "com.pulsHealth.PulsHealth.backfill.run")
    }

    @Test func catchupIdentifierDerivesFromBundleIdentifier() {
        // Info.plist lists `$(PRODUCT_BUNDLE_IDENTIFIER).healthsync.catchup`;
        // the scheduler must derive the same string from the same bundle ID.
        #expect(BackgroundSyncScheduler.catchupTaskIdentifier(
            bundleIdentifier: "com.pulsHealth.PulsHealth")
            == "com.pulsHealth.PulsHealth.healthsync.catchup")
        #expect(BackgroundSyncScheduler.catchupTaskIdentifier(
            bundleIdentifier: "org.example.Fork") == "org.example.Fork.healthsync.catchup")
        // No main bundle (tests, tools): the historical literal, frozen at the
        // string pre-derivation builds hardcoded. It does not follow the app's
        // bundle-ID rename, so it is spelled out rather than derived here.
        #expect(BackgroundSyncScheduler.catchupTaskIdentifier(bundleIdentifier: nil)
            == "com.puls.healthsync.catchup")
        #expect(BackgroundSyncScheduler.catchupTaskIdentifier(bundleIdentifier: "")
            == "com.puls.healthsync.catchup")
    }

    @Test func schedulerUsesInjectedIdentifiers() {
        let scheduler = BackgroundSyncScheduler(
            engine: HealthSyncEngine(),
            catchupTaskIdentifier: "org.example.Fork.healthsync.catchup",
            backfillTaskIdentifier: "org.example.Fork.backfill.run")
        #expect(scheduler.catchupTaskIdentifier == "org.example.Fork.healthsync.catchup")
        #expect(scheduler.backfillTaskIdentifier == "org.example.Fork.backfill.run")
    }

    @Test func taskCompletionGateHasExactlyOneWinner() async {
        let gate = BackgroundTaskCompletionGate()
        let outcomes = await withTaskGroup(
            of: (Bool, Bool).self, returning: [(Bool, Bool)].self
        ) { group in
            for _ in 0..<100 {
                group.addTask {
                    var completedSynchronously = false
                    let claimed = gate.claim(performing: {
                        completedSynchronously = true
                    })
                    return (claimed, completedSynchronously)
                }
            }
            var results: [(Bool, Bool)] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(outcomes.count { $0.0 } == 1)
        #expect(outcomes.count { $0.1 } == 1)
        #expect(outcomes.allSatisfy { $0.0 == $0.1 })
    }

    @Test func expirationCanWinWhileNormalCompletionIsSuspended() async {
        let gate = BackgroundTaskCompletionGate()
        let normalCompletion = Task {
            try? await Task.sleep(for: .milliseconds(20))
            return gate.claim(performing: {})
        }

        // Models expiration firing while the normal path is still awaiting its
        // required persistence. The late normal completion tail must be a no-op.
        let expirationWon = gate.claim(performing: {})
        let normalWon = await normalCompletion.value
        #expect(expirationWon)
        #expect(!normalWon)
    }

    @Test func claimedGateRejectsLateProgressMutation() {
        let gate = BackgroundTaskCompletionGate()
        var updates = 0
        let beforeClaim = gate.performIfUnclaimed { updates += 1 }
        #expect(beforeClaim)
        #expect(updates == 1)

        #expect(gate.claim(performing: {}))
        let afterClaim = gate.performIfUnclaimed { updates += 1 }
        #expect(!afterClaim)
        #expect(updates == 1)
    }
}
#endif

// MARK: - Series & special types

@Suite struct SeriesWireFormatTests {
    @Test func specialTypesAreInCatalog() {
        #expect(HealthTypeCatalog.descriptor(
            for: HealthTypeCatalog.heartbeatSeriesIdentifier)?.kind == .heartbeatSeries)
        #expect(HealthTypeCatalog.descriptor(
            for: HealthTypeCatalog.electrocardiogramIdentifier)?.kind == .ecg)
        if #available(iOS 18.0, *) {
            #expect(HealthTypeCatalog.descriptor(
                for: HealthTypeCatalog.stateOfMindIdentifier)?.kind == .stateOfMind)
            // Effort scores must stay out of the catalog — iOS won't show them in
            // the authorization sheet, which wedges the whole request (see catalog).
            #expect(HealthTypeCatalog.descriptor(
                for: "HKQuantityTypeIdentifierWorkoutEffortScore") == nil)
            #expect(HealthTypeCatalog.descriptor(
                for: "HKCategoryTypeIdentifierSleepApneaEvent") != nil)
        }
        if #available(iOS 26.0, *) {
            #expect(HealthTypeCatalog.descriptor(
                for: HealthTypeCatalog.medicationDoseIdentifier)?.kind == .medicationDose)
        }
    }

    @Test func heartbeatEncodesAsPairArray() throws {
        let sample = SyncSample(
            uuid: UUID(), type: HealthTypeCatalog.heartbeatSeriesIdentifier,
            kind: .heartbeatSeries,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_060),
            heartbeats: [
                Heartbeat(timeSinceSeriesStart: 0.5, precededByGap: false),
                Heartbeat(timeSinceSeriesStart: 1.25, precededByGap: true),
            ]
        )
        let data = try JSONEncoder.puls.encode(sample)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let beats = json["heartbeats"] as! [[Any]]
        #expect(beats.count == 2)
        #expect(beats[0][0] as! Double == 0.5)
        #expect(beats[0][1] as! Bool == false)
        #expect(beats[1][1] as! Bool == true)
        let decoded = try JSONDecoder.puls.decode(SyncSample.self, from: data)
        #expect(decoded.heartbeats == sample.heartbeats)
    }

    @Test func ndjsonAppendsRouteLinesAndCountsThem() throws {
        let workoutUUID = UUID()
        let points = (0..<5).map {
            RoutePoint(
                t: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)),
                lat: 37.33 + Double($0) * 0.0001, lon: -122.01,
                alt: 12.5, hAcc: 3.1, speed: 2.4, course: 270
            )
        }
        let batch = SyncBatch(
            deviceID: "d", type: HealthTypeCatalog.workoutIdentifier, reason: .backfill,
            samples: [], deletions: [],
            routes: [RoutePayload(workoutUUID: workoutUUID, points: points)]
        )
        let data = try BatchSerializer.ndjson(for: batch)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)

        let header = try JSONDecoder.puls.decode(
            BatchSerializer.Header.self, from: Data(lines[0].utf8))
        #expect(header.routeCount == 1)
        #expect(header.sampleCount == 0)

        let routeJSON = try JSONSerialization.jsonObject(
            with: Data(lines[1].utf8)) as! [String: Any]
        let route = routeJSON["route"] as! [String: Any]
        #expect(route["workoutUUID"] as! String == workoutUUID.uuidString)
        let wirePoints = route["points"] as! [[String: Any]]
        #expect(wirePoints.count == 5)
        #expect(wirePoints[0]["t"] as! Double == 1_700_000_000_000)
        #expect(wirePoints[0]["lat"] as! Double == 37.33)
    }

    @Test func ecgAndStateOfMindDetailsRoundTrip() throws {
        let ecg = ECGDetail(
            classification: "sinusRhythm", averageHeartRateBpm: 61,
            samplingFrequencyHz: 512.0, symptomsStatus: "none",
            voltagesUV: [1.5, -2.25, 3.0]
        )
        let som = StateOfMindDetail(
            kind: "momentaryEmotion", valence: 0.35, valenceClassification: "slightlyPleasant",
            labels: ["calm", "grateful"], associations: ["family"]
        )
        let dose = MedicationDoseDetail(
            medication: "Ibuprofen", status: "taken",
            scheduledAt: Date(timeIntervalSince1970: 1_700_000_000),
            doseQuantity: 2, doseUnit: "count"
        )
        #expect(try JSONDecoder.puls.decode(
            ECGDetail.self, from: JSONEncoder.puls.encode(ecg)) == ecg)
        #expect(try JSONDecoder.puls.decode(
            StateOfMindDetail.self, from: JSONEncoder.puls.encode(som)) == som)
        #expect(try JSONDecoder.puls.decode(
            MedicationDoseDetail.self, from: JSONEncoder.puls.encode(dose)) == dose)
    }

    @Test func enrichedWorkoutDetailRoundTrips() throws {
        let detail = WorkoutDetail(
            activityType: "running", duration: 3600,
            totalEnergyKcal: 450, totalDistanceMeters: 8046,
            statistics: ["HKQuantityTypeIdentifierHeartRate": 152],
            statisticsDetail: [
                "HKQuantityTypeIdentifierHeartRate": WorkoutStat(min: 98, avg: 152, max: 178),
                "HKQuantityTypeIdentifierActiveEnergyBurned": WorkoutStat(sum: 450),
            ],
            events: [
                WorkoutEvent(type: "lap", start: Date(timeIntervalSince1970: 1_700_000_900)),
                WorkoutEvent(
                    type: "segment",
                    start: Date(timeIntervalSince1970: 1_700_000_000),
                    end: Date(timeIntervalSince1970: 1_700_000_900)),
            ],
            activities: [
                WorkoutActivitySegment(
                    activityType: "running",
                    start: Date(timeIntervalSince1970: 1_700_000_000),
                    end: Date(timeIntervalSince1970: 1_700_003_600), duration: 3600,
                    statistics: ["HKQuantityTypeIdentifierHeartRate": WorkoutStat(avg: 152, max: 178)]),
            ]
        )
        #expect(try JSONDecoder.puls.decode(
            WorkoutDetail.self, from: JSONEncoder.puls.encode(detail)) == detail)
    }

    @Test func ndjsonAppendsSeriesAndProfileLinesAndCountsThem() throws {
        let workoutUUID = UUID()
        let series = WorkoutSeriesPayload(
            workoutUUID: workoutUUID, type: "HKQuantityTypeIdentifierHeartRate", unit: "count/min",
            points: [
                SeriesPoint(t: Date(timeIntervalSince1970: 1_700_000_001), value: 120),
                SeriesPoint(t: Date(timeIntervalSince1970: 1_700_000_002), value: 135.5),
            ])
        let profile = ProfilePayload(
            dateOfBirth: Date(timeIntervalSince1970: 631_152_000), biologicalSex: "male")
        let batch = SyncBatch(
            deviceID: "d", type: HealthTypeCatalog.workoutIdentifier, reason: .backfill,
            samples: [], deletions: [], routes: [], series: [series], profile: profile)
        let data = try BatchSerializer.ndjson(for: batch)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3) // header + series + profile

        let header = try JSONDecoder.puls.decode(
            BatchSerializer.Header.self, from: Data(lines[0].utf8))
        #expect(header.seriesCount == 1)
        #expect(header.profileCount == 1)

        let seriesJSON = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        let s = seriesJSON["series"] as! [String: Any]
        #expect(s["type"] as! String == "HKQuantityTypeIdentifierHeartRate")
        let pts = s["points"] as! [[String: Any]]
        #expect(pts.count == 2)
        #expect(pts[0]["t"] as! Double == 1_700_000_001_000)
        #expect(pts[1]["value"] as! Double == 135.5)

        let profileJSON = try JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as! [String: Any]
        let p = profileJSON["profile"] as! [String: Any]
        #expect(p["biologicalSex"] as! String == "male")
    }

    @Test func headerWithoutNewCountsDefaultsToZero() throws {
        // A header written before series/profile existed must still decode.
        let legacy = #"{"batchID":"6f1c1f1e-2a3b-4c5d-8e9f-0a1b2c3d4e5f","deviceID":"d","type":"t","reason":"incremental","exportedAt":1700000000000,"sampleCount":0,"deletionCount":0,"routeCount":0}"#
        let header = try JSONDecoder.puls.decode(BatchSerializer.Header.self, from: Data(legacy.utf8))
        #expect(header.seriesCount == 0)
        #expect(header.profileCount == 0)
        // Pre-versioning headers: schema 0, unknown client.
        #expect(header.schemaVersion == 0)
        #expect(header.clientVersion == "unknown")
    }
}

// MARK: - Reconciliation

@Suite struct ReconciliationTests {
    @Test func digestIsOrderIndependentXOR() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
        let b = UUID(uuidString: "10000000-0000-0000-0000-00000000000F")!
        #expect(ReconcileDigest.hexDigest(of: [a, b]) == ReconcileDigest.hexDigest(of: [b, a]))
        #expect(ReconcileDigest.hexDigest(of: [a, b]) == "100000000000000000000000000000f0")
        // Self-cancelling: x ^ x = 0.
        #expect(ReconcileDigest.hexDigest(of: [a, a]) == String(repeating: "0", count: 32))
        #expect(ReconcileDigest.hexDigest(of: [UUID]()) == String(repeating: "0", count: 32))
    }

    @Test func monthWindowsCoverRangeInUTC() {
        let from = Date(timeIntervalSince1970: 1_705_276_800) // 2024-01-15 UTC
        let to = Date(timeIntervalSince1970: 1_711_929_600)   // 2024-04-01 UTC
        let windows = ReconcileDigest.monthWindows(from: from, to: to)
        #expect(windows.count == 3) // Jan partial, Feb, Mar; no empty Apr window
        #expect(windows[0].monthStart == Date(timeIntervalSince1970: 1_704_067_200)) // Jan 1
        #expect(windows[0].start == from)
        #expect(windows[0].end == Date(timeIntervalSince1970: 1_706_745_600))   // 2024-02-01
        #expect(windows[1].start == windows[0].end)
        #expect(windows[2].end == to)
        #expect(windows.allSatisfy { $0.start >= from && $0.end <= to && $0.start < $0.end })
        #expect(ReconcileDigest.monthWindows(from: from, to: from).isEmpty)
        #expect(ReconcileDigest.monthWindows(from: to, to: from).isEmpty)
    }

    @Test func sameMonthWindowKeepsMonthDigestKeyButClampsBothBounds() {
        let from = Date(timeIntervalSince1970: 1_705_276_800) // 2024-01-15 UTC
        let to = from.addingTimeInterval(3 * 86_400)
        let window = ReconcileDigest.monthWindows(from: from, to: to)
        #expect(window == [ReconcileDigest.MonthWindow(
            monthStart: Date(timeIntervalSince1970: 1_704_067_200),
            start: from,
            end: to
        )])
    }

    @Test func reportSummaryReadsSensibly() {
        var report = ReconciliationReport(type: "t")
        report.windowsChecked = 12
        #expect(report.summary == "12 windows in sync")
        report.windowsMismatched = 2
        report.samplesReuploaded = 31
        report.orphanDeletionsSent = 4
        #expect(report.summary == "2/12 windows repaired: +31 samples, -4 orphans")
    }

    // A type whose Health read access is off — None in Settings, or never
    // granted — answers every sample query with nothing and no error, and
    // `HKHealthStore.authorizationStatus(for:)` reports only write access.
    // So a month the device returns nothing for is indistinguishable from a
    // denied type, and its server rows must not be deleted on that evidence.

    @Test func anEmptyDeviceMonthKeepsItsServerRows() {
        #expect(ReconcileDigest.orphanVerdict(localCount: 0, serverRows: 120, readAccessConfirmed: false) == .withhold)
        #expect(ReconcileDigest.orphanVerdict(localCount: 0, serverRows: 1, readAccessConfirmed: false) == .withhold)
    }

    @Test func aMonthTheDeviceHasSamplesForStillDeletesItsOrphans() {
        // The device can read the type: whatever it lacks is gone from Health.
        #expect(ReconcileDigest.orphanVerdict(localCount: 1, serverRows: 120, readAccessConfirmed: false) == .delete)
        #expect(ReconcileDigest.orphanVerdict(localCount: 119, serverRows: 120, readAccessConfirmed: false) == .delete)
    }

    @Test func nothingOnEitherSideHasNothingToWithhold() {
        #expect(ReconcileDigest.orphanVerdict(localCount: 0, serverRows: 0, readAccessConfirmed: false) == .delete)
    }

    @Test func aConfirmedReadableRangeProvesAnEmptyMonthIsEmpty() {
        // iOS 27 listed the type with an earliest readable date, which a type
        // set to None never is: from that date on, empty is the truth.
        #expect(ReconcileDigest.orphanVerdict(localCount: 0, serverRows: 120, readAccessConfirmed: true) == .delete)
    }

    @Test func aRunThatReadNothingAnywhereLooksUnreadable() {
        #expect(ReconcileDigest.looksUnreadable(localTotal: 0, serverTotal: 4_000, readAccessConfirmed: false))
        // One sample anywhere in the range proves the type is readable.
        #expect(!ReconcileDigest.looksUnreadable(localTotal: 1, serverTotal: 4_000, readAccessConfirmed: false))
        // Nothing on the server either: an empty type, not a denied one.
        #expect(!ReconcileDigest.looksUnreadable(localTotal: 0, serverTotal: 0, readAccessConfirmed: false))
        // A confirmed limit vouches for the empty answer.
        #expect(!ReconcileDigest.looksUnreadable(localTotal: 0, serverTotal: 4_000, readAccessConfirmed: true))
    }

    @Test func readAccessIsConfirmedOnlyByAFreshListing() {
        // The default: nothing vouched for the type.
        #expect(!ReadableLimit(since: nil, isFresh: true).isConfirmed)
        // What `readableLimit(for:recorded:)` builds when HealthKit cannot be
        // asked: the recorded date stands in, and proves nothing.
        #expect(!ReadableLimit(since: Date(), isFresh: false).isConfirmed)
        #expect(ReadableLimit(since: Date(), isFresh: true, isConfirmed: true).isConfirmed)
    }

    @Test func reportSummaryNamesTheMonthsLeftAlone() {
        var report = ReconciliationReport(type: "t")
        report.windowsChecked = 12
        report.windowsUnverified = 1
        report.orphanDeletionsWithheld = 120
        #expect(report.summary == "12 windows in sync; 1 window left alone: Health returned nothing where the database has 120 rows")
        report.windowsMismatched = 1
        report.samplesReuploaded = 3
        report.windowsUnverified = 2
        report.orphanDeletionsWithheld = 250
        #expect(report.summary == "1/12 windows repaired: +3 samples, -0 orphans; 2 windows left alone: Health returned nothing where the database has 250 rows")
    }

    @Test func theUnreadableErrorSaysNothingWasDeleted() {
        let error = SyncError.reconciliationUnreadable("Steps", serverRows: 4_000)
        let text = error.localizedDescription
        #expect(text.contains("no Steps samples"))
        #expect(text.contains("4000"))
        #expect(text.contains("nothing was deleted"))
        #expect(text.contains("Settings"))
    }
}
