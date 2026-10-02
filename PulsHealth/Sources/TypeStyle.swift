import SwiftUI
import PulsHealthSync

// Visual identity for catalog types, mirroring Apple Health's category palette.
// UI-only concern, so it lives in the app rather than the library catalog.

extension HealthTypeDescriptor.Group {
    var color: Color {
        switch self {
        case .activity: .orange
        case .heart: .red
        case .body: .purple
        case .respiratory: .cyan
        case .sleep: .mint
        case .nutrition: .green
        case .vitals: .pink
        case .workouts: .teal
        case .other: .indigo
        }
    }

    var symbol: String {
        switch self {
        case .activity: "flame.fill"
        case .heart: "heart.fill"
        case .body: "figure.arms.open"
        case .respiratory: "lungs.fill"
        case .sleep: "bed.double.fill"
        case .nutrition: "carrot.fill"
        case .vitals: "waveform.path.ecg"
        case .workouts: "figure.run"
        case .other: "square.grid.2x2.fill"
        }
    }
}

extension HealthTypeDescriptor {
    var symbol: String { Self.symbolOverrides[identifier] ?? group.symbol }

    private static let symbolOverrides: [String: String] = [
        // Activity
        "HKQuantityTypeIdentifierStepCount": "figure.walk",
        "HKQuantityTypeIdentifierDistanceWalkingRunning": "figure.walk.motion",
        "HKQuantityTypeIdentifierDistanceCycling": "figure.outdoor.cycle",
        "HKQuantityTypeIdentifierFlightsClimbed": "figure.stairs",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "flame.fill",
        "HKQuantityTypeIdentifierBasalEnergyBurned": "flame",
        "HKQuantityTypeIdentifierAppleExerciseTime": "figure.run",
        "HKQuantityTypeIdentifierAppleStandTime": "figure.stand",
        "HKCategoryTypeIdentifierAppleStandHour": "figure.stand",
        "HKQuantityTypeIdentifierWalkingSpeed": "speedometer",
        "HKQuantityTypeIdentifierWalkingStepLength": "ruler",
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage": "figure.walk",
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage": "figure.walk",
        "HKQuantityTypeIdentifierRunningSpeed": "figure.run",
        "HKQuantityTypeIdentifierRunningPower": "bolt.fill",
        "HKQuantityTypeIdentifierRunningGroundContactTime": "figure.run",
        "HKQuantityTypeIdentifierRunningVerticalOscillation": "figure.run",
        "HKQuantityTypeIdentifierRunningStrideLength": "figure.run",
        "HKQuantityTypeIdentifierCyclingPower": "bolt.fill",
        "HKQuantityTypeIdentifierCyclingCadence": "figure.outdoor.cycle",
        "HKQuantityTypeIdentifierCyclingSpeed": "figure.outdoor.cycle",
        "HKQuantityTypeIdentifierDistanceSwimming": "figure.pool.swim",
        "HKQuantityTypeIdentifierSwimmingStrokeCount": "figure.pool.swim",
        "HKQuantityTypeIdentifierVO2Max": "bolt.heart.fill",
        "HKQuantityTypeIdentifierPhysicalEffort": "gauge.medium",

        // Heart
        "HKQuantityTypeIdentifierRestingHeartRate": "arrow.down.heart.fill",
        "HKQuantityTypeIdentifierWalkingHeartRateAverage": "figure.walk",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "waveform.path",
        "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD": "waveform.path",
        "HKQuantityTypeIdentifierAtrialFibrillationBurden": "waveform.path.ecg.rectangle",
        "HKDataTypeIdentifierHeartbeatSeries": "waveform.path",
        "HKDataTypeIdentifierElectrocardiogram": "waveform.path.ecg",

        // Body
        "HKQuantityTypeIdentifierBodyMass": "scalemass.fill",
        "HKQuantityTypeIdentifierBodyMassIndex": "scalemass",
        "HKQuantityTypeIdentifierLeanBodyMass": "scalemass",
        "HKQuantityTypeIdentifierBodyFatPercentage": "percent",
        "HKQuantityTypeIdentifierHeight": "ruler.fill",
        "HKQuantityTypeIdentifierWaistCircumference": "ruler",
        "HKQuantityTypeIdentifierBodyTemperature": "medical.thermometer.fill",
        "HKQuantityTypeIdentifierBasalBodyTemperature": "medical.thermometer",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature": "medical.thermometer",

        // Respiratory / vitals
        "HKQuantityTypeIdentifierOxygenSaturation": "drop.fill",
        "HKQuantityTypeIdentifierBloodGlucose": "drop.fill",
        "HKQuantityTypeIdentifierBloodAlcoholContent": "drop",
        "HKQuantityTypeIdentifierNumberOfTimesFallen": "figure.fall",

        // Sleep
        "HKCategoryTypeIdentifierSleepApneaEvent": "zzz",

        // Nutrition
        "HKQuantityTypeIdentifierDietaryEnergyConsumed": "fork.knife",
        "HKQuantityTypeIdentifierDietaryWater": "drop.fill",
        "HKQuantityTypeIdentifierDietaryCaffeine": "cup.and.saucer.fill",

        // Other
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure": "ear.fill",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure": "headphones",
        "HKQuantityTypeIdentifierEnvironmentalSoundReduction": "ear.fill",
        "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent": "ear.trianglebadge.exclamationmark",
        "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent": "ear.trianglebadge.exclamationmark",
        "HKQuantityTypeIdentifierTimeInDaylight": "sun.max.fill",
        "HKQuantityTypeIdentifierUVExposure": "sun.max.fill",
        "HKCategoryTypeIdentifierMindfulSession": "brain.head.profile",
        "HKCategoryTypeIdentifierHandwashingEvent": "hands.and.sparkles.fill",
        "HKCategoryTypeIdentifierToothbrushingEvent": "mouth.fill",
        "HKDataTypeIdentifierStateOfMind": "face.smiling",
        "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent": "pills.fill",
    ]
}
