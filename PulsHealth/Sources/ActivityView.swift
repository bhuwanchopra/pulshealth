import SwiftUI

/// Sync → Activity: the event log and the background-wake study, one segment
/// each. Both screens keep their own trailing toolbar item (the log's filter
/// menu, the wake study's diagnostics share) — only one is in the hierarchy
/// at a time, so they never collide — and this view supplies the title and
/// the switch in the principal slot.
struct ActivityView: View {
    private enum Segment: Hashable { case log, background }
    @State private var segment: Segment = .log

    var body: some View {
        Group {
            switch segment {
            case .log: LogView()
            case .background: BackgroundActivityView()
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Activity", selection: $segment) {
                    Text("Log").tag(Segment.log)
                    Text("Background").tag(Segment.background)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
        }
    }
}
