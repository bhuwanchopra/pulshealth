import SwiftUI
import PulsHealthSync

@main
struct PulsHealthApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Must happen before app launch finishes so iOS can deliver
        // background task launches.
        model.scheduler.register()
        if #available(iOS 26.0, *) {
            // Lets a user-initiated backfill keep running with system progress UI
            // after the app is backgrounded.
            model.scheduler.registerContinuedBackfill()
        }
        // Start the engine from launch, not from the root view: when HealthKit
        // relaunches the app in the background for a delivery (after a jetsam
        // or reboot) no scene connects, RootView never appears, and its `.task`
        // never runs — so the observer query the delivery is meant for would not
        // exist in the launched process and the wake would be wasted. `start()`
        // is idempotent, so the view's `.task` stays as the foreground path.
        Task { await model.start() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                // `puls://pair?…` — a tapped link, or the server's QR code read
                // by the iOS Camera app. Untrusted by definition: the model
                // only ever turns it into a prompt (`handleIncomingURL`).
                .onOpenURL { model.handleIncomingURL($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Catch up whenever the user opens the app — the most reliable
                // sync trigger on iOS.
                Task { await model.syncNow(trigger: "foreground") }
            case .background:
                Task {
                    await model.ensureBackgroundCatchupScheduled()
                    await model.engine.store.persistNow()
                }
            default:
                break
            }
        }
    }
}
