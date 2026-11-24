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
    @State private var trendMetric = StatsMetric.reviews

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let isSprintOffered = model.isSprintOffered
        let cycles = isSprintOffered ? model.sprintCycles : []
        let fallback = defaultPeriod(isSprintOffered: isSprintOffered, cycles: cycles, now: now)
        let period = picked.flatMap { $0 != .sprint || isSprintOffered ? $0 : nil } ?? fallback
        let history = model.history.counted(model.settings)
        let report = StatsReport(history: history, period: period, offset: offset, cycles: cycles, now: now, calendar: calendar)
        let title = periodTitle(report.span, period: period, calendar: calendar)
        let trendKey = TrendKey(
            period: period,
            offset: offset,
            prs: model.history.prs.count,
            completedAt: model.history.completedAt,
            cycles: cycles.map(\.id),
            me: model.history.me,
            allowedBots: model.settings.allowedBotAuthors
        )
        VStack(alignment: .leading, spacing: 22) {
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
            HStack(alignment: .top, spacing: 12) {
                ForEach(StatsMetric.allCases) { metric in
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
                            ForEach(StatsMetric.allCases) { Text($0.title).tag($0) }
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
        .task(id: trendKey) {
            let points = trend(period, endingAt: offset, history: history, cycles: cycles, now: Date(), calendar: calendar)
            trendCache = TrendCache(key: trendKey, points: points)
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

/// What the trend depends on, so it is computed once per change of period, offset, history, cycles or allowed bots
/// rather than on every render.
private struct TrendKey: Hashable {
    let period: StatsPeriod
    let offset: Int
    let prs: Int
    let completedAt: Date?
    let cycles: [String]
    let me: String?
    let allowedBots: [String]
}

private struct TrendCache {
    let key: TrendKey
    let points: [PeriodStats]
}

/// One period's metric for the trend chart: your value (nil leaves a gap) and the team median, both in the chart's
/// units, which are hours for response time.
private struct TrendPoint: Identifiable {
    let id: Int
    let stats: PeriodStats
    let mine: Double?
    let median: Double?
    let run: Int
    let isPartial: Bool
}

/// The chosen metric over the trend's periods: you as a solid line with points, broken where you have no value, and
/// the team median dashed. The last point is the selected period, drawn larger; a period still running is hollow and
/// reads "so far". Hovering shows the period, your value and the median. Fixed height, so it never sizes the window.
private struct TrendView: View {
    private static let you = Color.green
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
            chart(data).frame(height: 220)
            HStack(spacing: 16) {
                legendItem("You", dash: [])
                legendItem("Team median", dash: [5, 4])
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
        metric == .response ? value / Self.hour : value
    }

    private func chart(_ data: [TrendPoint]) -> some View {
        Chart {
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
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .response ? compactDuration(number * Self.hour) : metric.format(number))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
    }

    private func tooltip(_ point: TrendPoint) -> some View {
        let unplot = { (value: Double?) in value.map { self.metric == .response ? $0 * Self.hour : $0 } }
        return VStack(alignment: .leading, spacing: 2) {
            Text(periodTitle(point.stats.span, period: period, calendar: calendar)).font(.caption.weight(.semibold))
            Text("You: \(metric.format(unplot(point.mine)))\(point.isPartial ? " so far" : "")")
            Text("Team median: \(metric.format(unplot(point.median)))")
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func legendItem(_ name: String, dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 22, y: 4))
            }
            .stroke(dash.isEmpty ? Self.you : Color.secondary, style: StrokeStyle(lineWidth: dash.isEmpty ? 2.5 : 1.5, dash: dash))
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
/// large numbered cells (Sprint, Week, Month) or a heatmap of small cells with month labels (Quarter, Year), and the
/// Less/More legend. Future days are outlined and empty; days outside the period are blank. Cell sizes come from the
/// window's minimum content width, never from a measurement, so the graph can't feed back into the window's size.
private struct PeriodGraphView: View {
    private static let gap: CGFloat = 3
    private static let width = StatsContent.width - 48
    private static let rowLabelWidth: CGFloat = 30
    private static let dayWidth: CGFloat = 112
    private static let dayHeight: CGFloat = 58
    private static let heatmapCell: CGFloat = 18
    private static let swatch: CGFloat = 12
    private static let monthRow: CGFloat = 14

    let graph: PeriodGraph
    let title: String
    let calendar: Calendar
    @State private var hovered: GraphDay?
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

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
            switch graph.style {
            case .calendar: calendarGrid
            case .heatmap: heatmap
            }
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
                        .frame(maxWidth: Self.dayWidth, alignment: .leading)
                        .padding(.leading, 6)
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
            VStack(alignment: .leading) {
                Text("\(calendar.component(.day, from: day.date))").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if day.count > 0 {
                    Text("\(day.count)").font(.title3.weight(.semibold)).monospacedDigit()
                }
            }
            .padding(6)
            .frame(maxWidth: Self.dayWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(height: Self.dayHeight)
            .background(dayShape(day))
            .contentShape(Rectangle())
            .onHover { isInside in hovered = isInside && !day.isFuture ? day : nil }
        } else {
            Color.clear.frame(maxWidth: Self.dayWidth).frame(height: Self.dayHeight)
        }
    }

    @ViewBuilder private func dayShape(_ day: GraphDay) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if day.isFuture {
            shape.strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
        } else {
            shape.fill(Color.heatmap(day.level, isDark: isDark))
        }
    }

    private var heatmapCellSize: CGFloat {
        let columns = CGFloat(max(graph.weeks.count, 1))
        let fit = ((Self.width - Self.rowLabelWidth - 6) / columns).rounded(.down) - Self.gap
        return min(Self.heatmapCell, max(fit, 6))
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

    /// Every day drawn in one Canvas rather than a view per day; hovering reads the day under the pointer from its
    /// position.
    private func heatmapCanvas(cell: CGFloat, step: CGFloat) -> some View {
        let weeks = graph.weeks
        let isDark = isDark
        return Canvas { context, _ in
            for (column, days) in weeks.enumerated() {
                for (row, day) in days.enumerated() {
                    guard let day else { continue }
                    let rect = CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: cell, height: cell)
                    if day.isFuture {
                        context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5, style: .continuous), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                    } else {
                        context.fill(Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous), with: .color(.heatmap(day.level, isDark: isDark)))
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
        HStack(spacing: Self.gap) {
            Spacer()
            Text("Less").padding(.trailing, 3)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.heatmap(level, isDark: isDark))
                    .frame(width: Self.swatch, height: Self.swatch)
            }
            Text("More").padding(.leading, 3)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One metric: your value, the team median, and your rank. Response time has no rank until you have a response sample
/// in the period, and also shows how many of your samples there are unanswered requests.
private struct MetricCard: View {
    let metric: StatsMetric
    let mine: ReviewerStats?
    let benchmark: Benchmark

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title).font(.callout).foregroundStyle(.secondary)
            Text(mine.map(metric.text) ?? "—")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("Team median \(metric.format(benchmark.median))").font(.callout)
            Text(standing).font(.callout).foregroundStyle(.secondary)
            if metric == .response, let unanswered = mine?.unanswered {
                Text("\(unanswered) unanswered").font(.callout).foregroundStyle(unanswered > 0 ? Color.orange : Color.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var standing: String {
        guard let rank = benchmark.rank, let top = benchmark.topPercent else {
            return metric == .response ? "No responses to time" : "No team to compare"
        }
        return "\(rankText(rank, of: benchmark.cohort)) · Top \(top)%"
    }
}

/// Everyone in the teams with the period's numbers, sortable by any column (click again to reverse), with your row
/// highlighted.
private struct LeaderboardView: View {
    private static let column: CGFloat = 128

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

extension Color {
    /// GitHub's contribution greens for heatmap levels 0 to 4, with level 0 a neutral grey, in the light or dark set.
    static func heatmap(_ level: Int, isDark: Bool) -> Color {
        let light: [UInt32] = [0xEBEDF0, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
        let dark: [UInt32] = [0x2D333B, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]
        let rgb = (isDark ? dark : light)[min(max(level, 0), 4)]
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
