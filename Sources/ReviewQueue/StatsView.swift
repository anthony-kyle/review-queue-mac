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

/// The statistics page on one grid: every section shares the same 24pt inset and full width. From the top: the title
/// bar with Refresh, the period controls that drive everything below, the period's graph, one row of equal-height
/// metric cards, and one panel with the trend or the leaderboard (as saved in Settings) and the trend's metric menu.
/// Until a period is picked it follows the default: Sprint while it is offered and a cycle is running, else Month, so
/// it switches to Sprint once cycles arrive. Sprint is only listed while offered.
struct StatsContent: View {
    static let width: CGFloat = 900
    static let inset: CGFloat = 24
    static let gridWidth = width - 2 * inset

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
        VStack(alignment: .leading, spacing: 20) {
            header
            if model.settings.teams.isEmpty {
                Text("Choose the GitHub teams whose PRs you review in Settings to see review statistics.").foregroundStyle(.secondary)
            }
            if !model.isHistoryLoading, let note = model.historyNote {
                ErrorBanner(message: "GitHub: \(note)", color: .orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                periodBar(report, period: period, title: title, isSprintOffered: isSprintOffered)
                if model.settings.sprintTeam != nil, let note = model.sprintNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            PeriodGraphView(graph: report.graph, title: title, calendar: calendar)
            HStack(alignment: .top, spacing: 8) {
                ForEach(StatsMetric.allCases.filter(\.isRanked)) { metric in
                    MetricCard(metric: metric, mine: report.mine, benchmark: report.benchmark(metric))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Panel", selection: settingsBinding(model, \.statsPanel)) {
                        ForEach(StatsPanel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
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
        .frame(width: Self.gridWidth, alignment: .leading)
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 20)
        .onChange(of: isSprintOffered) { offset = 0 }
        .task(id: indexKey) {
            if indexCache?.key != indexKey { indexCache = IndexCache(key: indexKey, index: index) }
        }
        .task(id: trendKey) {
            trendCache = TrendCache(key: trendKey, points: trend(period, endingAt: offset, index: index, cycles: cycles))
        }
        .frame(maxWidth: .infinity)
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
            .fixedSize()
            Spacer()
            IconButton(symbol: "chevron.left", help: "Previous \(period.label.lowercased())") { offset -= 1 }
                .disabled(!report.span.canGoBack)
            Text(title)
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 200)
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

/// Your reviews over the selected period, across the full grid width: a header with the period's total, the hovered
/// day and the Less/More legend, then the days as a calendar of numbered cells in week rows (Sprint, Week, Month) or a
/// heatmap in week columns with month labels (Quarter, Year), every reviewed day showing its count. The days sit in one
/// fixed-height block (`GraphLayout`) for every period, so switching period never moves what is below: calendar rows
/// share it, top-aligned and capped, and turn compact (date and count on one line) when short. Future days are dim
/// outlines; days outside the period are blank. Sizes come from the grid's fixed width, never from a measurement, so the graph
/// can't feed back into the window's size.
private struct PeriodGraphView: View {
    private static let gap = CGFloat(GraphLayout.calendarGap)
    private static let heatmapGap = CGFloat(GraphLayout.heatmapGap)
    private static let width = StatsContent.gridWidth
    private static let rowLabelWidth: CGFloat = 30
    private static let labelRow = CGFloat(GraphLayout.labelRow)
    private static let labelGap = CGFloat(GraphLayout.labelGap)
    private static let blockHeight = CGFloat(GraphLayout.blockHeight)
    private static let swatch: CGFloat = 12

    let graph: PeriodGraph
    let title: String
    let calendar: Calendar
    @State private var hovered: GraphDay?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: DayPalette { DayPalette(isDark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(counted(graph.total, "review")) in \(title)").font(.headline)
                if let hovered {
                    Text("\(counted(hovered.count, "review")) on \(hovered.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                legend
            }
            Group {
                switch graph.style {
                case .calendar: calendarGrid
                case .heatmap: heatmap
                }
            }
            .frame(width: Self.width, height: Self.blockHeight, alignment: .topLeading)
        }
    }

    private var calendarGrid: some View {
        let rowHeight = CGFloat(GraphLayout.rowHeight(rows: graph.weeks.count, gap: GraphLayout.calendarGap))
        return VStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                ForEach(graph.weekdays.indices, id: \.self) { index in
                    Text(graph.weekdays[index])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.labelRow)
                }
            }
            ForEach(graph.weeks.indices, id: \.self) { week in
                HStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { slot in
                        calendarDay(graph.weeks[week][slot], height: rowHeight)
                    }
                }
            }
        }
    }

    @ViewBuilder private func calendarDay(_ day: GraphDay?, height: CGFloat) -> some View {
        if let day {
            let isCompact = GraphLayout.isCompact(Double(height))
            let date = Text("\(calendar.component(.day, from: day.date))")
                .font(.caption2)
                .foregroundStyle(day.isFuture ? .tertiary : .secondary)
            let count = Text(day.count > 0 ? "\(day.count)" : "")
                .font(isCompact ? .caption.weight(.bold) : .callout.weight(.bold))
                .monospacedDigit()
            Group {
                if isCompact {
                    HStack {
                        date
                        Spacer(minLength: 4)
                        count
                    }
                } else {
                    ZStack {
                        date.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        count.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(DayCell(level: day.level, isFuture: day.isFuture, palette: palette, cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { isInside in hovered = isInside && !day.isFuture ? day : nil }
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: height)
        }
    }

    /// Heatmap cells as wide as the grid allows for the number of weeks, and no taller than they are wide or than seven
    /// rows fit the block: a quarter's cells come out wider than tall, a year's square.
    private var heatmapCell: CGSize {
        let columns = CGFloat(max(graph.weeks.count, 1))
        let width = ((Self.width - Self.rowLabelWidth - 6) / columns).rounded(.down) - Self.heatmapGap
        let byHeight = CGFloat(GraphLayout.rowHeight(rows: 7, gap: GraphLayout.heatmapGap))
        return CGSize(width: max(width, 6), height: max(min(width, byHeight), 6))
    }

    private var heatmap: some View {
        let cell = heatmapCell
        let step = CGSize(width: cell.width + Self.heatmapGap, height: cell.height + Self.heatmapGap)
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: Self.heatmapGap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(graph.weekdays[row]).frame(height: cell.height)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: Self.rowLabelWidth, alignment: .trailing)
            .padding(.top, Self.labelRow + Self.labelGap)
            VStack(alignment: .leading, spacing: Self.labelGap) {
                ZStack(alignment: .topLeading) {
                    ForEach(graph.months, id: \.column) { month in
                        Text(month.name).offset(x: CGFloat(month.column) * step.width)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: CGFloat(graph.weeks.count) * step.width, height: Self.labelRow, alignment: .topLeading)
                heatmapCanvas(cell: cell, step: step)
            }
        }
    }

    /// Every day drawn in one Canvas rather than a view per day: bordered when cells are big enough to show it, and
    /// with its count centred in a font scaled to the cell's shorter side (never below 7pt). Hovering reads the day under the pointer
    /// from its position.
    private func heatmapCanvas(cell: CGSize, step: CGSize) -> some View {
        let weeks = graph.weeks
        let palette = palette
        let side = min(cell.width, cell.height)
        let radius = min(4, side / 4)
        let font = Font.system(size: max(7, (side * 0.6).rounded(.down)), weight: .semibold).monospacedDigit()
        return Canvas { context, _ in
            for (column, days) in weeks.enumerated() {
                for (row, day) in days.enumerated() {
                    guard let day else { continue }
                    let rect = CGRect(x: CGFloat(column) * step.width, y: CGFloat(row) * step.height, width: cell.width, height: cell.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(palette.fill(day.level, isFuture: day.isFuture)))
                    if side >= 8 || day.isFuture {
                        let border = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius, style: .continuous)
                        context.stroke(border, with: .color(palette.border(day.level, isFuture: day.isFuture)), lineWidth: 1)
                    }
                    if day.count > 0, !day.isFuture {
                        context.draw(Text("\(day.count)").font(font).foregroundStyle(.primary), at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
            }
        }
        .frame(width: CGFloat(weeks.count) * step.width - Self.heatmapGap, height: 7 * step.height - Self.heatmapGap)
        .onContinuousHover { phase in
            guard case let .active(point) = phase else { return hovered = nil }
            let column = Int(point.x / step.width)
            let row = Int(point.y / step.height)
            let isOnCell = point.x.truncatingRemainder(dividingBy: step.width) < cell.width && point.y.truncatingRemainder(dividingBy: step.height) < cell.height
            let day = isOnCell && weeks.indices.contains(column) && (0..<7).contains(row) ? weeks[column][row] : nil
            hovered = day?.isFuture == false ? day : nil
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
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

/// One ranked metric as a compact card: a one-line title, your value, and one comparison line with the team median and
/// your rank as a pill, tinted green when you're in the top quarter. Response rate adds one line of requests answered
/// on time and missed, and keeps your own median response and pending count in its tooltip, so every card stays the
/// same height.
private struct MetricCard: View {
    let metric: StatsMetric
    let mine: ReviewerStats?
    let benchmark: Benchmark

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(mine.map(metric.text) ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if metric == .responseRate {
                rateLine.font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
            }
            HStack(spacing: 6) {
                Text("Team \(metric.format(benchmark.median))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                rankPill
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(tooltip)
    }

    @ViewBuilder private var rateLine: some View {
        if let mine {
            let due = mine.onTime + mine.late + mine.missed
            let missed = Text(mine.missed > 0 ? " · \(mine.missed) missed" : "").foregroundStyle(.orange)
            Text("\(Text("\(mine.onTime)/\(due) on time").foregroundStyle(.secondary))\(missed)")
        }
    }

    @ViewBuilder private var rankPill: some View {
        if let rank = benchmark.rank, let top = benchmark.topPercent {
            Text(rankText(rank, of: benchmark.cohort))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(top <= 25 ? AnyShapeStyle(Color.green.opacity(0.22)) : AnyShapeStyle(.fill.tertiary), in: Capsule())
        } else {
            Text(metric == .responseRate ? "No requests due" : "Unranked").foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private var tooltip: String {
        var lines = ["\(metric.title): \(mine.map(metric.text) ?? "—"), team median \(metric.format(benchmark.median))"]
        if let rank = benchmark.rank, let top = benchmark.topPercent { lines.append("\(rankText(rank, of: benchmark.cohort)) · Top \(top)%") }
        if metric == .responseRate, let mine {
            lines.append("\(mine.onTime) of \(mine.onTime + mine.late + mine.missed) within 1 business day, \(mine.late) late, \(mine.missed) missed")
            lines.append("\(mine.pending) pending")
            lines.append("Your median response: \(StatsMetric.ownSpeed.text(mine))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Everyone in the teams with the period's numbers in right-aligned columns of one width, sortable by any column (click
/// again to reverse), on alternating row shades with your row highlighted.
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
                        HStack(spacing: 3) {
                            Text(metric.title)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            ForEach(Array(leaderboard(rows, by: sort, isAscending: isAscending).enumerated()), id: \.element.login) { position, row in
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
                    row.login == me ? Color.accentColor.opacity(0.18) : position.isMultiple(of: 2) ? Color.primary.opacity(0.035) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
        }
    }
}
