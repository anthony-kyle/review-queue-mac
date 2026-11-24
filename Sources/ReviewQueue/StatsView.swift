import Charts
import ReviewQueueCore
import SwiftUI

/// The review statistics window, scrolling when it is shorter than its content. Opening it reads the cached history and
/// refreshes it when stale.
struct StatsView: View {
    nonisolated static let windowId = "stats"

    let model: AppModel

    var body: some View {
        ScrollView {
            StatsContent(model: model)
        }
        .frame(minWidth: StatsContent.width, minHeight: 560)
        .onAppear {
            model.refreshHistoryIfStale()
            model.refreshSprintCycles()
        }
    }
}

/// Header with refresh and progress, the selected period's graph, the period picker, your metrics against the team's,
/// and one panel below them: the trend or the leaderboard, as saved in Settings, with the trend's metric menu beside
/// the switch. Until a period is picked it follows the default: Sprint while it is offered and a cycle is running, else
/// Month, so it switches to Sprint once cycles arrive. Sprint is only listed while offered.
struct StatsContent: View {
    static let width: CGFloat = 900

    let model: AppModel
    @State private var picked: StatsPeriod?
    @State private var offset = 0
    @State private var trendCache: TrendCache?
    @State private var indexCache: IndexCache?
    @State private var trendMetric = StatsMetric.reviews

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let isSprintOffered = model.isSprintOffered
        let cycles = isSprintOffered ? model.sprintCycles : []
        let fallback = defaultPeriod(isSprintOffered: isSprintOffered, cycles: cycles, now: now)
        let period = picked.flatMap { $0 != .sprint || isSprintOffered ? $0 : nil } ?? fallback
        let indexKey = IndexKey(
            prs: model.history.prs.count,
            completedAt: model.history.completedAt,
            me: model.history.me,
            allowedBots: model.settings.allowedBotAuthors,
            hour: Int(now.timeIntervalSince1970 / 3600)
        )
        let index = indexCache.flatMap { $0.key == indexKey ? $0.index : nil }
            ?? StatsIndex(history: model.history.counted(model.settings), now: now, calendar: calendar)
        let report = StatsReport(index: index, period: period, offset: offset, cycles: cycles)
        let title = periodTitle(report.span, period: period, calendar: calendar)
        let trendKey = TrendKey(period: period, offset: offset, cycles: cycles.map(\.id), index: indexKey)
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.settings.teams.isEmpty {
                Text("Choose the GitHub teams whose PRs you review in Settings to see review statistics.").foregroundStyle(.secondary)
            }
            if !model.isHistoryLoading, let note = model.historyNote {
                ErrorBanner(message: "GitHub: \(note)", color: .orange)
            }
            PeriodGraphView(graph: report.graph, title: title, calendar: calendar)
            periodBar(report, period: period, title: title, isSprintOffered: isSprintOffered)
            if model.settings.sprintTeam != nil, let note = model.sprintNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(StatsMetric.allCases.filter(\.isRanked)) { metric in
                    MetricCard(metric: metric, mine: report.mine, benchmark: report.benchmark(metric))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Panel", selection: settingsBinding(model, \.statsPanel)) {
                        ForEach(StatsPanel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    Spacer()
                    if model.settings.statsPanel == .trend {
                        Picker("Metric", selection: $trendMetric) {
                            ForEach(StatsMetric.allCases) { Text($0.trendTitle).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                switch model.settings.statsPanel {
                case .trend:
                    TrendView(points: trendCache?.points ?? [], metric: trendMetric, period: period, calendar: calendar, now: now)
                case .leaderboard:
                    LeaderboardView(rows: report.rows, me: report.me)
                }
            }
        }
        .padding(24)
        .onChange(of: isSprintOffered) { offset = 0 }
        .task(id: indexKey) {
            if indexCache?.key != indexKey { indexCache = IndexCache(key: indexKey, index: index) }
        }
        .task(id: trendKey) {
            trendCache = TrendCache(key: trendKey, points: trend(period, endingAt: offset, index: index, cycles: cycles))
        }
        .frame(minWidth: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review statistics").font(.title2.weight(.semibold))
                Text(status).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await model.refreshHistory() } }
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.isHistoryLoading)
                .disabled(model.isHistoryLoading || model.settings.teams.isEmpty)
        }
    }

    private var status: String {
        if model.isHistoryLoading {
            let total = model.historyReposTotal
            return total == 0 ? "Finding your teams' repos…" : "Loading history… \(model.historyReposDone) of \(counted(total, "repo"))"
        }
        guard let completedAt = model.history.completedAt else { return "Not loaded yet" }
        return "Your teams' repos · updated \(clockTime(completedAt))"
    }

    private func periodBar(_ report: StatsReport, period: StatsPeriod, title: String, isSprintOffered: Bool) -> some View {
        HStack(spacing: 10) {
            Picker("Period", selection: Binding(get: { period }, set: { picked = $0; offset = 0 })) {
                ForEach(StatsPeriod.allCases.filter { $0 != .sprint || isSprintOffered }) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: isSprintOffered ? 400 : 320)
            Spacer()
            IconButton(symbol: "chevron.left", help: "Previous \(period.label.lowercased())") { offset -= 1 }
                .disabled(!report.span.canGoBack)
            Text(title)
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 190)
            IconButton(symbol: "chevron.right", help: "Next \(period.label.lowercased())") { offset += 1 }
                .disabled(!report.span.canGoForward)
        }
    }
}

/// The selected span as the period bar and graph header name it: a cycle with its dates, a week's dates, a month,
/// a quarter or a year.
private func periodTitle(_ span: PeriodSpan, period: StatsPeriod, calendar: Calendar) -> String {
    let start = span.interval.start
    let last = calendar.date(byAdding: .day, value: -1, to: span.interval.end) ?? start
    if let cycle = span.cycle {
        return "\(cycle.title) · \((start..<max(start, last)).formatted(.interval.day().month(.abbreviated)))"
    }
    switch period {
    case .week:
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    case .sprint, .month:
        return start.formatted(.dateTime.month(.wide).year())
    case .quarter:
        return "Q\(quarter(of: start, calendar: calendar)) \(start.formatted(.dateTime.year()))"
    case .year:
        return start.formatted(.dateTime.year())
    }
}

private func quarter(of date: Date, calendar: Calendar) -> Int {
    (calendar.component(.month, from: date) - 1) / 3 + 1
}

/// A span's short name for the trend's x-axis: `C42`, `23 Nov`, `Nov`, `Q4` or `2026`.
private func axisLabel(_ span: PeriodSpan, period: StatsPeriod, calendar: Calendar) -> String {
    let start = span.interval.start
    if let cycle = span.cycle { return "C\(cycle.number)" }
    switch period {
    case .week: return start.formatted(.dateTime.day().month(.abbreviated))
    case .sprint, .month: return start.formatted(.dateTime.month(.abbreviated))
    case .quarter: return "Q\(quarter(of: start, calendar: calendar))"
    case .year: return start.formatted(.dateTime.year())
    }
}

/// What the stats index depends on, so it is built once per change of history, allowed bots or hour (which moves
/// pending requests past their deadlines) rather than on every render.
private struct IndexKey: Hashable {
    let prs: Int
    let completedAt: Date?
    let me: String?
    let allowedBots: [String]
    let hour: Int
}

private struct IndexCache {
    let key: IndexKey
    let index: StatsIndex
}

/// What the trend depends on, so it is computed once per change of period, offset, cycles or index rather than on every
/// render.
private struct TrendKey: Hashable {
    let period: StatsPeriod
    let offset: Int
    let cycles: [String]
    let index: IndexKey
}

private struct TrendCache {
    let key: TrendKey
    let points: [PeriodStats]
}

/// One period's metric for the trend chart: your value (nil leaves a gap) and the team median, both in the chart's
/// units, which are hours for response time, and the team's backlog of PRs waiting for review when it ended.
private struct TrendPoint: Identifiable {
    let id: Int
    let stats: PeriodStats
    let mine: Double?
    let median: Double?
    let run: Int
    let isPartial: Bool

    var waiting: Int { stats.waiting }
}

/// The chosen metric over the trend's periods: you as a solid line with points, broken where you have no value, and
/// the team median dashed, on the left axis. The team's PRs waiting for review at each period's end are a thin orange
/// line on the right axis: Swift Charts has one y scale, so the counts are scaled to fill the metric's range and the
/// right axis labels them back in PRs. The last point is the selected period, drawn larger; a period still running is
/// hollow and reads "so far". Hovering shows the period, your value, the median and the backlog. Fixed height, so it
/// never sizes the window.
private struct TrendView: View {
    private static let you = Color.green
    private static let backlog = Color.orange
    private static let hour: Double = 3600

    let points: [PeriodStats]
    let metric: StatsMetric
    let period: StatsPeriod
    let calendar: Calendar
    let now: Date
    @State private var selected: Int?

    var body: some View {
        let data = trendPoints
        VStack(alignment: .leading, spacing: 10) {
            chart(data).frame(height: 180)
            HStack(spacing: 16) {
                legendItem("You", color: Self.you, width: 2.5)
                legendItem("Team median", color: .secondary, width: 1.5, dash: [5, 4])
                legendItem("Open PRs waiting for review (right axis)", color: Self.backlog, width: 1.5)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var trendPoints: [TrendPoint] {
        var run = 0
        var wasGap = false
        return points.enumerated().map { index, stats in
            let mine = stats.mine.flatMap(metric.value).map(plotted)
            if mine == nil { wasGap = true } else if wasGap { run += 1; wasGap = false }
            return TrendPoint(
                id: index,
                stats: stats,
                mine: mine,
                median: stats.benchmark(metric).median.map(plotted),
                run: run,
                isPartial: stats.isPartial(now: now)
            )
        }
    }

    private func plotted(_ value: Double) -> Double {
        metric == .ownSpeed ? value / Self.hour : value
    }

    /// The factor that stretches backlog counts over the metric's range, so both lines use the chart's height.
    private func backlogScale(_ data: [TrendPoint]) -> Double {
        let metricMax = data.flatMap { [$0.mine, $0.median] }.compactMap(\.self).max() ?? 0
        let waitingMax = data.map(\.waiting).max() ?? 0
        return max(metricMax, 1) / Double(max(waitingMax, 1))
    }

    /// Whole-PR ticks for the right axis: about four steps from zero to the largest backlog.
    private func backlogTicks(_ data: [TrendPoint]) -> [Int] {
        let waitingMax = max(data.map(\.waiting).max() ?? 0, 1)
        let step = max(1, Int((Double(waitingMax) / 4).rounded(.up)))
        return Array(stride(from: 0, through: waitingMax, by: step))
    }

    private func chart(_ data: [TrendPoint]) -> some View {
        let scale = backlogScale(data)
        return Chart {
            ForEach(data) { point in
                LineMark(x: .value("Period", point.id), y: .value("Value", Double(point.waiting) * scale), series: .value("Series", "waiting"))
                    .foregroundStyle(Self.backlog)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(data) { point in
                if let median = point.median {
                    LineMark(x: .value("Period", point.id), y: .value("Value", median), series: .value("Series", "median"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            ForEach(data) { point in
                if let mine = point.mine {
                    let isLast = point.id == data.count - 1
                    LineMark(x: .value("Period", point.id), y: .value("Value", mine), series: .value("Series", "you \(point.run)"))
                        .foregroundStyle(Self.you)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("Period", point.id), y: .value("Value", mine))
                        .symbol {
                            Circle()
                                .fill(point.isPartial ? Color.clear : Self.you)
                                .stroke(Self.you, lineWidth: 2)
                                .frame(width: isLast ? 12 : 8, height: isLast ? 12 : 8)
                        }
                }
            }
            if let selected, data.indices.contains(selected) {
                RuleMark(x: .value("Period", selected))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(data[selected])
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: -0.5...(Double(max(data.count, 1)) - 0.5))
        .chartXAxis {
            AxisMarks(values: data.map(\.id)) { value in
                AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let index = value.as(Int.self), data.indices.contains(index) {
                        Text(axisLabel(data[index].stats.span, period: period, calendar: calendar))
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .ownSpeed ? compactDuration(number * Self.hour) : metric.format(number))
                    }
                }
            }
            AxisMarks(position: .trailing, values: backlogTicks(data).map { Double($0) * scale }) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(Int((number / scale).rounded()))").foregroundStyle(Self.backlog)
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
    }

    private func tooltip(_ point: TrendPoint) -> some View {
        let unplot = { (value: Double?) in value.map { self.metric == .ownSpeed ? $0 * Self.hour : $0 } }
        return VStack(alignment: .leading, spacing: 2) {
            Text(periodTitle(point.stats.span, period: period, calendar: calendar)).font(.caption.weight(.semibold))
            Text("You: \(metric.format(unplot(point.mine)))\(point.isPartial ? " so far" : "")")
            Text("Team median: \(metric.format(unplot(point.median)))")
            Text("Waiting for review: \(point.waiting)\(point.isPartial ? " now" : "")")
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func legendItem(_ name: String, color: Color, width: CGFloat, dash: [CGFloat] = []) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 22, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, dash: dash))
            .frame(width: 22, height: 8)
            Text(name)
        }
    }
}

/// A circular bordered icon button for the statistics window, an ordinary opaque window where the menus' glass
/// `HeaderButton` has no glass container or backdrop to sample.
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Your reviews over the selected period: the period's total and the hovered day's count, the days as a calendar of
/// compact cells with the date top-left and the count bottom-right (Sprint, Week, Month) or a heatmap of small cells
/// with month labels (Quarter, Year), and the Less/More legend. The days sit in a block as tall as a six-week month,
/// so switching period never moves what is below. Future days are dim outlines; days outside the period are blank.
/// Sizes come from the window's minimum content width, never from a measurement, so the graph can't feed back into the
/// window's size.
private struct PeriodGraphView: View {
    private static let gap: CGFloat = 3
    private static let width = StatsContent.width - 48
    private static let rowLabelWidth: CGFloat = 30
    private static let dayWidth: CGFloat = 112
    private static let dayHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 16
    private static let blockHeight = headerHeight + gap + 6 * dayHeight + 5 * gap
    private static let heatmapCell: CGFloat = 26
    private static let swatch: CGFloat = 12
    private static let monthRow: CGFloat = 14

    let graph: PeriodGraph
    let title: String
    let calendar: Calendar
    @State private var hovered: GraphDay?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: DayPalette { DayPalette(isDark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(counted(graph.total, "review")) in \(title)").font(.headline)
                Spacer()
                if let hovered {
                    Text("\(counted(hovered.count, "review")) on \(hovered.date.formatted(date: .long, time: .omitted))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Group {
                switch graph.style {
                case .calendar: calendarGrid
                case .heatmap: heatmap
                }
            }
            .frame(height: Self.blockHeight, alignment: .top)
            legend
        }
    }

    private var calendarGrid: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                ForEach(graph.weekdays.indices, id: \.self) { index in
                    Text(graph.weekdays[index])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: Self.dayWidth)
                        .frame(height: Self.headerHeight)
                }
            }
            ForEach(graph.weeks.indices, id: \.self) { week in
                HStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { slot in
                        calendarDay(graph.weeks[week][slot])
                    }
                }
            }
        }
    }

    @ViewBuilder private func calendarDay(_ day: GraphDay?) -> some View {
        if let day {
            ZStack {
                Text("\(calendar.component(.day, from: day.date))")
                    .font(.caption2)
                    .foregroundStyle(day.isFuture ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if day.count > 0 {
                    Text("\(day.count)")
                        .font(.callout.weight(.bold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: Self.dayWidth)
            .frame(height: Self.dayHeight)
            .background(DayCell(level: day.level, isFuture: day.isFuture, palette: palette, cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { isInside in hovered = isInside && !day.isFuture ? day : nil }
        } else {
            Color.clear.frame(maxWidth: Self.dayWidth).frame(height: Self.dayHeight)
        }
    }

    /// The largest cell, up to the cap, that lets every week column fit the width and all seven rows fit the block.
    private var heatmapCellSize: CGFloat {
        let columns = CGFloat(max(graph.weeks.count, 1))
        let byWidth = ((Self.width - Self.rowLabelWidth - 6) / columns).rounded(.down) - Self.gap
        let byHeight = ((Self.blockHeight - Self.monthRow - 4) / 7).rounded(.down) - Self.gap
        return min(Self.heatmapCell, max(min(byWidth, byHeight), 6))
    }

    private var heatmap: some View {
        let cell = heatmapCellSize
        let step = cell + Self.gap
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: Self.gap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(row % 2 == 1 ? graph.weekdays[row] : "").frame(height: cell)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: Self.rowLabelWidth, alignment: .trailing)
            .padding(.top, Self.monthRow + 4)
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    ForEach(graph.months, id: \.column) { month in
                        Text(month.name).offset(x: CGFloat(month.column) * step)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: CGFloat(graph.weeks.count) * step, height: Self.monthRow, alignment: .topLeading)
                heatmapCanvas(cell: cell, step: step)
            }
        }
    }

    /// Every day drawn in one Canvas rather than a view per day, bordered when cells are big enough to show it; hovering
    /// reads the day under the pointer from its position.
    private func heatmapCanvas(cell: CGFloat, step: CGFloat) -> some View {
        let weeks = graph.weeks
        let palette = palette
        let radius = min(4, cell / 4)
        return Canvas { context, _ in
            for (column, days) in weeks.enumerated() {
                for (row, day) in days.enumerated() {
                    guard let day else { continue }
                    let rect = CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: cell, height: cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(palette.fill(day.level, isFuture: day.isFuture)))
                    if cell >= 8 || day.isFuture {
                        let border = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius, style: .continuous)
                        context.stroke(border, with: .color(palette.border(day.level, isFuture: day.isFuture)), lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: CGFloat(weeks.count) * step - Self.gap, height: 7 * step - Self.gap)
        .onContinuousHover { phase in
            guard case let .active(point) = phase else { return hovered = nil }
            let column = Int(point.x / step)
            let row = Int(point.y / step)
            let isOnCell = point.x.truncatingRemainder(dividingBy: step) < cell && point.y.truncatingRemainder(dividingBy: step) < cell
            let day = isOnCell && weeks.indices.contains(column) && (0..<7).contains(row) ? weeks[column][row] : nil
            hovered = day?.isFuture == false ? day : nil
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Spacer()
            Text("Less").padding(.trailing, 3)
            ForEach(0..<5, id: \.self) { level in
                DayCell(level: level, isFuture: false, palette: palette, cornerRadius: 3)
                    .frame(width: Self.swatch, height: Self.swatch)
            }
            Text("More").padding(.leading, 3)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The graph's ghost-style day colours: a dark green border at full strength over a fill whose opacity grows with the
/// level, a faint neutral cell for no reviews, and only a dim outline for a day still to come. The same colours draw
/// calendar cells, heatmap cells and the legend, in light and dark.
private struct DayPalette {
    let isDark: Bool

    private var green: Color {
        isDark ? Color(.sRGB, red: 0.18, green: 0.62, blue: 0.30) : Color(.sRGB, red: 0.10, green: 0.50, blue: 0.22)
    }

    func fill(_ level: Int, isFuture: Bool) -> Color {
        if isFuture { return .clear }
        guard level > 0 else { return Color.primary.opacity(0.05) }
        return green.opacity([0.12, 0.22, 0.33, 0.45][min(level, 4) - 1])
    }

    func border(_ level: Int, isFuture: Bool) -> Color {
        if isFuture { return Color.secondary.opacity(0.3) }
        return level > 0 ? green : Color.primary.opacity(0.12)
    }
}

/// One day cell's background in `palette`: its fill and a one-point border.
private struct DayCell: View {
    let level: Int
    let isFuture: Bool
    let palette: DayPalette
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(palette.fill(level, isFuture: isFuture))
            .overlay(shape.strokeBorder(palette.border(level, isFuture: isFuture), lineWidth: 1))
    }
}

/// One ranked metric: your value, the team median and your rank. Response rate also says how many requests you answered
/// within a business day, how many you missed or still have pending, and your own median time to respond, which is
/// never ranked.
private struct MetricCard: View {
    let metric: StatsMetric
    let mine: ReviewerStats?
    let benchmark: Benchmark

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(metric.title).font(.callout).foregroundStyle(.secondary)
            Text(mine.map(metric.text) ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if metric == .responseRate, let mine {
                Text("\(mine.onTime) of \(mine.onTime + mine.late + mine.missed) within 1 business day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Team median \(metric.format(benchmark.median))").font(.caption)
            Text(standing).font(.caption).foregroundStyle(.secondary)
            if metric == .responseRate, let mine {
                if mine.missed > 0 { Text("\(mine.missed) missed").font(.caption).foregroundStyle(.orange) }
                if mine.pending > 0 { Text("\(mine.pending) pending").font(.caption).foregroundStyle(.secondary) }
                Text("Your median: \(StatsMetric.ownSpeed.text(mine))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var standing: String {
        guard let rank = benchmark.rank, let top = benchmark.topPercent else {
            return metric == .responseRate ? "No requests due" : "No team to compare"
        }
        return "\(rankText(rank, of: benchmark.cohort)) · Top \(top)%"
    }
}

/// Everyone in the teams with the period's numbers, sortable by any column (click again to reverse), with your row
/// highlighted.
private struct LeaderboardView: View {
    private static let column: CGFloat = 96

    let rows: [ReviewerStats]
    let me: String?
    @State private var sort = StatsMetric.reviews
    @State private var isAscending = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("Reviewer").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(StatsMetric.allCases) { metric in
                    Button {
                        isAscending = metric == sort ? !isAscending : metric.isLowerBetter
                        sort = metric
                    } label: {
                        HStack(spacing: 4) {
                            Text(metric.title)
                            Image(systemName: isAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                                .opacity(metric == sort ? 1 : 0)
                        }
                        .frame(width: Self.column, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            ForEach(leaderboard(rows, by: sort, isAscending: isAscending), id: \.login) { row in
                HStack(spacing: 0) {
                    Text(row.login == me ? "\(row.login) (you)" : row.login)
                        .fontWeight(row.login == me ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(StatsMetric.allCases) { metric in
                        Text(metric.text(row)).monospacedDigit().frame(width: Self.column, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    row.login == me ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }
}
