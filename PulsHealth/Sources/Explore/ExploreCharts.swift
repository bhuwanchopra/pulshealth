import Charts
import PulsHealthSync
import SwiftUI

// The Explore tab's charts. One series each, in the type's category colour;
// grey for reference bands; readouts through `ChartCard`, never on the plot.

/// A number in a type's unit, with as many decimals as its size warrants.
func formatValue(_ value: Double) -> String {
    let magnitude = abs(value)
    if magnitude >= 1_000 { return value.formatted(.number.precision(.fractionLength(0))) }
    if magnitude >= 10 { return value.formatted(.number.precision(.fractionLength(0...1))) }
    return value.formatted(.number.precision(.fractionLength(0...2)))
}

// MARK: - Value distribution

/// Fixed-width bins as columns; the knowledge base's typical range as a
/// grey band behind them, when the article has one that overlaps. The bins
/// cover the middle of the data (`TypeProfile.Histogram.belowCount` and
/// `aboveCount` are what they leave out), so the axis is the histogram's
/// bounds, never min…max.
struct HistogramChart: View {
    let histogram: TypeProfile.Histogram
    let unit: String?
    let color: Color
    var typicalRange: ClosedRange<Double>?
    /// Drawn as a dashed rule so the eye has a reference on the value axis.
    var median: Double?
    @State private var selection: Double?
    /// Spelled-out selection for the card's readout line.
    @Binding var readout: String?

    private struct Bin: Identifiable {
        let id: Int
        let lower: Double
        let upper: Double
        let count: Int
    }

    private var bins: [Bin] {
        let width = (histogram.upperBound - histogram.lowerBound) / Double(max(histogram.binCount, 1))
        return histogram.counts.enumerated().map { index, count in
            Bin(
                id: index,
                lower: histogram.lowerBound + Double(index) * width,
                upper: histogram.lowerBound + Double(index + 1) * width,
                count: count)
        }
    }

    private var selectedBin: Bin? {
        guard let selection else { return nil }
        return bins.first { selection >= $0.lower && selection < $0.upper }
            ?? (selection == histogram.upperBound ? bins.last : nil)
    }

    private var computedReadout: String? {
        guard let bin = selectedBin else { return nil }
        let unitText = unit.map { " \($0)" } ?? ""
        return "\(formatValue(bin.lower)) to \(formatValue(bin.upper))\(unitText) · \(bin.count.formatted()) samples"
    }

    var body: some View {
        let band = typicalRange.map {
            max($0.lowerBound, histogram.lowerBound)...min($0.upperBound, histogram.upperBound)
        }
        Chart {
            if let band, band.lowerBound < band.upperBound {
                RectangleMark(xStart: .value("From", band.lowerBound), xEnd: .value("To", band.upperBound))
                    .foregroundStyle(.gray.opacity(0.15))
            }
            ForEach(bins) { bin in
                // A rectangle from zero, not a BarMark with xStart/xEnd —
                // that one is an interval bar floating at y.
                RectangleMark(
                    xStart: .value("From", bin.lower), xEnd: .value("To", bin.upper),
                    yStart: .value("Samples", 0), yEnd: .value("Samples", bin.count))
                .foregroundStyle(selectedBin == nil || selectedBin?.id == bin.id ? color : color.opacity(0.4))
            }
            if let median {
                RuleMark(x: .value("Median", median))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    // Kept inside the plot: a median in the first bin would
                    // otherwise hang its label off the chart's leading edge.
                    .annotation(
                        position: .top, alignment: .center, spacing: 2,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        Text("median")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartXSelection(value: $selection)
        .onChange(of: selection) { readout = computedReadout }
        .chartXScale(domain: histogram.lowerBound...max(histogram.upperBound, histogram.lowerBound.nextUp))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(formatValue(number))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: IntegerFormatStyle<Int>.number.notation(.compactName))
            }
        }
        .chartXAxisLabel(unit ?? "", alignment: .trailing)
        .chartYAxisLabel("Samples")
        .frame(height: 200)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let peak = bins.max(by: { $0.count < $1.count }) else { return "Empty histogram" }
        let outside = histogram.belowCount + histogram.aboveCount
        return "Value histogram, \(bins.count) bins from \(formatValue(histogram.lowerBound)) to "
            + "\(formatValue(histogram.upperBound)) \(unit ?? ""); most samples between "
            + "\(formatValue(peak.lower)) and \(formatValue(peak.upper))"
            + (outside > 0 ? "; \(outside.formatted()) samples outside the axis" : "")
    }
}

// MARK: - Label shares

/// One bar per label, drawn as list rows rather than a plotted axis: the
/// label and its number on one line, a proportional bar under them, and any
/// detail (a description, a date range) under that. Every row gets the
/// full width for its text, so nothing truncates at any Dynamic Type size,
/// and a row with nothing in it is drawn as an empty track rather than
/// dropped — a category type shows every value HealthKit defines.
struct ShareBars: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        /// The bar's length, relative to the largest row.
        let measure: Double
        /// The number beside the label: a count, a duration, both.
        let measureText: String
        /// Small print under the bar: a description, a date range.
        var detail: String?
        /// A short tag after the label: the raw value, a "deprecated" note.
        var tag: String?

        init(
            id: String? = nil, label: String, measure: Double, measureText: String,
            detail: String? = nil, tag: String? = nil
        ) {
            self.id = id ?? label
            self.label = label
            self.measure = measure
            self.measureText = measureText
            self.detail = detail
            self.tag = tag
        }
    }

    let rows: [Row]
    let color: Color
    /// The bar is a share of this; the largest row by default, so the widest
    /// bar spans the card. Pass the total for bars that read as fractions of
    /// the whole.
    var scale: Double?

    private var denominator: Double {
        max(scale ?? rows.map(\.measure).max() ?? 1, .leastNonzeroMagnitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(row.measure > 0 ? .primary : .secondary)
                        if let tag = row.tag {
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        Text(row.measureText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Bar(fraction: row.measure / denominator, color: color)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.label): \(row.measureText)")
            }
        }
        .padding(.vertical, 2)
    }

    private struct Bar: View {
        let fraction: Double
        let color: Color

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    if fraction > 0 {
                        // At least a dot, so a tiny share is not invisible.
                        Capsule()
                            .fill(color)
                            .frame(width: max(8, geometry.size.width * min(fraction, 1)))
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

/// A duration the way the type pages say it: "7 h 20 min", "3 d 4 h", "45 s".
func durationString(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(format: "%.0f s", seconds) }
    let formatter = seconds >= 86_400 ? durationFormatterDays : durationFormatterHours
    return formatter.string(from: seconds) ?? ""
}

private let durationFormatterHours: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.maximumUnitCount = 2
    formatter.unitsStyle = .abbreviated
    return formatter
}()

private let durationFormatterDays: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour]
    formatter.maximumUnitCount = 2
    formatter.unitsStyle = .abbreviated
    return formatter
}()

// MARK: - Samples over time

/// The spans the Samples over time card offers. A profile covers the past
/// year (`ExploreModel.profileOptions`), so a year is the most it can show.
enum TimeWindow: String, CaseIterable, Identifiable {
    case month = "30 d"
    case year = "1 y"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .month: 30 * 86_400
        case .year: 365 * 86_400
        }
    }
}

/// Samples over time as columns: a bar a day for 30 days, scrolling back
/// through the year, or a bar a week for the whole year (a bar a day over
/// a year is a row of hairlines). The axis is marked for the window with no more labels than
/// fit side by side: every seven days back from the newest, "Sep 23" beside
/// the mark, for 30 days; each month's letter under its middle for the
/// year, with January labelled by its year instead.
struct DailyCountsChart: View {
    let dailyCounts: [TypeProfile.DailyCount]
    let window: TimeWindow
    let color: Color
    @State private var selection: Date?
    @State private var scrollPosition = Date()
    @Binding var readout: String?

    /// The bar width: a day, or a week for the year.
    private var grain: Calendar.Component { window == .year ? .weekOfYear : .day }

    private var buckets: [TypeProfile.DailyCount] {
        let grain = grain
        guard grain != .day else { return dailyCounts }
        let calendar = Calendar.current
        var sums: [Date: Int] = [:]
        for entry in dailyCounts {
            let key = calendar.dateInterval(of: grain, for: entry.day)?.start ?? entry.day
            sums[key, default: 0] += entry.count
        }
        return sums.keys.sorted().map { TypeProfile.DailyCount(day: $0, count: sums[$0] ?? 0) }
    }

    /// What the chart spans: through the close of the newest day (30 d) or
    /// month (1 y), so it opens on the newest data with its trailing edge on
    /// a boundary, and at least a window long, so a short history sits at the
    /// right of an empty window instead of being stretched across it.
    private func domain(of buckets: [TypeProfile.DailyCount]) -> ClosedRange<Date>? {
        guard let first = buckets.first?.day, let last = dailyCounts.last?.day else { return nil }
        let end = Calendar.current.dateInterval(of: window == .year ? .month : .day, for: last)?.end ?? last
        return min(first, end.addingTimeInterval(-window.seconds))...end
    }

    /// The grid lines across `range`: every seven days back from its end
    /// (so the newest mark has a week of room for its label rather than
    /// hanging it off the edge), or every month start.
    private func ticks(over range: ClosedRange<Date>) -> [Date] {
        let calendar = Calendar.current
        var result: [Date] = []
        if window == .month {
            var date = calendar.date(byAdding: .day, value: -7, to: range.upperBound)
            while let current = date, current >= range.lowerBound {
                result.append(current)
                date = calendar.date(byAdding: .day, value: -7, to: current)
            }
            return result.reversed()
        }
        var date = calendar.dateInterval(of: .month, for: range.lowerBound)?.start
        while let current = date, current < range.upperBound {
            if current >= range.lowerBound { result.append(current) }
            date = calendar.date(byAdding: .month, value: 1, to: current)
        }
        return result
    }

    /// The middle of the month that starts at `start`.
    private static func midMonth(_ start: Date) -> Date {
        guard let month = Calendar.current.dateInterval(of: .month, for: start) else { return start }
        return month.start.addingTimeInterval(month.duration / 2)
    }

    private func tickLabel(_ date: Date) -> String {
        if window == .month { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return Calendar.current.component(.month, from: date) == 1
            ? date.formatted(.dateTime.year()) : date.formatted(.dateTime.month(.narrow))
    }

    private var selected: TypeProfile.DailyCount? {
        guard let selection else { return nil }
        let calendar = Calendar.current
        return buckets.first { calendar.isDate($0.day, equalTo: selection, toGranularity: grain) }
    }

    private var computedReadout: String? {
        guard let selected else { return nil }
        let date = selected.day.formatted(date: .abbreviated, time: .omitted)
        return "\(window == .year ? "Week of " + date : date) · \(selected.count.formatted()) samples"
    }

    var body: some View {
        let buckets = buckets
        let domain = domain(of: buckets)
        let ticks = domain.map { self.ticks(over: $0) } ?? []
        // A month's label sits under the middle of its month; a week's starts
        // at its mark. (Not `AxisValueLabel(centered:)`: it centres between a
        // mark and the next, and the newest month has no next.)
        let labels = window == .year ? ticks.map(Self.midMonth) : ticks
        Chart(buckets, id: \.day) { entry in
            BarMark(
                x: .value("Date", entry.day, unit: grain),
                y: .value("Samples", entry.count))
            .foregroundStyle(
                selected == nil || selected?.day == entry.day ? color : color.opacity(0.4))
        }
        .chartXSelection(value: $selection)
        .onChange(of: selection) { readout = computedReadout }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: IntegerFormatStyle<Int>.number.notation(.compactName))
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine()
            }
            AxisMarks(values: labels) { value in
                // Greedy drops a label that would run into its neighbour,
                // which the largest text sizes can still make happen.
                AxisValueLabel(anchor: window == .year ? .top : .topLeading, collisionResolution: .greedy) {
                    if let date = value.as(Date.self) {
                        Text(tickLabel(date))
                    }
                }
            }
        }
        // No "Samples" axis title: a scrolling chart does not keep it in
        // view, and the card's title says it.
        .frame(height: 200)
        .modifier(WindowScroll(window: window, domain: domain, position: $scrollPosition))
        .accessibilityLabel(accessibilityText)
        .onAppear { showNewest() }
        .onChange(of: window) { showNewest() }
    }

    /// Land on the newest data, not on the oldest.
    private func showNewest() {
        if let end = domain(of: buckets)?.upperBound {
            scrollPosition = end.addingTimeInterval(-window.seconds)
        }
    }

    private var accessibilityText: String {
        let total = dailyCounts.reduce(0) { $0 + $1.count }
        return "Samples over time: \(total.formatted()) samples across \(dailyCounts.count.formatted()) days"
    }

    /// The 30 d window scrolls back through the year; the year is the whole
    /// analysis and fits. No `chartScrollTargetBehavior`: snapping to month
    /// starts opened a window a month short of the newest data.
    private struct WindowScroll: ViewModifier {
        let window: TimeWindow
        let domain: ClosedRange<Date>?
        @Binding var position: Date

        func body(content: Content) -> some View {
            if let domain, window == .month {
                content
                    .chartXScale(domain: domain)
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: window.seconds)
                    .chartScrollPosition(x: $position)
            } else if let domain {
                content.chartXScale(domain: domain)
            } else {
                content
            }
        }
    }
}

// MARK: - Aggregate preview

/// The buckets a configured series would produce: a line for the discrete
/// functions, columns for the cumulative ones (a sum is an amount per
/// bucket; an average is a level).
struct AggregatePreviewChart: View {
    let buckets: [HealthExplorer.AggregateBucket]
    let function: AggregateFunction
    let unit: String?
    let color: Color
    @State private var selection: Date?
    @Binding var readout: String?

    private var isColumn: Bool { function == .sum || function == .duration }

    private var selected: HealthExplorer.AggregateBucket? {
        guard let selection else { return nil }
        return buckets.first { selection >= $0.start && selection < $0.end }
    }

    private var computedReadout: String? {
        guard let selected else { return nil }
        let when = selected.start.formatted(date: .abbreviated, time: .shortened)
        guard let value = selected.value else { return "\(when) · no data" }
        return "\(when) · \(formatValue(value)) \(unit ?? "")"
    }

    var body: some View {
        Chart {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                if let value = bucket.value {
                    if isColumn {
                        BarMark(
                            xStart: .value("From", bucket.start), xEnd: .value("To", bucket.end),
                            y: .value(function.displayName, value))
                        .foregroundStyle(
                            selected == nil || selected?.start == bucket.start ? color : color.opacity(0.4))
                    } else {
                        AreaMark(x: .value("Time", bucket.start), y: .value(function.displayName, value))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [color.opacity(0.25), color.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", bucket.start), y: .value(function.displayName, value))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            if let selected, let value = selected.value {
                if isColumn {
                    RuleMark(x: .value("Time", selected.start))
                        .foregroundStyle(.secondary.opacity(0.4))
                } else {
                    RuleMark(x: .value("Time", selected.start))
                        .foregroundStyle(.secondary.opacity(0.4))
                    PointMark(x: .value("Time", selected.start), y: .value(function.displayName, value))
                        .foregroundStyle(color)
                        .symbolSize(64)
                }
            }
        }
        .chartXSelection(value: $selection)
        .onChange(of: selection) { readout = computedReadout }
        // A level (average, min, max) reads better on a scale that fits it;
        // an amount per bucket (sum, duration) must start at zero.
        .chartYScale(domain: .automatic(includesZero: isColumn))
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(formatValue(number))
                    }
                }
            }
        }
        .chartYAxisLabel(unit ?? "")
        .frame(height: 200)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let values = buckets.compactMap(\.value)
        guard let low = values.min(), let high = values.max() else {
            return "\(function.displayName): no data in this window"
        }
        return "\(function.displayName) over \(buckets.count) buckets, from \(formatValue(low)) to "
            + "\(formatValue(high)) \(unit ?? ""), \(buckets.count - values.count) empty"
    }
}
