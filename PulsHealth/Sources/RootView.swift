import SwiftUI
import PulsHealthSync

struct RootView: View {
    private enum Tab: String, Hashable {
        case explore, export, sync, settings

        /// Debug builds accept `-PulsInitialTab <name>` so a scripted
        /// simulator run can screenshot each tab without tapping; release
        /// builds always start on Explore.
        static var initial: Tab {
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "PulsInitialTab"), let tab = Tab(rawValue: name) {
                return tab
            }
            #endif
            return .explore
        }
    }
    @State private var selection: Tab = Tab.initial
    /// Owned here rather than by SyncView so an accepted pairing link can pop
    /// whatever the Sync tab had pushed and land on its Database screen.
    @State private var syncPath: [SyncRoute] = []
    /// Debug builds accept `-PulsInitialType <identifier>` alongside
    /// `-PulsInitialTab explore`, so a scripted run can screenshot a Type page.
    @State private var explorePath: [ExploreRoute] = {
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: "PulsInitialType") { return [.type(id)] }
        #endif
        return []
    }()
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $selection) {
            NavigationStack(path: $explorePath) { ExploreView() }
                .tabItem { Label("Explore", systemImage: "heart.text.square") }
                .tag(Tab.explore)
            NavigationStack { ExportView() }
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(Tab.export)
            NavigationStack(path: $syncPath) { SyncView(path: $syncPath) }
                // The Synced Data screen is pushed on this stack, so its
                // Apply/Discard bar belongs to the tab, not to a screen that
                // could be popped with edits still staged.
                .safeAreaInset(edge: .bottom) { PendingChangesBar() }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.sync)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // An incoming `puls://` link asks before it fills anything. While the
        // first-run flow covers this view the prompt is OnboardingView's; and
        // it waits its turn behind the server-change prompt, which can be up
        // from launch.
        .pairingLinkPrompt(canPresent: !model.showsOnboarding && model.pendingServerChange == nil)
        // Accepted: take the user to the fields the link filled in, the same
        // place a scan from the Database screen would have left them.
        // ServerSettingsView collects the payload itself; nothing is applied
        // from here.
        .onChange(of: model.pairingAwaitsSyncTab) { _, waiting in
            guard waiting else { return }
            syncPath = [.server(scan: false)]
            selection = .sync
        }
        // Save & Apply on Settings, the User page, the Database screen or the
        // Synced Data bar can all raise the server/user-change prompt; show it
        // above every tab.
        .serverChangePrompt()
        // First run only: a fresh install lands here with no server and no
        // types, so the tabs have nothing to show and nothing to say about
        // where to start. `showsOnboarding` is false for every configured
        // install (see AppModel).
        .fullScreenCover(isPresented: $model.showsOnboarding) {
            OnboardingView().environment(model)
        }
    }
}
