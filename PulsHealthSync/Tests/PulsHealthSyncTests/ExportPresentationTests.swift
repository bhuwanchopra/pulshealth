import Foundation
import Testing
@testable import PulsHealthSync

/// What the export screen says and asks for. The range arithmetic decides which
/// samples are in the file; the failure copy decides whether someone whose
/// Health access is off is told so, or told they have no data.
@Suite struct ExportPresentationTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - Range

    @Test func aRangeStartsAtLocalMidnightNotMidAfternoon() {
        // 14:30 in Los Angeles on 21 September.
        let now = date("2026-09-21T21:30:00Z")
        let start = ExportRange.last30Days.startDate(now: now, calendar: calendar("America/Los_Angeles"))
        // 22 August, 00:00 PDT.
        #expect(start == date("2026-08-22T07:00:00Z"))
    }

    @Test func theSameInstantIsADifferentDayInAnotherZone() {
        // Already the 22nd in Auckland, so thirty days back is a day later.
        let now = date("2026-09-21T21:30:00Z")
        let start = ExportRange.last30Days.startDate(now: now, calendar: calendar("Pacific/Auckland"))
        #expect(start == date("2026-08-22T12:00:00Z"))
    }

    @Test func aYearIsACalendarYearAcrossALeapDay() {
        let now = date("2028-03-01T12:00:00Z")
        let start = ExportRange.lastYear.startDate(now: now, calendar: calendar("UTC"))
        #expect(start == date("2027-03-01T00:00:00Z"))
    }

    @Test func ninetyDaysCrossesADaylightSavingChangeWithoutDrifting() {
        // 90 days back from 1 December crosses the November fall-back in Los
        // Angeles; the start is still a local midnight (PDT, UTC−7).
        let now = date("2026-12-01T20:00:00Z")
        let start = ExportRange.last90Days.startDate(now: now, calendar: calendar("America/Los_Angeles"))
        #expect(start == date("2026-09-02T07:00:00Z"))
    }

    @Test func allTimeHasNoStartAndIsTheOnlyRangeWithASizeWarning() {
        #expect(ExportRange.allTime.startDate() == nil)
        #expect(ExportRange.allTime.sizeNote != nil)
        for range in ExportRange.allCases where range != .allTime {
            #expect(range.startDate() != nil)
            #expect(range.sizeNote == nil)
        }
    }

    // MARK: - Selection

    @Test func theSummaryCountsWhatTheExportWillRun() {
        var config = SyncConfiguration()
        config.enabledTypes = [HealthTypeCatalog.workoutIdentifier, "HKQuantityTypeIdentifierHeartRate"]
        var enabled = AggregateConfig(typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum)
        enabled.enabled = true
        var disabled = AggregateConfig(typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum)
        disabled.enabled = false
        config.aggregates = [enabled, disabled]
        config.includeWorkoutRoutes = true
        config.includeWorkoutEnhancedData = false

        let summary = ExportSelectionSummary(configuration: config)
        #expect(summary.typeCount == 2)
        #expect(summary.aggregateCount == 1)
        #expect(summary.includesWorkoutRoutes)
        #expect(!summary.includesWorkoutStreams)
        #expect(!summary.isEmpty)
    }

    @Test func routeAndStreamSwitchesMeanNothingWithoutWorkouts() {
        var config = SyncConfiguration()
        config.enabledTypes = ["HKQuantityTypeIdentifierHeartRate"]
        config.includeWorkoutRoutes = true
        config.includeWorkoutEnhancedData = true
        let summary = ExportSelectionSummary(configuration: config)
        #expect(!summary.includesWorkoutRoutes)
        #expect(!summary.includesWorkoutStreams)
    }

    @Test func emptyAgreesWithTheExportersOwnCheck() {
        var config = SyncConfiguration()
        config.enabledTypes = []
        var disabled = AggregateConfig(typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum)
        disabled.enabled = false
        config.aggregates = [disabled]
        #expect(ExportSelectionSummary(configuration: config).isEmpty)
        #expect(!ExportPlan.hasAnythingToExport(ExportSelection(configuration: config)))

        // An aggregate-only selection is something to export.
        config.aggregates[0].enabled = true
        #expect(!ExportSelectionSummary(configuration: config).isEmpty)
        #expect(ExportPlan.hasAnythingToExport(ExportSelection(configuration: config)))
    }

    /// A selection built for the export, not from the configuration: every
    /// aggregate in it counts whatever its `enabled` flag says, and the two
    /// initialisers agree on the applied selection.
    @Test func aSelectionOfItsOwnCountsEverythingItNames() {
        var config = SyncConfiguration()
        config.enabledTypes = [HealthTypeCatalog.workoutIdentifier]
        config.includeWorkoutRoutes = false
        var off = AggregateConfig(typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum)
        off.enabled = false
        config.aggregates = [off]

        let selection = ExportSelection(
            types: [HealthTypeCatalog.workoutIdentifier, "HKQuantityTypeIdentifierHeartRate"],
            aggregates: [off], includeWorkoutRoutes: true, includeWorkoutEnhancedData: true)
        let summary = ExportSelectionSummary(selection: selection)
        #expect(summary.typeCount == 2)
        #expect(summary.aggregateCount == 1)
        #expect(summary.includesWorkoutRoutes)
        #expect(summary.includesWorkoutStreams)
        #expect(!selection.isEmpty)

        let applied = ExportSelection(configuration: config)
        #expect(applied.aggregates.isEmpty)
        #expect(ExportSelectionSummary(configuration: config) == ExportSelectionSummary(selection: applied))
        #expect(ExportSelection(types: []).isEmpty)
        #expect(!ExportSelection(types: [], aggregates: [off]).isEmpty)
    }

    // MARK: - Failure copy

    @Test func cancellationIsNotAFailure() {
        #expect(ExportFailureCopy(error: CancellationError()) == nil)
    }

    @Test func noDataGivesBothReadingsAndPointsAtHealthSettings() throws {
        let copy = try #require(ExportFailureCopy(error: HealthExportError.noData))
        #expect(copy.suggestion == .healthAccess)
        // The innocent reading, and the one HealthKit will never confirm.
        #expect(copy.message.contains("longer range"))
        #expect(copy.message.contains("Settings → Privacy & Security → Health"))
    }

    @Test func nothingSelectedPointsAtDataTypes() throws {
        let copy = try #require(ExportFailureCopy(error: HealthExportError.nothingSelected))
        #expect(copy.suggestion == .dataTypes)
        #expect(copy.message.contains("Data Types on the Export tab"))
        #expect(!copy.message.contains("Data Types tab"))
    }

    @Test func aLockedDeviceSaysToUnlock() throws {
        let copy = try #require(ExportFailureCopy(error: HealthExportError.deviceLocked))
        #expect(copy.suggestion == .none)
        #expect(copy.message.contains("Unlock"))
    }

    @Test func aTotalFailureKeepsThePerTypeReasons() throws {
        let issues = [ExportIssue(type: "HKQuantityTypeIdentifierHeartRate", message: "Authorization not determined")]
        let copy = try #require(ExportFailureCopy(error: HealthExportError.failed(issues)))
        #expect(copy.issues == issues)
        #expect(copy.suggestion == .healthAccess)
        #expect(copy.issues[0].typeDisplayName == "Heart Rate")
    }

    @Test func aWriteFailureCarriesItsReasonAndSaysNothingWasKept() throws {
        let copy = try #require(ExportFailureCopy(error: HealthExportError.writeFailed("No space left on device")))
        #expect(copy.message.contains("No space left on device"))
        #expect(copy.message.contains("removed"))
    }

    @Test func anUnknownErrorIsScrubbedLikeEverythingElseShown() throws {
        struct Leaky: LocalizedError {
            var errorDescription: String? { "GET https://example.test/x?token=s3cr3t failed" }
        }
        let copy = try #require(ExportFailureCopy(error: Leaky()))
        #expect(!copy.message.contains("s3cr3t"))
        #expect(copy.message.contains("Nothing was kept"))
    }

    @Test func anIssueNamesItsTypeTheWayTheAppDoes() {
        #expect(ExportIssue(type: "HKWorkoutTypeIdentifier", message: "x").typeDisplayName == "Workouts")
        #expect(ExportIssue(type: "NotInTheCatalog", message: "x").typeDisplayName == "NotInTheCatalog")
        #expect(ExportIssue(message: "x").typeDisplayName == nil)
    }

    @Test func whatIsInTheFilesLeavesOutWhatCSVCouldNotWrite() {
        let result = ExportResult(
            format: .csv, directory: URL(fileURLWithPath: "/tmp/x"), files: [],
            manifestURL: URL(fileURLWithPath: "/tmp/x/m.json"),
            rowCounts: [.samples: 100, .heartbeatSeries: 3, .deletions: 2],
            notRepresented: [.heartbeatSeries: 3, .deletions: 2],
            unmappableSamples: [:], failures: [], warnings: [], totalBytes: 1, duration: 1)
        #expect(result.totalRows == 105)
        #expect(result.writtenRowCounts == [.samples: 100])
        #expect(result.writtenRows == 100)
    }

    @Test func everyDatasetPhaseAndFormatHasWords() {
        for dataset in ExportDataset.allCases { #expect(!dataset.displayName.isEmpty) }
        for format in ExportFormat.allCases { #expect(!format.title.isEmpty) }
        // CSV has no shape for these; the result screen lists them as left out.
        #expect(!ExportDataset.ecg.isWrittenToCSV)
        #expect(!ExportDataset.heartbeatSeries.isWrittenToCSV)
    }
}
