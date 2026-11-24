import Foundation

private let countedStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]

/// The calendar span the statistics cover.
public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, quarter, year

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .quarter: "Quarter"
        case .year: "Year"
        }
    }
}

/// The calendar `period` holding `date`, moved `offset` periods (negative is earlier). Weeks start on `calendar`'s first
/// weekday; quarters start in January, April, July and October.
public func periodInterval(_ period: StatsPeriod, offset: Int = 0, containing date: Date, calendar: Calendar) -> DateInterval {
    let (component, length): (Calendar.Component, Int) = switch period {
    case .week: (.weekOfYear, 1)
    case .month: (.month, 1)
    case .quarter: (.month, 3)
    case .year: (.year, 1)
    }
    let start: Date
    switch period {
    case .week: start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    case .year: start = calendar.dateInterval(of: .year, for: date)?.start ?? date
    case .month, .quarter:
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

/// One day in the heatmap.
public struct HeatmapCell: Equatable, Sendable {
    public let date: Date
    public let count: Int
    public let level: Int
}

/// A month name over the first heatmap column whose week starts in that month.
public struct HeatmapMonth: Equatable, Sendable {
    public let column: Int
    public let name: String
}

/// A GitHub-style year of days: columns are weeks from Sunday to Saturday, the last one running up to today; days after
/// today are nil. Levels run 0 (no reviews) to 4.
public struct Heatmap: Equatable, Sendable {
    public static let weeks = 53

    public let columns: [[HeatmapCell?]]
    public let months: [HeatmapMonth]
    public let total: Int
}

/// The first day the heatmap shows, and so the start of what the history keeps: the Sunday 52 weeks before the one
/// that starts today's week.
public func heatmapStart(today: Date, calendar: Calendar) -> Date {
    let sundays = sundayFirst(calendar)
    let week = sundays.dateInterval(of: .weekOfYear, for: today)?.start ?? sundays.startOfDay(for: today)
    return sundays.date(byAdding: .weekOfYear, value: -(Heatmap.weeks - 1), to: week) ?? week
}

/// Lays `counts` (keyed by start of day) out as the heatmap ending today.
public func heatmap(_ counts: [Date: Int], today: Date, calendar: Calendar) -> Heatmap {
    let sundays = sundayFirst(calendar)
    let start = heatmapStart(today: today, calendar: calendar)
    let last = sundays.startOfDay(for: today)
    let days = (0..<(Heatmap.weeks * 7)).map { sundays.date(byAdding: .day, value: $0, to: start) ?? start }
    let shown = days.filter { $0 <= last }
    let thresholds = heatmapThresholds(shown.map { counts[$0] ?? 0 })
    let cells: [HeatmapCell?] = days.map { day in
        guard day <= last else { return nil }
        let count = counts[day] ?? 0
        return HeatmapCell(date: day, count: count, level: heatmapLevel(count, thresholds: thresholds))
    }
    let columns = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    let weekStarts = stride(from: 0, to: days.count, by: 7).map { days[$0] }
    return Heatmap(
        columns: columns,
        months: heatmapMonths(weekStarts, calendar: sundays),
        total: shown.reduce(0) { $0 + (counts[$1] ?? 0) }
    )
}

/// Labels each column whose week starts in a different month from the column before; the first column is labelled
/// only when the next label is at least three columns away, so the two never overlap.
func heatmapMonths(_ weekStarts: [Date], calendar: Calendar) -> [HeatmapMonth] {
    let months = weekStarts.map { calendar.component(.month, from: $0) }
    var labels = months.indices.filter { $0 > 0 && months[$0] != months[$0 - 1] }
    if !months.isEmpty, (labels.first ?? Int.max) >= 3 { labels.insert(0, at: 0) }
    return labels.map { HeatmapMonth(column: $0, name: calendar.shortMonthSymbols[months[$0] - 1]) }
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

private func sundayFirst(_ calendar: Calendar) -> Calendar {
    var sundays = calendar
    sundays.firstWeekday = 1
    return sundays
}

/// Everything the statistics window shows for one period: the year heatmap, and every cohort member's stats for the
/// period, where the cohort is the teams' human members plus you. Members and you come from the history, so a cached
/// history renders the same before any refresh.
public struct StatsReport: Equatable, Sendable {
    public let me: String?
    public let interval: DateInterval
    public let heatmap: Heatmap
    public let rows: [ReviewerStats]
    public let canGoBack: Bool

    public init(history: ReviewHistory, period: StatsPeriod, offset: Int, now: Date, calendar: Calendar) {
        me = history.me
        interval = periodInterval(period, offset: offset, containing: now, calendar: calendar)
        let counts = history.me.map { dailyReviewCounts(history.prs, reviewer: $0, calendar: calendar) } ?? [:]
        heatmap = ReviewQueueCore.heatmap(counts, today: now, calendar: calendar)
        let cohort = unique(history.members + (history.me.map { [$0] } ?? [])).filter { !$0.hasSuffix("[bot]") }
        rows = reviewerStats(history.prs, in: interval, reviewers: cohort, calendar: calendar)
        canGoBack = interval.start > heatmapStart(today: now, calendar: calendar)
    }

    public var mine: ReviewerStats? { rows.first { $0.login == me } }

    public func benchmark(_ metric: StatsMetric) -> Benchmark {
        ReviewQueueCore.benchmark(mine.flatMap(metric.value), among: rows.map(metric.value), isLowerBetter: metric.isLowerBetter)
    }
}
