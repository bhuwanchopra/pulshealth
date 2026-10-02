import Foundation
import HealthKit

/// One syncable HealthKit type: identifier, human name, canonical unit, and grouping.
public struct HealthTypeDescriptor: Identifiable, Sendable, Hashable {
    public enum Group: String, Sendable, CaseIterable {
        case activity = "Activity"
        case heart = "Heart"
        case body = "Body"
        case respiratory = "Respiratory"
        case sleep = "Sleep"
        case nutrition = "Nutrition"
        case vitals = "Vitals"
        case workouts = "Workouts"
        case other = "Other"

        /// Stable machine key (`activity`, `heart`, …): the value published in
        /// `docs/protocol/catalog.json` and used by the web viewer. The raw
        /// value is the display label.
        public var key: String {
            switch self {
            case .activity: "activity"
            case .heart: "heart"
            case .body: "body"
            case .respiratory: "respiratory"
            case .sleep: "sleep"
            case .nutrition: "nutrition"
            case .vitals: "vitals"
            case .workouts: "workouts"
            case .other: "other"
            }
        }
    }

    /// An iOS release, compared numerically. Catalog entries carry the first
    /// release PulsHealth exports them on as data rather than as `#available`
    /// checks, so the published vocabulary (`docs/protocol/catalog.json`) can
    /// list every type with its `minimumIOS` no matter which runtime renders it.
    public struct IOSVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
        public let major: Int
        public let minor: Int

        public init(_ major: Int, _ minor: Int = 0) {
            self.major = major
            self.minor = minor
        }

        /// The package's deployment target. Every type older than this is
        /// published with it: PulsHealth cannot run on anything earlier, so a
        /// finer answer would not change what a receiver can expect.
        public static let baseline = IOSVersion(17)

        /// `"18.0"` — the form used on the wire and in the docs.
        public var description: String { "\(major).\(minor)" }

        public static func < (lhs: IOSVersion, rhs: IOSVersion) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }

        /// True when the running OS is at least this release — the runtime
        /// equivalent of `#available(iOS major.minor, *)`.
        public var isAvailableOnThisOS: Bool {
            ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
    }

    public var id: String { identifier }
    /// Raw HealthKit identifier, e.g. "HKQuantityTypeIdentifierHeartRate".
    public let identifier: String
    public let displayName: String
    public let kind: SampleKind
    /// Canonical unit string all values are converted to before upload (nil for category/workout).
    public let unitString: String?
    public let group: Group
    /// Rough expected sample density, used for backfill ETA estimates (samples per active day).
    public let estimatedSamplesPerDay: Int
    /// The first iOS release PulsHealth exports this type on: `IOSVersion.baseline`
    /// (17.0) for anything older, otherwise the release that introduced the
    /// HealthKit type. `HealthTypeCatalog.all` omits entries above the running OS.
    public let minimumIOS: IOSVersion

    /// True when the running OS exposes this type.
    public var isAvailableOnThisOS: Bool { minimumIOS.isAvailableOnThisOS }

    var sampleType: HKSampleType? {
        // A definition above the running OS has no resolvable HealthKit type;
        // constructing one would trap. `all` never contains such an entry, but
        // the guard keeps `definitions` safe to walk too.
        guard isAvailableOnThisOS else { return nil }
        switch kind {
        case .quantity: return HKQuantityType(HKQuantityTypeIdentifier(rawValue: identifier))
        case .category: return HKCategoryType(HKCategoryTypeIdentifier(rawValue: identifier))
        case .workout: return HKWorkoutType.workoutType()
        case .heartbeatSeries: return HKSeriesType.heartbeat()
        case .ecg: return HKObjectType.electrocardiogramType()
        case .stateOfMind:
            guard #available(iOS 18.0, *) else { return nil }
            return HKObjectType.stateOfMindType()
        case .medicationDose:
            guard #available(iOS 26.0, *) else { return nil }
            return HKObjectType.medicationDoseEventType()
        case .activitySummary:
            // HKActivitySummaryType is an HKObjectType, not an HKSampleType. It
            // can't ride the bulk-read sample-type path (or the observer); the
            // engine unions HKObjectType.activitySummaryType() into the read set
            // separately. Returning nil here keeps it out of both.
            return nil
        }
    }

    /// True for types HealthKit only exposes via `requestPerObjectReadAuthorization`
    /// (excluded from bulk authorization, observer, and background-delivery APIs).
    var needsPerObjectAuthorization: Bool { kind == .medicationDose }

    var unit: HKUnit? { unitString.map(HKUnit.init(from:)) }
}

/// Registry of every type PulsHealthSync knows how to export.
///
/// `definitions` is the complete vocabulary on every iOS the package supports;
/// `all` (and `quantityTypes`/`categoryTypes`/`specialTypes`) is the subset
/// the running OS exposes, which is what the app offers and syncs. The
/// published vocabulary, `docs/protocol/catalog.json`, is rendered from
/// `definitions` by `CatalogVocabularyTests` in the package tests, which also
/// fail whenever the committed file and this catalog disagree.
public enum HealthTypeCatalog {
    /// Special identifier used for workouts (HKWorkoutType has no string identifier).
    public static let workoutIdentifier = "HKWorkoutTypeIdentifier"
    /// Special identifier for daily activity summaries (the activity rings).
    /// HKActivitySummaryType has no string identifier; the server keys its
    /// `activity_summaries` table on date, not this string, and uses it only
    /// for `/v1/stats` bookkeeping.
    public static let activitySummaryIdentifier = "HKActivitySummaryTypeIdentifier"
    /// Series/special type identifiers (these match the HK type identifier constants;
    /// the server hardcodes the same strings in its stats query).
    public static let heartbeatSeriesIdentifier = "HKDataTypeIdentifierHeartbeatSeries"
    public static let electrocardiogramIdentifier = "HKDataTypeIdentifierElectrocardiogram"
    public static let stateOfMindIdentifier = "HKDataTypeIdentifierStateOfMind"
    public static let medicationDoseIdentifier = "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"
    /// iOS 18 category type, spelled out because `HKCategoryTypeIdentifier.sleepApneaEvent`
    /// is `@available(iOS 18, *)` and `definitions` must build on every runtime.
    /// `CatalogTests.gatedIdentifiersMatchTheSDK` pins it to the SDK constant.
    public static let sleepApneaEventIdentifier = "HKCategoryTypeIdentifierSleepApneaEvent"
    /// iOS 27 quantity type ("Recovery HRV" in the Health app), spelled out
    /// because `HKQuantityTypeIdentifier.heartRateVariabilityRMSSD` exists only
    /// in the iOS 27 SDK and CI also builds with Xcode 26.5.
    /// `CatalogTests.gatedIdentifiersMatchTheSDK` pins it to the SDK constant.
    public static let heartRateVariabilityRMSSDIdentifier = "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD"

    /// Every type the catalog defines, on every iOS PulsHealth supports, in
    /// declaration order. Never depends on the running OS: this is the
    /// published vocabulary.
    public static let definitions: [HealthTypeDescriptor] =
        quantityDefinitions + categoryDefinitions + specialDefinitions + [
            HealthTypeDescriptor(
                identifier: workoutIdentifier, displayName: "Workouts", kind: .workout,
                unitString: nil, group: .workouts, estimatedSamplesPerDay: 2,
                minimumIOS: .baseline
            ),
            HealthTypeDescriptor(
                identifier: activitySummaryIdentifier, displayName: "Activity Rings",
                kind: .activitySummary, unitString: nil, group: .activity, estimatedSamplesPerDay: 1,
                minimumIOS: .baseline
            ),
        ]

    /// The definitions the running OS exposes — what the app offers and syncs.
    /// An entry whose `minimumIOS` is above the running OS is absent, exactly
    /// as it was when the gates were `#available` checks.
    public static let all: [HealthTypeDescriptor] = definitions.filter(\.isAvailableOnThisOS)

    /// True for the daily activity-summary (rings) type, which is exported via
    /// `HKActivitySummaryQuery` rather than the anchored/observer sample path.
    public static func isActivitySummary(_ identifier: String) -> Bool {
        identifier == activitySummaryIdentifier
    }

    /// Series + non-quantity special types the running OS exposes.
    public static let specialTypes: [HealthTypeDescriptor] =
        specialDefinitions.filter(\.isAvailableOnThisOS)

    /// Series + non-quantity special types, OS-gated entries included.
    public static let specialDefinitions: [HealthTypeDescriptor] = [
        HealthTypeDescriptor(
            identifier: heartbeatSeriesIdentifier, displayName: "Heartbeat Series (beat-to-beat)",
            kind: .heartbeatSeries, unitString: nil, group: .heart, estimatedSamplesPerDay: 6,
            minimumIOS: .baseline
        ),
        HealthTypeDescriptor(
            identifier: electrocardiogramIdentifier, displayName: "ECG",
            kind: .ecg, unitString: nil, group: .heart, estimatedSamplesPerDay: 1,
            minimumIOS: .baseline
        ),
        HealthTypeDescriptor(
            identifier: stateOfMindIdentifier, displayName: "State of Mind",
            kind: .stateOfMind, unitString: nil, group: .other, estimatedSamplesPerDay: 2,
            minimumIOS: HealthTypeDescriptor.IOSVersion(18)
        ),
        HealthTypeDescriptor(
            identifier: medicationDoseIdentifier, displayName: "Medication Doses",
            kind: .medicationDose, unitString: nil, group: .other, estimatedSamplesPerDay: 3,
            minimumIOS: HealthTypeDescriptor.IOSVersion(26)
        ),
    ]

    /// The descriptor for an identifier the running OS exposes; nil for
    /// unknown identifiers and for definitions above the running OS.
    public static func descriptor(for identifier: String) -> HealthTypeDescriptor? {
        byIdentifier[identifier]
    }

    /// Execution order for a backfill sweep over `identifiers`.
    ///
    /// A backfill is one long pole plus a long tail: summed over the catalog,
    /// heart rate alone is a little over half of `estimatedSamplesPerDay`, and
    /// most types are in the single digits per day. Neither naive sort handles
    /// that. Ascending leaves the pole to start last and then run by itself
    /// after everything else has drained, which stretches the whole sweep;
    /// descending parks every concurrent slot on a heavy type and lands nothing
    /// visible for the first stretch.
    ///
    /// So the single most expensive type goes first — it is the critical path
    /// and wants a slot from t=0 — and the rest follow cheapest-first, so the
    /// remaining slots retire the once-a-day types in the opening minutes
    /// instead of at whatever point the alphabet happened to put them. Ties and
    /// identifiers with no descriptor on this OS fall back to identifier order,
    /// so the sweep stays deterministic.
    public static func backfillOrder(_ identifiers: [String]) -> [String] {
        func cost(_ identifier: String) -> Int {
            descriptor(for: identifier)?.estimatedSamplesPerDay ?? 0
        }
        let ascending = identifiers.sorted {
            cost($0) == cost($1) ? $0 < $1 : cost($0) < cost($1)
        }
        guard let heaviest = ascending.last else { return ascending }
        return [heaviest] + ascending.dropLast()
    }

    /// Sample types that are safe to pass to HealthKit's normal bulk read APIs.
    /// Per-object-only Health Records types, such as medication dose events, must
    /// use `requestPerObjectReadAuthorization` instead.
    public static var bulkReadAuthorizationSampleTypes: [HKSampleType] {
        bulkReadAuthorizationSampleTypes(for: all.map(\.identifier))
    }

    /// Bulk-auth sample types for a specific set of catalog identifiers: unknown
    /// identifiers and per-object types are skipped, and workout routes ride along
    /// whenever workouts are included (they have their own object type) unless
    /// `includeWorkoutRoutes` is false.
    public static func bulkReadAuthorizationSampleTypes(
        for identifiers: [String], includeWorkoutRoutes: Bool = true
    ) -> [HKSampleType] {
        var types = identifiers
            .compactMap { descriptor(for: $0) }
            .filter { !$0.needsPerObjectAuthorization }
            .compactMap(\.sampleType)
        if includeWorkoutRoutes && identifiers.contains(workoutIdentifier) {
            types.append(HKSeriesType.workoutRoute())
        }
        return types
    }

    public static func usesPerObjectAuthorization(_ identifier: String) -> Bool {
        descriptor(for: identifier)?.needsPerObjectAuthorization ?? false
    }

    @available(iOS 26.0, *)
    public static var perObjectReadAuthorizationObjectTypes: [HKObjectType] {
        [
            HKObjectType.userAnnotatedMedicationType(),
            HKObjectType.medicationDoseEventType(),
        ]
    }

    private static let byIdentifier: [String: HealthTypeDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.identifier, $0) })

    // MARK: - Quantity types

    private static func q(
        _ id: HKQuantityTypeIdentifier, _ name: String, _ unit: String,
        _ group: HealthTypeDescriptor.Group, perDay: Int
    ) -> HealthTypeDescriptor {
        HealthTypeDescriptor(
            identifier: id.rawValue, displayName: name, kind: .quantity,
            unitString: unit, group: group, estimatedSamplesPerDay: perDay,
            minimumIOS: .baseline
        )
    }

    private static func q(
        _ identifier: String, _ name: String, _ unit: String,
        _ group: HealthTypeDescriptor.Group, perDay: Int,
        minimumIOS: HealthTypeDescriptor.IOSVersion
    ) -> HealthTypeDescriptor {
        HealthTypeDescriptor(
            identifier: identifier, displayName: name, kind: .quantity,
            unitString: unit, group: group, estimatedSamplesPerDay: perDay,
            minimumIOS: minimumIOS
        )
    }

    /// Quantity types the running OS exposes.
    public static let quantityTypes: [HealthTypeDescriptor] =
        quantityDefinitions.filter(\.isAvailableOnThisOS)

    /// Quantity types, OS-gated entries included. A gated entry here must use
    /// a raw identifier string (the SDK constant is unavailable to older
    /// compilers' availability checking) and carry its `minimumIOS`.
    public static let quantityDefinitions: [HealthTypeDescriptor] = [
        // Activity
        q(.stepCount, "Steps", "count", .activity, perDay: 250),
        q(.distanceWalkingRunning, "Walking + Running Distance", "m", .activity, perDay: 250),
        q(.distanceCycling, "Cycling Distance", "m", .activity, perDay: 20),
        q(.flightsClimbed, "Flights Climbed", "count", .activity, perDay: 30),
        q(.activeEnergyBurned, "Active Energy", "kcal", .activity, perDay: 700),
        q(.basalEnergyBurned, "Resting Energy", "kcal", .activity, perDay: 350),
        q(.appleExerciseTime, "Exercise Minutes", "min", .activity, perDay: 60),
        q(.appleStandTime, "Stand Minutes", "min", .activity, perDay: 60),
        q(.appleMoveTime, "Move Minutes", "min", .activity, perDay: 60),
        q(.walkingSpeed, "Walking Speed", "m/s", .activity, perDay: 60),
        q(.walkingStepLength, "Step Length", "m", .activity, perDay: 60),
        q(.walkingDoubleSupportPercentage, "Double Support %", "%", .activity, perDay: 60),
        q(.walkingAsymmetryPercentage, "Walking Asymmetry %", "%", .activity, perDay: 30),
        q(.runningSpeed, "Running Speed", "m/s", .activity, perDay: 50),
        q(.runningPower, "Running Power", "W", .activity, perDay: 50),
        q(.runningGroundContactTime, "Ground Contact Time", "ms", .activity, perDay: 50),
        q(.runningVerticalOscillation, "Vertical Oscillation", "cm", .activity, perDay: 50),
        q(.runningStrideLength, "Running Stride Length", "m", .activity, perDay: 50),
        q(.cyclingPower, "Cycling Power", "W", .activity, perDay: 50),
        q(.cyclingCadence, "Cycling Cadence", "count/min", .activity, perDay: 50),
        q(.cyclingSpeed, "Cycling Speed", "m/s", .activity, perDay: 50),
        q(.distanceSwimming, "Swimming Distance", "m", .activity, perDay: 5),
        q(.swimmingStrokeCount, "Swimming Strokes", "count", .activity, perDay: 5),
        q(.vo2Max, "VO₂ Max", "ml/kg*min", .activity, perDay: 1),
        q(.physicalEffort, "Physical Effort", "kcal/hr*kg", .activity, perDay: 100),

        // Heart
        q(.heartRate, "Heart Rate", "count/min", .heart, perDay: 3500),
        q(.restingHeartRate, "Resting Heart Rate", "count/min", .heart, perDay: 1),
        q(.walkingHeartRateAverage, "Walking HR Average", "count/min", .heart, perDay: 1),
        q(.heartRateVariabilitySDNN, "HRV (SDNN)", "ms", .heart, perDay: 8),
        q(heartRateVariabilityRMSSDIdentifier, "HRV (RMSSD)", "ms", .heart, perDay: 100,
          minimumIOS: HealthTypeDescriptor.IOSVersion(27)),
        q(.heartRateRecoveryOneMinute, "HR Recovery (1 min)", "count/min", .heart, perDay: 1),
        q(.atrialFibrillationBurden, "AFib Burden", "%", .heart, perDay: 1),
        q(.peripheralPerfusionIndex, "Perfusion Index", "%", .heart, perDay: 1),

        // Body
        q(.bodyMass, "Body Weight", "kg", .body, perDay: 1),
        q(.bodyMassIndex, "BMI", "count", .body, perDay: 1),
        q(.bodyFatPercentage, "Body Fat %", "%", .body, perDay: 1),
        q(.leanBodyMass, "Lean Body Mass", "kg", .body, perDay: 1),
        q(.height, "Height", "m", .body, perDay: 1),
        q(.waistCircumference, "Waist Circumference", "m", .body, perDay: 1),
        q(.bodyTemperature, "Body Temperature", "degC", .body, perDay: 1),
        q(.basalBodyTemperature, "Basal Body Temperature", "degC", .body, perDay: 1),
        q(.appleSleepingWristTemperature, "Wrist Temperature (Sleep)", "degC", .sleep, perDay: 1),

        // Respiratory / vitals
        q(.respiratoryRate, "Respiratory Rate", "count/min", .respiratory, perDay: 120),
        q(.oxygenSaturation, "Blood Oxygen", "%", .respiratory, perDay: 30),
        q(.bloodPressureSystolic, "Blood Pressure (Systolic)", "mmHg", .vitals, perDay: 2),
        q(.bloodPressureDiastolic, "Blood Pressure (Diastolic)", "mmHg", .vitals, perDay: 2),
        q(.bloodGlucose, "Blood Glucose", "mg/dL", .vitals, perDay: 10),
        q(.bloodAlcoholContent, "Blood Alcohol Content", "%", .vitals, perDay: 1),
        q(.numberOfTimesFallen, "Falls", "count", .vitals, perDay: 1),
        q(.environmentalAudioExposure, "Environmental Sound", "dBASPL", .other, perDay: 50),
        q(.headphoneAudioExposure, "Headphone Audio", "dBASPL", .other, perDay: 30),
        q(.environmentalSoundReduction, "Sound Reduction", "dBASPL", .other, perDay: 30),
        q(.timeInDaylight, "Time in Daylight", "min", .other, perDay: 20),
        q(.uvExposure, "UV Exposure", "count", .other, perDay: 5),

        // Nutrition
        q(.dietaryEnergyConsumed, "Dietary Energy", "kcal", .nutrition, perDay: 5),
        q(.dietaryProtein, "Protein", "g", .nutrition, perDay: 5),
        q(.dietaryCarbohydrates, "Carbohydrates", "g", .nutrition, perDay: 5),
        q(.dietaryFatTotal, "Total Fat", "g", .nutrition, perDay: 5),
        q(.dietaryFiber, "Fiber", "g", .nutrition, perDay: 5),
        q(.dietarySugar, "Sugar", "g", .nutrition, perDay: 5),
        q(.dietarySodium, "Sodium", "mg", .nutrition, perDay: 5),
        q(.dietaryCaffeine, "Caffeine", "mg", .nutrition, perDay: 3),
        q(.dietaryWater, "Water", "mL", .nutrition, perDay: 8),
    ]
    // workoutEffortScore / estimatedWorkoutEffortScore are deliberately absent:
    // iOS never lists them in the read-authorization sheet (FB15315876), so any
    // request containing them leaves statusForAuthorizationRequest stuck at
    // .shouldRequest and — once they're the only undetermined types — makes the
    // permission sheet flash and auto-dismiss, blocking every other pending grant.
    // Effort scores still reach the server attached to workout payloads via
    // SeriesEnricher.effortScores(for:).

    // MARK: - Category types

    private static func c(
        _ id: HKCategoryTypeIdentifier, _ name: String,
        _ group: HealthTypeDescriptor.Group, perDay: Int
    ) -> HealthTypeDescriptor {
        c(id.rawValue, name, group, perDay: perDay, minimumIOS: .baseline)
    }

    private static func c(
        _ identifier: String, _ name: String,
        _ group: HealthTypeDescriptor.Group, perDay: Int,
        minimumIOS: HealthTypeDescriptor.IOSVersion
    ) -> HealthTypeDescriptor {
        HealthTypeDescriptor(
            identifier: identifier, displayName: name, kind: .category,
            unitString: nil, group: group, estimatedSamplesPerDay: perDay,
            minimumIOS: minimumIOS
        )
    }

    /// Category types the running OS exposes.
    public static let categoryTypes: [HealthTypeDescriptor] =
        categoryDefinitions.filter(\.isAvailableOnThisOS)

    /// Category types, OS-gated entries included.
    public static let categoryDefinitions: [HealthTypeDescriptor] = [
        c(.sleepAnalysis, "Sleep Stages", .sleep, perDay: 40),
        c(.appleStandHour, "Stand Hours", .activity, perDay: 16),
        c(.mindfulSession, "Mindful Minutes", .other, perDay: 2),
        c(.highHeartRateEvent, "High HR Events", .heart, perDay: 1),
        c(.lowHeartRateEvent, "Low HR Events", .heart, perDay: 1),
        c(.irregularHeartRhythmEvent, "Irregular Rhythm Events", .heart, perDay: 1),
        c(.lowCardioFitnessEvent, "Low Cardio Fitness Events", .heart, perDay: 1),
        c(.handwashingEvent, "Handwashing Events", .other, perDay: 5),
        c(.toothbrushingEvent, "Toothbrushing Events", .other, perDay: 2),
        c(.environmentalAudioExposureEvent, "Loud Environment Events", .other, perDay: 1),
        c(.headphoneAudioExposureEvent, "Loud Headphone Events", .other, perDay: 1),
        c(sleepApneaEventIdentifier, "Sleep Apnea Events", .sleep, perDay: 1,
          minimumIOS: HealthTypeDescriptor.IOSVersion(18)),
    ]
}
