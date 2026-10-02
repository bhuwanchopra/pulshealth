import SwiftUI

/// A `CardSection` that holds a chart: the title, an optional control row
/// above the plot (a window picker, a toggle), the plot itself at a height
/// that stays readable at every Dynamic Type size, and a readout line under
/// it in tabular digits, so every chart in the app is framed the same way.
///
/// The readout is where a selection is spelled out — a chart's tooltip, in
/// a form VoiceOver reads and a finger does not cover.
struct ChartCard<Controls: View, Chart: View>: View {
    let title: String
    var subtitle: String?
    /// The selection or summary under the plot; shown greyed when nil so the
    /// card does not jump when a selection begins.
    var readout: String?
    var placeholder = "Touch the chart for values"
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let chart: () -> Chart

    init(
        _ title: String, subtitle: String? = nil, readout: String? = nil,
        placeholder: String = "Touch the chart for values",
        @ViewBuilder controls: @escaping () -> Controls,
        @ViewBuilder chart: @escaping () -> Chart
    ) {
        self.title = title
        self.subtitle = subtitle
        self.readout = readout
        self.placeholder = placeholder
        self.controls = controls
        self.chart = chart
    }

    var body: some View {
        CardSection(title, subtitle: subtitle) {
            controls()
            // One container, so a chart slot holding a plot and a note is
            // sized once rather than each child getting the minimum.
            VStack(alignment: .leading, spacing: 8) { chart() }
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(readout ?? placeholder)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(readout == nil ? .tertiary : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ChartCard where Controls == EmptyView {
    init(
        _ title: String, subtitle: String? = nil, readout: String? = nil,
        placeholder: String = "Touch the chart for values",
        @ViewBuilder chart: @escaping () -> Chart
    ) {
        self.init(
            title, subtitle: subtitle, readout: readout, placeholder: placeholder,
            controls: { EmptyView() }, chart: chart)
    }
}
