import Foundation
import UIKit

/// Background time for sync work the app started itself.
///
/// An app that leaves the foreground, or that HealthKit wakes for an observer
/// delivery, gets a few seconds before iOS suspends it. A sweep caught
/// mid-upload then freezes where it stands: its types stay claimed, so the
/// next wake finds them busy and does nothing, and the frozen request usually
/// fails when the process resumes. A reinstall's re-sync on 2026-09-26 moved
/// as much in 44 hours of such wakes as in its first ten foreground minutes.
///
/// `run` asks for the extra time iOS grants on request (roughly half a minute)
/// and, when that runs out, **cancels** the work instead of letting it freeze.
/// Every sweep stops at a page boundary on cancellation, every acked page's
/// anchor is already recorded, and the claims are released for the next wake.
///
/// Not for `BGTaskScheduler` handlers: those carry their own expiration, and a
/// nested request would cut a processing task short at the ~30 s mark.
public enum BackgroundExecution {
    /// Runs `work` under a background-task assertion. Returns false when the
    /// assertion expired and the work was cancelled — the caller's wake
    /// outcome, not an error.
    ///
    /// `onExpiration` runs in the expiration handler itself, before the
    /// assertion is released: anything that must happen before iOS suspends
    /// the app — acknowledging HealthKit, above all — goes there, because the
    /// cancelled work may not unwind far enough to do it in time.
    @discardableResult
    public static func run(
        _ name: String,
        onExpiration: (@Sendable () -> Void)? = nil,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let task = Task { await work() }
        let assertion = await BackgroundAssertion.begin(name) {
            onExpiration?()
            task.cancel()
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return await assertion.end()
    }
}

@MainActor
private final class BackgroundAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var expired = false

    static func begin(_ name: String, onExpiration: @escaping @Sendable () -> Void) -> BackgroundAssertion {
        let assertion = BackgroundAssertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak assertion] in
            // iOS wants the assertion ended promptly here, before the cancelled
            // work has unwound; `end` below is then a no-op.
            onExpiration()
            assertion?.expired = true
            assertion?.release()
        }
        return assertion
    }

    /// Ends the assertion if expiration has not already done so. True when the
    /// work finished inside the time it was given.
    func end() -> Bool {
        release()
        return !expired
    }

    private func release() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
