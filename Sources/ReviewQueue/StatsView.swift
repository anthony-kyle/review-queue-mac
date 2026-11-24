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
        .onAppear { model.refreshHistoryIfStale() }
    }
}

/// Header with refresh and progress, last year's heatmap, the period picker, your metrics against the team's, and the
/// leaderboard when it is switched on. The period starts at this month whenever the window opens.
struct StatsContent: View {
    static let width: CGFloat = 900

    let model: AppModel
    @State private var period = StatsPeriod.month
    @State private var offset = 0

    var body: some View {
        let calendar = Calendar.current
        let report = StatsReport(history: model.history, period: period, offset: offset, now: Date(), calendar: calendar)
        VStack(alignment: .leading, spacing: 22) {
            header
            if model.settings.teams.isEmpty {
                Text("Choose the GitHub teams whose PRs you review in Settings to see review statistics.").foregroundStyle(.secondary)
            }
            if !model.isHistoryLoading, let note = model.historyNote {
                ErrorBanner(message: "GitHub: \(note)", color: .orange)
            }
            HeatmapView(heatmap: report.heatmap, highlighted: report.interval, calendar: calendar)
            periodBar(report, calendar: calendar)
            HStack(alignment: .top, spacing: 12) {
                ForEach(StatsMetric.allCases) { metric in
                    MetricCard(metric: metric, mine: report.mine, benchmark: report.benchmark(metric))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show leaderboard", isOn: settingsBinding(model, \.isLeaderboardShown))
                    .toggleStyle(.switch)
                if model.settings.isLeaderboardShown {
                    LeaderboardView(rows: report.rows, me: report.me)
                }
            }
        }
        .padding(24)
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

    private func periodBar(_ report: StatsReport, calendar: Calendar) -> some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $period) {
                ForEach(StatsPeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .onChange(of: period) { offset = 0 }
            Spacer()
            IconButton(symbol: "chevron.left", help: "Previous \(period.label.lowercased())") { offset -= 1 }
                .disabled(!report.canGoBack)
            Text(periodTitle(report.interval, calendar: calendar))
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 190)
            IconButton(symbol: "chevron.right", help: "Next \(period.label.lowercased())") { offset += 1 }
                .disabled(offset >= 0)
        }
    }

    private func periodTitle(_ interval: DateInterval, calendar: Calendar) -> String {
        let start = interval.start
        switch period {
        case .week:
            let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? start
            return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month:
            return start.formatted(.dateTime.month(.wide).year())
        case .quarter:
            return "Q\((calendar.component(.month, from: start) - 1) / 3 + 1) \(start.formatted(.dateTime.year()))"
        case .year:
            return start.formatted(.dateTime.year())
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

/// GitHub's contribution grid for your reviews: week columns from Sunday to Saturday with Mon, Wed and Fri labelled,
/// month names on top, a five-step green scale and a legend. Days in the selected period are outlined, and hovering a
/// day shows its count beside the total.
private struct HeatmapView: View {
    private static let cell: CGFloat = 12
    private static let gap: CGFloat = 3
    private static let monthRow: CGFloat = 14

    let heatmap: Heatmap
    let highlighted: DateInterval
    let calendar: Calendar
    @State private var hovered: HeatmapCell?
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(counted(heatmap.total, "review")) in the last year").font(.headline)
                Spacer()
                if let hovered {
                    Text("\(counted(hovered.count, "review")) on \(hovered.date.formatted(date: .long, time: .omitted))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack(alignment: .top, spacing: 6) {
                weekdays.padding(.top, Self.monthRow + 4)
                VStack(alignment: .leading, spacing: 4) {
                    months
                    grid
                    legend
                }
            }
        }
    }

    private var weekdays: some View {
        let symbols = calendar.shortWeekdaySymbols
        return VStack(alignment: .trailing, spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? symbols[row] : "")
                    .frame(height: Self.cell)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var months: some View {
        ZStack(alignment: .topLeading) {
            ForEach(heatmap.months, id: \.column) { month in
                Text(month.name).offset(x: CGFloat(month.column) * (Self.cell + Self.gap))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: Self.monthRow, alignment: .topLeading)
    }

    /// Every day drawn in one Canvas rather than 371 views; hovering reads the day under the pointer from its position.
    private var grid: some View {
        let step = Self.cell + Self.gap
        let columns = heatmap.columns
        let isDark = isDark
        return Canvas { context, _ in
            for (column, days) in columns.enumerated() {
                for (row, day) in days.enumerated() {
                    guard let day else { continue }
                    let rect = CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: Self.cell, height: Self.cell)
                    let shape = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)
                    context.fill(shape, with: .color(.heatmap(day.level, isDark: isDark)))
                    if highlighted.holds(day.date) {
                        context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5, style: .continuous), with: .color(.primary.opacity(0.55)), lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: CGFloat(columns.count) * step - Self.gap, height: 7 * step - Self.gap)
        .onContinuousHover { phase in
            guard case let .active(point) = phase else { return hovered = nil }
            let column = Int(point.x / step)
            let row = Int(point.y / step)
            let isOnCell = point.x.truncatingRemainder(dividingBy: step) < Self.cell && point.y.truncatingRemainder(dividingBy: step) < Self.cell
            hovered = isOnCell && columns.indices.contains(column) && (0..<7).contains(row) ? columns[column][row] : nil
        }
    }

    private var legend: some View {
        HStack(spacing: Self.gap) {
            Spacer()
            Text("Less").padding(.trailing, 3)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.heatmap(level, isDark: isDark))
                    .frame(width: Self.cell, height: Self.cell)
            }
            Text("More").padding(.leading, 3)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

/// One metric: your value, the team median, and your rank. Response time has no rank until you have reviewed a PR in
/// the period.
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var standing: String {
        guard let rank = benchmark.rank, let top = benchmark.topPercent else {
            return metric == .response ? "No first reviews to time" : "No team to compare"
        }
        return "\(rankText(rank, of: benchmark.cohort)) · Top \(top)%"
    }
}

/// Everyone in the teams with the period's numbers, sortable by any column (click again to reverse), with your row
/// highlighted.
private struct LeaderboardView: View {
    private static let column: CGFloat = 150

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
