import Foundation

private let countedStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]

/// The span the statistics cover: a calendar period, or a Linear cycle of the chosen sprint team.
public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case sprint, week, month, quarter, year

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sprint: "Sprint"
        case .week: "Week"
        case .month: "Month"
        case .quarter: "Quarter"
        case .year: "Year"
        }
    }
}

/// The calendar `period` holding `date`, moved `offset` periods (negative is earlier). Weeks start on `calendar`'s first
/// weekday; quarters start in January, April, July and October. Nil for Sprint, which follows Linear's cycles instead.
public func periodInterval(_ period: StatsPeriod, offset: Int = 0, containing date: Date, calendar: Calendar) -> DateInterval? {
    let (component, length): (Calendar.Component, Int)
    switch period {
    case .sprint: return nil
    case .week: (component, length) = (.weekOfYear, 1)
    case .month: (component, length) = (.month, 1)
    case .quarter: (component, length) = (.month, 3)
    case .year: (component, length) = (.year, 1)
    }
    let start: Date
    switch period {
    case .week: start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    case .year: start = calendar.dateInterval(of: .year, for: date)?.start ?? date
    case .sprint, .month, .quarter:
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let intoQuarter = period == .quarter ? (calendar.component(.month, from: month) - 1) % 3 : 0
        start = calendar.date(byAdding: .month, value: -intoQuarter, to: month) ?? month
    }
    let shifted = calendar.date(byAdding: component, value: length * offset, to: start) ?? start
    let end = calendar.date(byAdding: component, value: length, to: shifted) ?? shifted
    return DateInterval(start: shifted, end: end)
}

/// One reviewer's numbers for a period. `reviews` counts distinct PR-days; `responseTimes` holds one entry per PR whose
/// first review by this reviewer fell in the period.
public struct ReviewerStats: Equatable, Sendable {
    public let login: String
    public var reviews = 0
    public var approved = 0
    public var changesRequested = 0
    public var responseTimes: [TimeInterval] = []

    public init(login: String, reviews: Int = 0, approved: Int = 0, changesRequested: Int = 0, responseTimes: [TimeInterval] = []) {
        self.login = login
        self.reviews = reviews
        self.approved = approved
        self.changesRequested = changesRequested
        self.responseTimes = responseTimes
    }

    public var averageResponse: TimeInterval? {
        responseTimes.isEmpty ? nil : responseTimes.reduce(0, +) / Double(responseTimes.count)
    }
}

/// What the statistics compare, with how each reads from a reviewer's stats. Only response time is better lower, and
/// only it can be missing.
public enum StatsMetric: String, CaseIterable, Identifiable, Sendable {
    case reviews, approved, changesRequested, response

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .reviews: "Reviews done"
        case .approved: "PRs approved"
        case .changesRequested: "Changes requested"
        case .response: "Avg time to respond"
        }
    }

    public var isLowerBetter: Bool { self == .response }

    public func value(_ stats: ReviewerStats) -> Double? {
        switch self {
        case .reviews: Double(stats.reviews)
        case .approved: Double(stats.approved)
        case .changesRequested: Double(stats.changesRequested)
        case .response: stats.averageResponse
        }
    }

    public func text(_ stats: ReviewerStats) -> String {
        format(value(stats))
    }

    /// A value as the window shows it: a compact duration for response time, otherwise a count with at most one
    /// decimal (medians can fall between two); an em dash when missing.
    public func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        if self == .response { return compactDuration(value) }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// `rows` ordered by `metric`, ascending or descending, with missing values always last and ties by login.
public func leaderboard(_ rows: [ReviewerStats], by metric: StatsMetric, isAscending: Bool) -> [ReviewerStats] {
    rows.sorted { a, b in
        switch (metric.value(a), metric.value(b)) {
        case let (x?, y?) where x != y: isAscending ? x < y : x > y
        case (_?, nil): true
        case (nil, _?): false
        default: a.login < b.login
        }
    }
}

/// The reviews that count: by a human other than the PR's author, approving, requesting changes or commenting.
func countedReviews(_ pr: HistoryPr) -> [HistoryReview] {
    pr.reviews.filter { !$0.isBot && $0.author != pr.author && countedStates.contains($0.state) }
}

/// How long `reviewer` took to answer a PR, from the later of the PR becoming ready (its last ready-for-review event,
/// else its creation) and the reviewer's earliest review request, to `firstReview`. A request after the first review
/// falls back to the ready time; never negative.
func responseTime(_ pr: HistoryPr, reviewer: String, firstReview: Date) -> TimeInterval {
    let ready = pr.readyAt ?? pr.createdAt
    let requested = pr.requests.filter { $0.reviewer == reviewer }.map(\.at).min()
    let latest = max(ready, requested ?? ready)
    let start = latest > firstReview ? ready : latest
    return max(0, firstReview.timeIntervalSince(start))
}

/// The local days `reviewer` reviewed each PR on, keyed by start of day, counting each PR once a day.
public func dailyReviewCounts(_ prs: [HistoryPr], reviewer: String, calendar: Calendar) -> [Date: Int] {
    var counts: [Date: Int] = [:]
    for pr in prs {
        let days = Set(countedReviews(pr).filter { $0.author == reviewer }.map { calendar.startOfDay(for: $0.submittedAt) })
        for day in days { counts[day, default: 0] += 1 }
    }
    return counts
}

/// Each of `reviewers`' stats in `interval`, in the given order, with zeros for anyone who did not review there.
public func reviewerStats(_ prs: [HistoryPr], in interval: DateInterval, reviewers: [String], calendar: Calendar) -> [ReviewerStats] {
    var stats = Dictionary(reviewers.map { ($0, ReviewerStats(login: $0)) }, uniquingKeysWith: { first, _ in first })
    for pr in prs {
        for (reviewer, reviews) in Dictionary(grouping: countedReviews(pr), by: \.author) where stats[reviewer] != nil {
            let inside = reviews.filter { interval.holds($0.submittedAt) }
            stats[reviewer]?.reviews += Set(inside.map { calendar.startOfDay(for: $0.submittedAt) }).count
            if inside.contains(where: { $0.state == "APPROVED" }) { stats[reviewer]?.approved += 1 }
            if inside.contains(where: { $0.state == "CHANGES_REQUESTED" }) { stats[reviewer]?.changesRequested += 1 }
            if let first = reviews.map(\.submittedAt).min(), interval.holds(first) {
                stats[reviewer]?.responseTimes.append(responseTime(pr, reviewer: reviewer, firstReview: first))
            }
        }
    }
    return unique(reviewers).compactMap { stats[$0] }
}

extension DateInterval {
    /// Whether `date` falls in the half-open interval, so a review at midnight belongs to the day it starts.
    public func holds(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

/// Your value for a metric beside the team's: the median and your rank among everyone with a value. Ties share the
/// better rank, so three people on 4 reviews are all 1st when 4 is the most.
public struct Benchmark: Equatable, Sendable {
    public let median: Double?
    public let rank: Int?
    public let cohort: Int

    /// The share of the team at or above your rank, rounded up: 3rd of 14 is the top 22%.
    public var topPercent: Int? {
        guard let rank, cohort > 0 else { return nil }
        return Int((Double(rank) / Double(cohort) * 100).rounded(.up))
    }
}

/// `value`'s place among `values` (which include it); nil values are left out of both the median and the ranking.
public func benchmark(_ value: Double?, among values: [Double?], isLowerBetter: Bool) -> Benchmark {
    let present = values.compactMap(\.self)
    let rank = value.map { mine in 1 + present.filter { isLowerBetter ? $0 < mine : $0 > mine }.count }
    return Benchmark(median: median(present), rank: rank, cohort: present.count)
}

/// The middle value, or the mean of the middle two for an even count; nil for none.
public func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

/// A rank as words: `1st of 5`, `12th of 14`, `23rd of 40`.
public func rankText(_ rank: Int, of count: Int) -> String {
    let suffix = switch (rank % 100, rank % 10) {
    case (11...13, _): "th"
    case (_, 1): "st"
    case (_, 2): "nd"
    case (_, 3): "rd"
    default: "th"
    }
    return "\(rank)\(suffix) of \(count)"
}

/// One day of the period graph. Future days have no count and level 0.
public struct GraphDay: Equatable, Sendable {
    public let date: Date
    public let count: Int
    public let level: Int
    public let isFuture: Bool
}

/// A month name over the first graph column whose first day in the period falls in that month.
public struct GraphMonth: Equatable, Sendable {
    public let column: Int
    public let name: String
}

/// How a period graph is drawn: a calendar of large day cells in week rows (Sprint, Week, Month), or a GitHub-style
/// heatmap of small cells in week columns (Quarter, Year).
public enum GraphStyle: Equatable, Sendable {
    case calendar, heatmap

    public init(_ period: StatsPeriod) {
        self = period == .quarter || period == .year ? .heatmap : .calendar
    }
}

/// The selected period's days laid out by week. Each week has seven slots in `calendar`'s weekday order; a nil slot is a
/// day outside the period. For the calendar style weeks are rows; for the heatmap they are columns, labelled by
/// `months`. `weekdays` names the slots, and `total` sums the period's days up to today.
public struct PeriodGraph: Equatable, Sendable {
    public let style: GraphStyle
    public let weeks: [[GraphDay?]]
    public let weekdays: [String]
    public let months: [GraphMonth]
    public let total: Int
}

private let keptWeeks = 53

/// The first day the history keeps: the start of the week 52 weeks before the one holding `today`.
public func historyStart(today: Date, calendar: Calendar) -> Date {
    let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? calendar.startOfDay(for: today)
    return calendar.date(byAdding: .weekOfYear, value: -(keptWeeks - 1), to: week) ?? week
}

/// Lays the days of `interval` out in whole weeks, with `counts` (keyed by start of day) shaded on `thresholds`. A
/// period starting mid-day, like a Linear cycle, includes that day; one ending at midnight excludes the next.
public func periodGraph(
    _ interval: DateInterval,
    style: GraphStyle,
    counts: [Date: Int],
    thresholds: [Int],
    today: Date,
    calendar: Calendar
) -> PeriodGraph {
    let first = calendar.startOfDay(for: interval.start)
    let last = calendar.startOfDay(for: max(interval.start, interval.end.addingTimeInterval(-1)))
    let todayStart = calendar.startOfDay(for: today)
    let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
    var weeks: [[GraphDay?]] = []
    var weekStart = firstWeek
    while weekStart <= last {
        weeks.append((0..<7).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart), day >= first, day <= last else { return nil }
            let isFuture = day > todayStart
            let count = isFuture ? 0 : counts[day] ?? 0
            return GraphDay(date: day, count: count, level: heatmapLevel(count, thresholds: thresholds), isFuture: isFuture)
        })
        guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { break }
        weekStart = next
    }
    let symbols = calendar.shortWeekdaySymbols
    return PeriodGraph(
        style: style,
        weeks: weeks,
        weekdays: (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] },
        months: style == .heatmap ? graphMonths(weeks.map { $0.compactMap(\.self).first?.date }, calendar: calendar) : [],
        total: weeks.joined().compactMap(\.self).reduce(0) { $0 + $1.count }
    )
}

/// Labels each column whose first day in the period falls in a different month from the column before; the first
/// column is labelled only when the next label is at least three columns away, so the two never overlap.
func graphMonths(_ firstDays: [Date?], calendar: Calendar) -> [GraphMonth] {
    let months = firstDays.map { $0.map { calendar.component(.month, from: $0) } ?? 0 }
    var labels = months.indices.filter { $0 > 0 && months[$0] != months[$0 - 1] && months[$0] > 0 }
    if months.first.map({ $0 > 0 }) == true, (labels.first ?? Int.max) >= 3 { labels.insert(0, at: 0) }
    return labels.map { GraphMonth(column: $0, name: calendar.shortMonthSymbols[months[$0] - 1]) }
}

/// The upper bounds of levels 1 to 3: the quartiles of the nonzero counts, by nearest rank. Empty when no day has
/// reviews.
func heatmapThresholds(_ counts: [Int]) -> [Int] {
    let nonzero = counts.filter { $0 > 0 }.sorted()
    guard !nonzero.isEmpty else { return [] }
    return [0.25, 0.5, 0.75].map { nonzero[max(0, Int((Double(nonzero.count) * $0).rounded(.up)) - 1)] }
}

/// 0 for no reviews, otherwise 1 plus how many thresholds the count exceeds.
func heatmapLevel(_ count: Int, thresholds: [Int]) -> Int {
    count == 0 ? 0 : 1 + thresholds.filter { count > $0 }.count
}

/// The span a period and offset land on, the cycle behind it for Sprint, and whether it can step either way.
public struct PeriodSpan: Equatable, Sendable {
    public let interval: DateInterval
    public let cycle: LinearCycle?
    public let canGoBack: Bool
    public let canGoForward: Bool
}

/// The span `offset` steps back from the current one (positive offsets are clamped to now). Calendar periods step until
/// they would start before the kept history. Sprint steps through `cycles` that have started and start within the kept
/// history, from the latest one; with no such cycle it falls back to the month.
public func periodSpan(_ period: StatsPeriod, offset: Int, cycles: [LinearCycle], now: Date, calendar: Calendar) -> PeriodSpan {
    let start = historyStart(today: now, calendar: calendar)
    let steps = min(offset, 0)
    let reachable = reachableCycles(cycles, now: now, start: start)
    if period == .sprint, let latest = reachable.indices.last {
        let index = max(0, latest + steps)
        let cycle = reachable[index]
        return PeriodSpan(interval: cycle.interval, cycle: cycle, canGoBack: index > 0, canGoForward: index < latest)
    }
    let calendarPeriod = period == .sprint ? StatsPeriod.month : period
    let interval = periodInterval(calendarPeriod, offset: steps, containing: now, calendar: calendar) ?? DateInterval(start: now, duration: 0)
    return PeriodSpan(interval: interval, cycle: nil, canGoBack: interval.start > start, canGoForward: steps < 0)
}

/// Every cohort member's stats for one span, where the cohort is the teams' human members plus you, with your row and
/// your standing against the team. The cards, the leaderboard and each trend point all read from this.
public struct PeriodStats: Equatable, Sendable {
    public let span: PeriodSpan
    public let me: String?
    public let rows: [ReviewerStats]

    public init(history: ReviewHistory, span: PeriodSpan, calendar: Calendar) {
        self.span = span
        me = history.me
        let cohort = unique(history.members + (history.me.map { [$0] } ?? [])).filter { !$0.hasSuffix("[bot]") }
        rows = reviewerStats(history.prs, in: span.interval, reviewers: cohort, calendar: calendar)
    }

    public var mine: ReviewerStats? { rows.first { $0.login == me } }

    public func benchmark(_ metric: StatsMetric) -> Benchmark {
        ReviewQueueCore.benchmark(mine.flatMap(metric.value), among: rows.map(metric.value), isLowerBetter: metric.isLowerBetter)
    }

    /// Whether the span is still running at `now`, so its numbers are only so far.
    public func isPartial(now: Date) -> Bool {
        span.interval.end > now
    }
}

/// Everything the statistics window shows for one period: your reviews in it as a graph, shaded on the quartiles of
/// your whole kept history so a shade means the same in every period, and the period's stats. Members and you come
/// from the history, so a cached history renders the same before any refresh.
public struct StatsReport: Equatable, Sendable {
    public let stats: PeriodStats
    public let graph: PeriodGraph

    public init(history: ReviewHistory, period: StatsPeriod, offset: Int, cycles: [LinearCycle] = [], now: Date, calendar: Calendar) {
        stats = PeriodStats(history: history, span: periodSpan(period, offset: offset, cycles: cycles, now: now, calendar: calendar), calendar: calendar)
        let counts = history.me.map { dailyReviewCounts(history.prs, reviewer: $0, calendar: calendar) } ?? [:]
        graph = periodGraph(stats.span.interval, style: GraphStyle(period), counts: counts, thresholds: heatmapThresholds(Array(counts.values)), today: now, calendar: calendar)
    }

    public var span: PeriodSpan { stats.span }
    public var interval: DateInterval { stats.span.interval }
    public var me: String? { stats.me }
    public var rows: [ReviewerStats] { stats.rows }
    public var mine: ReviewerStats? { stats.mine }

    public func benchmark(_ metric: StatsMetric) -> Benchmark {
        stats.benchmark(metric)
    }
}

/// How many points the trend shows for each period: 12 cycles, weeks or months, 4 quarters, and every year the history
/// reaches.
func trendLength(_ period: StatsPeriod) -> Int {
    switch period {
    case .sprint, .week, .month: 12
    case .quarter: 4
    case .year: Int.max
    }
}

/// The trend's periods, oldest first, ending at the one `offset` selects: up to `trendLength` of them, never one that
/// starts before the kept history (the selected period always counts). Each is computed exactly as the cards compute
/// the selected period.
public func trend(_ period: StatsPeriod, endingAt offset: Int, history: ReviewHistory, cycles: [LinearCycle], now: Date, calendar: Calendar) -> [PeriodStats] {
    let start = historyStart(today: now, calendar: calendar)
    var spans: [PeriodSpan] = []
    var step = min(offset, 0)
    while spans.count < trendLength(period) {
        let span = periodSpan(period, offset: step, cycles: cycles, now: now, calendar: calendar)
        guard spans.isEmpty || span.interval.start >= start else { break }
        spans.insert(span, at: 0)
        guard span.canGoBack else { break }
        step -= 1
    }
    return spans.map { PeriodStats(history: history, span: $0, calendar: calendar) }
}
