import Foundation
import Testing
@testable import PulsHealthSync

/// A type is synced by one run at a time, and the run that holds it is the
/// one that finishes it. What the first sync after pairing depends on is that
/// a backfill takes *all* of its types before anything else can, and that
/// every claim it takes is given back — a type left claimed is a type that
/// never syncs again until the app restarts.
///
/// No server is configured here, so each type's run ends at once ("No
/// transport configured"); the claims are what is under test.
@Suite struct SweepClaimTests {
    func makeEngine() -> HealthSyncEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        return HealthSyncEngine(
            store: SyncStateStore(directory: dir),
            eventLog: SyncEventLog(directory: dir),
            wakeLog: WakeLog(directory: dir))
    }

    @Test func aTypeAnotherRunHoldsIsLeftToItAndMarkedForAFollowUp() async {
        let engine = makeEngine()
        #expect(await engine.claimTypes(["b"]) == ["b"])

        let claimed = await engine.claimTypes(["a", "b", "c"])

        #expect(claimed == ["a", "c"])
        #expect(await engine.pendingResync == ["b"])
        for id in ["a", "b", "c"] { #expect(await engine.isSyncing(id)) }
    }

    @Test func aSweepGivesBackEveryClaimItTook() async {
        let engine = makeEngine()
        let ids = ["a", "b", "c", "d", "e", "f"]
        let claimed = await engine.claimTypes(ids)

        await engine.sweep(claimed, reason: .backfill)

        for id in ids { #expect(!(await engine.isSyncing(id))) }
    }

    @Test func aCancelledSweepStillGivesBackEveryClaim() async {
        let engine = makeEngine()
        let ids = (0..<20).map { "t\($0)" }
        let claimed = await engine.claimTypes(ids)

        let run = Task { await engine.sweep(claimed, reason: .backfill) }
        run.cancel()
        await run.value

        for id in ids { #expect(!(await engine.isSyncing(id))) }
    }

    @Test func syncingABusyTypeDefersToTheRunThatHoldsIt() async {
        let engine = makeEngine()
        _ = await engine.claimTypes(["a"])

        await engine.sync(type: "a", reason: .manual)

        // Still held by the first claim, and queued for it to repeat.
        #expect(await engine.isSyncing("a"))
        #expect(await engine.pendingResync == ["a"])
    }
}
