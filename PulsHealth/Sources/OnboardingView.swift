import SwiftUI
import PulsHealthSync

/// First-run flow: four pages the person swipes through, on iPhone and iPad.
///
/// 1. what the app does (explore, export, sync),
/// 2. Health access for the starter set (`TypePresets.common`, preselected
///    by `AppModel`), picked in iOS's own sheet,
/// 3. one-time exports,
/// 4. syncing to a database of your own, and the button that finishes.
///
/// Page 2 cannot be skipped (App Review rejected 1.4 under 5.1.1(iv) for a
/// Skip). Until iOS has been asked about the starter set, the pager holds only
/// the first two pages, so there is no page past it; a swipe forward there and
/// its one button, Continue, both present the sheet, and the flow moves on
/// once it has been answered. With nothing to ask (a replay after the
/// question was settled) all four pages are there from the start.
///
/// Nothing reaches the engine until Start Exploring: `model.config` is the
/// same staged draft the Synced Data screen edits, and `finishOnboarding()` is
/// the same Save & Apply path. Leaving the app at any point leaves the install
/// as it was, and the flow reappears on the next launch until it is finished.
///
/// A `puls://` pairing link can still arrive while this flow is up. It is
/// confirmed here (the prompt cannot come from the covered RootView), and the
/// accepted payload then waits in `AppModel.confirmedPairing` until the flow
/// ends: `pairingAwaitsSyncTab` turns true, RootView opens Sync → Database,
/// and that screen fills its fields from it.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Page: Int, CaseIterable, Hashable {
        case welcome, health, export, sync
    }

    /// The page on screen. Optional because that is what
    /// `scrollPosition(id:)` binds; nothing here sets it to nil.
    @State private var page: Page? = .welcome
    /// True once iOS has nothing left to ask about the draft: answered on
    /// page 2 in this showing, or found settled when the flow opened. Never
    /// goes back to false while the flow is up, so a swipe back to page 2
    /// does not ask again.
    @State private var healthSettled = false
    @State private var requestingHealthAccess = false
    @State private var finishing = false

    /// Pages 3 and 4 are not in the pager until page 2 is settled: there is
    /// no page past it to swipe to, and no other way to reach one.
    private var pages: [Page] { healthSettled ? Page.allCases : [.welcome, .health] }

    /// A readable line length on iPad, where the screen is far wider than
    /// the text wants to be.
    private let maxContentWidth: CGFloat = 560

    var body: some View {
        // A NavigationStack only for the replay's Close button; nothing is
        // pushed, and on a first run the bar is hidden.
        NavigationStack {
            VStack(spacing: 0) {
                pager
                // Always four dots, though the pager holds two until page 2
                // is settled: the flow's length should not change under you.
                pageDots
            }
            .background(Color(.systemBackground))
            .toolbar {
                if model.onboardingIsRerun {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { model.completeOnboarding() }
                    }
                }
            }
            .toolbar(model.onboardingIsRerun ? .visible : .hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled()
        // This flow covers RootView, so the prompt for an incoming `puls://`
        // link has to come from here. Not over the iOS Health sheet, and not
        // during the final Apply.
        .pairingLinkPrompt(canPresent: !requestingHealthAccess && !finishing)
        .task {
            // Waits for the stored configuration and the preselected starter
            // set, so "nothing to ask" is never the answer for an empty draft.
            if await !model.onboardingHealthAccessPending() {
                healthSettled = true
            }
        }
    }

    /// A horizontal paging scroll view rather than a paged TabView: a
    /// TabView's pager keeps every drag to itself, so a swipe past its last
    /// page could not be noticed, and on page 2 that swipe is what asks.
    private var pager: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                // Not lazy: with a LazyHStack, iOS 27 stopped the first swipe
                // back after the move to page 3 about half a page short.
                HStack(spacing: 0) {
                    ForEach(pages, id: \.self) { each in
                        pageView(each)
                            .containerRelativeFrame(.horizontal)
                            .id(each)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            // No swiping while iOS's sheet is on its way or the final apply runs.
            .scrollDisabled(requestingHealthAccess || finishing)
            // Page 2 is the last page until iOS has been asked, so a swipe
            // forward there only stretches past the end. That pull asks.
            .onPullPastEnd(enabled: !healthSettled && page == .health) { continueFromHealth() }
            // Rotating an iPad, or resizing its window, changes the page
            // width, and the scroll view kept its old offset: on page 3 that
            // left half of page 2 on screen. Put the current page back.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                guard let current = page else { return }
                Task { @MainActor in reader.scrollTo(current, anchor: .leading) }
            }
        }
    }

    @ViewBuilder private func pageView(_ page: Page) -> some View {
        switch page {
        case .welcome: welcomePage
        case .health: healthPage
        case .export: exportPage
        case .sync: syncPage
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        pageLayout {
            VStack(spacing: 28) {
                // The app's own mark (Assets.xcassets/Logo, the SVG the site
                // uses, rendered as a template so it takes the tint).
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                pageTitle("Unlock your Health Data", font: .largeTitle.bold())
                VStack(alignment: .leading, spacing: 18) {
                    feature(
                        "heart.text.square", "Explore",
                        "See what Apple Health holds, how much, and where it came from.")
                    feature(
                        "square.and.arrow.up", "Export",
                        "Save any of it to CSV or JSONL files.")
                    feature(
                        "arrow.triangle.2.circlepath", "Sync",
                        "Keep a live copy in your own database.")
                }
            }
        }
    }

    private var healthPage: some View {
        pageLayout {
            VStack(spacing: 20) {
                pageIcon("heart.text.square", color: .pink)
                pageTitle("Which Health data would you like to use?")
                bodyText("iOS asks which data PulsHealth may read. Pick what you like. You can always add more later in the app.")
                if let hint = model.authorizationHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if healthSettled {
                    // Deliberately not "access granted": HealthKit never tells
                    // an app whether a read request was granted, only that
                    // iOS has asked.
                    Label("iOS has already asked about this data.", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            // App Review 5.1.1(iv): the one button on a pre-permission screen
            // is a neutral Continue, and it leads to the sheet.
            primaryButton("Continue", busy: requestingHealthAccess) { continueFromHealth() }
        }
    }

    private var exportPage: some View {
        pageLayout {
            VStack(spacing: 24) {
                pageIcon("square.and.arrow.up", color: .accentColor)
                pageTitle("Export your data")
                bodyText("Make a one-time export of any of your Health data, as CSV or JSONL files.")
                VStack(alignment: .leading, spacing: 18) {
                    feature(
                        "list.bullet.rectangle", "Raw samples",
                        "Every reading, as it was recorded.")
                    feature(
                        "chart.bar.xaxis", "Aggregates",
                        "Hourly or daily summaries, like steps per day.")
                }
            }
        }
    }

    private var syncPage: some View {
        pageLayout {
            VStack(spacing: 20) {
                pageIcon("arrow.triangle.2.circlepath", color: .accentColor)
                pageTitle("Sync to your own database")
                bodyText("Keep a live copy of your Health data in a database you control. Connect your own, or set up the open-source PulsHealth example.")
                // Opens in Safari, outside the app.
                Link(destination: URL(string: "https://pulshealth.com/docs/server/")!) {
                    Label("Learn more", systemImage: "arrow.up.right.square")
                }
                if model.confirmedPairing != nil {
                    // Accepted during the flow; Sync → Database opens with it
                    // filled in once the flow is done (RootView, on
                    // `pairingAwaitsSyncTab`).
                    Label("A pairing link is waiting. The Sync tab opens with it filled in when you finish.", systemImage: "qrcode")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            primaryButton("Start Exploring", busy: finishing) { finish() }
        }
    }

    // MARK: - Building blocks

    private var logoSize: CGFloat { sizeClass == .regular ? 128 : 104 }

    /// Content centred in the page, scrolling when it does not fit (large
    /// text sizes, iPad landscape), with the page's button, if it has one,
    /// pinned below it.
    private func pageLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        pageLayout(content: content) { EmptyView() }
    }

    private func pageLayout<Content: View, Footer: View>(
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) -> some View {
        let pageContent = content()
        return VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    pageContent
                        .frame(maxWidth: maxContentWidth)
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            footer()
                .frame(maxWidth: maxContentWidth)
                .padding(.horizontal, 24)
        }
    }

    // Multi-line text says so (`fixedSize`): without it a title that needs
    // two lines was cut to one with an ellipsis.

    private func pageTitle(_ text: String, font: Font = .title.bold()) -> some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pageIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 56))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func primaryButton(_ title: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                // The title keeps the button's size while the spinner shows.
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView() }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(requestingHealthAccess || finishing)
        .accessibilityLabel(title)
    }

    private var pageDots: some View {
        let current = page ?? .welcome
        return HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.self) { each in
                Capsule()
                    .fill(each == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: each == current ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Page \(current.rawValue + 1) of \(Page.allCases.count)")
    }

    // MARK: - Actions

    /// Continue on page 2, or a swipe forward there. Presents iOS's sheet
    /// for whatever is still undetermined, then moves on — after Allow,
    /// Don't Allow, or iOS 27's Don't Allow on the history page, which the
    /// model takes as an answer. Already settled: just the next page.
    private func continueFromHealth() {
        guard !requestingHealthAccess, !finishing else { return }
        guard !healthSettled else {
            withAnimation { page = .export }
            return
        }
        requestingHealthAccess = true
        Task {
            await model.requestOnboardingHealthAccess()
            requestingHealthAccess = false
            // Pages 3 and 4 join the pager first, then it moves to page 3.
            healthSettled = true
            try? await Task.sleep(for: .milliseconds(50))
            // Only if still on page 2: someone who swiped back to page 1
            // while the sheet came up stays there.
            if page == .health {
                withAnimation { page = .export }
            }
        }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        Task {
            await model.finishOnboarding()
            finishing = false
        }
    }
}

// MARK: - Pull past the last page

private extension View {
    /// Calls `action` when the person drags a horizontal scroll view past
    /// its trailing end and lets go — a swipe forward on its last page.
    /// Needs iOS 18's scroll geometry and phases; on iOS 17 the pull only
    /// bounces, and the page's own button is the way on.
    @ViewBuilder func onPullPastEnd(enabled: Bool, perform action: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            modifier(PullPastEndModifier(enabled: enabled, action: action))
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct PullPastEndModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    /// Set while a drag has stretched far enough past the end to count.
    @State private var pulled = false

    /// How far past the end, in points, a drag has to stretch: more than a
    /// nudge, less than a deliberate swipe.
    private static let threshold: CGFloat = 40

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.maxX - geometry.contentSize.width
            } action: { _, beyondEnd in
                if beyondEnd > Self.threshold { pulled = true }
            }
            .onScrollPhaseChange { old, new in
                // The finger lifted: a pull that went far enough asks.
                guard old == .interacting, new != .interacting else { return }
                if pulled, enabled { action() }
                pulled = false
            }
    }
}
