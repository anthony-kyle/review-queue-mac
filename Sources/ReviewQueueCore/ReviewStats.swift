import Foundation

private let countedStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]

/// How long a ready PR must have gone without any review for its first reviewer to count as unblocking it.
public let unblockedWait: TimeInterval = 72 * 60 * 60

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

/// One reviewer's numbers for a period. `reviews` counts distinct PR-days. Review requests to this reviewer (see
/// `opportunities`) count as `onTime`, `late` or `missed`, or `pending` while their deadline is ahead; `responseTimes`
/// holds the time to first review on each request they answered. `firstResponses` counts PRs they were asked on and
/// reviewed first; `unblocked` counts PRs they were first to review after they had waited `unblockedWait`. `merged` and
/// `closed` count PRs they merged or closed unmerged, with `completedByAuthor` splitting both by whose PR it was.
public struct ReviewerStats: Equatable, Sendable {
    public let login: String
    public var reviews = 0
    public var approved = 0
    public var changesRequested = 0
    public var onTime = 0
    public var late = 0
    public var missed = 0
    public var pending = 0
    public var responseTimes: [TimeInterval] = []
    public var firstResponses = 0
    public var unblocked = 0
    public var merged = 0
    public var closed = 0
    public var completedByAuthor: [CompletionAuthor: Int] = [:]

    public init(login: String) {
        self.login = login
    }

    /// Requests answered within a business day, out of all requests that have come due; nil when none have.
    public var responseRate: Double? {
        let due = onTime + late + missed
        return due == 0 ? nil : Double(onTime) / Double(due)
    }

    public var medianResponse: TimeInterval? { median(responseTimes) }

    public var completed: Int { merged + closed }
}

/// Whose PR a reviewer merged or closed: their own, a teammate's (anyone else in the cohort), a bot's (only allowed bots'
/// PRs are counted at all), or someone else's.
public enum CompletionAuthor: String, CaseIterable, Sendable {
    case own, teammate, other, bot

    public var label: String {
        switch self {
        case .own: "yours"
        case .teammate: "teammates'"
        case .other: "others'"
        case .bot: "bots'"
        }
    }
}

/// Who completed a PR and when: whoever merged it, at the merge, or for a PR closed unmerged, whoever closed it last, at
/// that close. Nil while open or when GitHub names no one.
func completion(_ pr: HistoryPr) -> (actor: String, at: Date, isMerged: Bool)? {
    if let at = pr.mergedAt {
        return pr.mergedBy.map { ($0, at, true) }
    }
    guard let at = pr.closedAt, let actor = pr.closedBy else { return nil }
    return (actor, at, false)
}

/// What the statistics compare, with how each reads from a reviewer's stats. Every metric but your own response time is
/// ranked, higher being better; own speed is for you alone and sorts fastest first.
public enum StatsMetric: String, CaseIterable, Identifiable, Sendable {
    case reviews, approved, changesRequested, completed, responseRate, firstResponses, unblocked, merged, closed, ownSpeed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .reviews: "Reviews done"
        case .approved: "PRs approved"
        case .changesRequested: "Changes requested"
        case .responseRate: "Response rate"
        case .firstResponses: "First responses"
        case .unblocked: "Unblocked"
        case .completed: "PRs completed"
        case .merged: "Merged"
        case .closed: "Closed"
        case .ownSpeed: "Median response"
        }
    }

    /// The name in the trend's metric menu, where own speed reads as yours.
    public var trendTitle: String {
        self == .ownSpeed ? "Your response time" : title
    }

    public var isRanked: Bool { self != .ownSpeed }

    /// Whether the metric has its own card; merged and closed are folded into PRs completed.
    public var isCard: Bool { isRanked && self != .merged && self != .closed }

    public var isLowerBetter: Bool { self == .ownSpeed }

    public func value(_ stats: ReviewerStats) -> Double? {
        switch self {
        case .reviews: Double(stats.reviews)
        case .approved: Double(stats.approved)
        case .changesRequested: Double(stats.changesRequested)
        case .responseRate: stats.responseRate
        case .firstResponses: Double(stats.firstResponses)
        case .unblocked: Double(stats.unblocked)
        case .completed: Double(stats.completed)
        case .merged: Double(stats.merged)
        case .closed: Double(stats.closed)
        case .ownSpeed: stats.medianResponse
        }
    }

    public func text(_ stats: ReviewerStats) -> String {
        format(value(stats))
    }

    /// A value as the window shows it: a whole percentage for the response rate, a compact duration for own speed,
    /// otherwise a count with at most one decimal (medians can fall between two); an em dash when missing.
    public func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        switch self {
        case .responseRate: return value.formatted(.percent.precision(.fractionLength(0)))
        case .ownSpeed: return compactDuration(value)
        default: return value.formatted(.number.precision(.fractionLength(0...1)))
        }
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

/// The moment a request is due: one business day after `start`, skipping Saturdays and Sundays as `calendar` sees them,
/// so a Friday 16:00 request is due Monday 16:00. A request made at the weekend counts from 00:00 the next working day.
/// No public holidays.
public func businessDeadline(from start: Date, calendar: Calendar) -> Date {
    var from = start
    while calendar.isDateInWeekend(from) {
        from = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86_400))
    }
    var due = calendar.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86_400)
    while calendar.isDateInWeekend(due) {
        due = calendar.date(byAdding: .day, value: 1, to: due) ?? due.addingTimeInterval(86_400)
    }
    return due
}

/// How one request to one person turned out.
enum Outcome: Equatable, Sendable {
    case onTime, late, missed, pending
}

/// A person's chance to respond on a PR: asked from `start`, due at `deadline`, with its `outcome`, the time it counts
/// at, and the time to their first review when they gave one.
struct Opportunity: Equatable, Sendable {
    let reviewer: String
    let start: Date
    let deadline: Date
    let outcome: Outcome
    let at: Date
    let wait: TimeInterval?
}

/// Who was asked to review a PR: everyone named, and every member of a requested team in `teams` (other teams are
/// ignored), never the author or bots, each with the requests that reached them.
func requestedReviewers(_ pr: HistoryPr, teams: [String: [String]]) -> [String: [HistoryRequest]] {
    var asked: [String: [HistoryRequest]] = [:]
    for request in pr.requests {
        let people = request.reviewer.map { [$0] } ?? request.team.flatMap { teams[$0] } ?? []
        for person in people where person != pr.author && !person.hasSuffix("[bot]") {
            asked[person, default: []].append(request)
        }
    }
    return asked
}

/// Everyone's one opportunity on a PR. It starts at their earliest request (by name or through a team), or when the PR
/// became ready if that was later, and is due a business day on. Their first review by then is on time and counts when
/// given; a later review is late and counts at the deadline. With no review, a request removed or a PR merged or closed
/// before the deadline drops the opportunity; otherwise it is missed at the deadline, or pending while the deadline is
/// still after `now`.
func opportunities(_ pr: HistoryPr, teams: [String: [String]], now: Date, calendar: Calendar) -> [Opportunity] {
    let firstReview = Dictionary(grouping: countedReviews(pr), by: \.author).compactMapValues { $0.map(\.submittedAt).min() }
    var deadlines: [Date: Date] = [:]
    return requestedReviewers(pr, teams: teams).compactMap { person, requests in
        guard let earliest = requests.map(\.at).min() else { return nil }
        let start = max(earliest, pr.readyTime)
        let deadline = deadlines[start] ?? businessDeadline(from: start, calendar: calendar)
        deadlines[start] = deadline
        let first = firstReview[person]
        let wait = first.map { max(0, $0.timeIntervalSince(start)) }
        if let first, first <= deadline {
            return Opportunity(reviewer: person, start: start, deadline: deadline, outcome: .onTime, at: first, wait: wait)
        }
        let removed = pr.removals.filter { removal in removal.at >= earliest && requests.contains { removal.isSameTarget(as: $0) } }.map(\.at).min()
        if let resolved = [removed, pr.endedAt].compactMap(\.self).min(), resolved < deadline, first.map({ resolved < $0 }) ?? true {
            return nil
        }
        if first != nil {
            return Opportunity(reviewer: person, start: start, deadline: deadline, outcome: .late, at: deadline, wait: wait)
        }
        return Opportunity(reviewer: person, start: start, deadline: deadline, outcome: deadline > now ? .pending : .missed, at: deadline, wait: nil)
    }
    .sorted { $0.reviewer < $1.reviewer }
}

/// The reviewer who gave a PR its first review, when they had been asked to (by name or through a known team).
func firstResponder(_ pr: HistoryPr, teams: [String: [String]]) -> HistoryReview? {
    guard let first = countedReviews(pr).min(by: { $0.submittedAt < $1.submittedAt }),
          requestedReviewers(pr, teams: teams)[first.author] != nil else { return nil }
    return first
}

/// How many PRs were waiting for a first review at `moment`: open (created by then and not yet merged or closed), ready
/// for review by then, and with no review counted yet from anyone but the author or bots.
public func waitingForReview(_ prs: [HistoryPr], at moment: Date) -> Int {
    prs.count { pr in
        pr.createdAt <= moment
            && pr.endedAt.map { $0 > moment } ?? true
            && pr.readyTime <= moment
            && !countedReviews(pr).contains { $0.submittedAt <= moment }
    }
}

/// The reviewer who first reviewed a PR that had waited at least `unblockedWait` since it was ready, and when.
func unblocker(_ pr: HistoryPr) -> HistoryReview? {
    guard let first = countedReviews(pr).min(by: { $0.submittedAt < $1.submittedAt }),
          first.submittedAt.timeIntervalSince(pr.readyTime) >= unblockedWait else { return nil }
    return first
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

/// What period stats need from each PR of a history, worked out once so every period and trend point only filters by
/// time: counted reviews by reviewer, everyone's request opportunity (deadlines and outcomes as of `now`), the first
/// responder, the unblocker and who completed it, plus your reviews per day for the graph.
public struct StatsIndex: Sendable {
    struct Entry: Sendable {
        let reviews: [String: [HistoryReview]]
        let opportunities: [Opportunity]
        let firstResponder: HistoryReview?
        let unblocker: HistoryReview?
        let completion: (actor: String, at: Date, isMerged: Bool)?
        let author: String
        let isBotAuthored: Bool
    }

    public let history: ReviewHistory
    public let now: Date
    let calendar: Calendar
    let entries: [Entry]
    let dailyCounts: [Date: Int]

    public init(history: ReviewHistory, now: Date, calendar: Calendar) {
        self.history = history
        self.now = now
        self.calendar = calendar
        entries = history.prs.map { pr in
            Entry(
                reviews: Dictionary(grouping: countedReviews(pr), by: \.author),
                opportunities: opportunities(pr, teams: history.teamMembers, now: now, calendar: calendar),
                firstResponder: firstResponder(pr, teams: history.teamMembers),
                unblocker: unblocker(pr),
                completion: completion(pr),
                author: pr.author,
                isBotAuthored: pr.isBotAuthored
            )
        }
        dailyCounts = history.me.map { dailyReviewCounts(history.prs, reviewer: $0, calendar: calendar) } ?? [:]
    }
}

/// Each of `reviewers`' stats in `interval`, in the given order, with zeros for anyone who did not review there.
func reviewerStats(_ index: StatsIndex, in interval: DateInterval, reviewers: [String]) -> [ReviewerStats] {
    var stats = Dictionary(reviewers.map { ($0, ReviewerStats(login: $0)) }, uniquingKeysWith: { first, _ in first })
    for entry in index.entries {
        for (reviewer, reviews) in entry.reviews where stats[reviewer] != nil {
            let inside = reviews.filter { interval.holds($0.submittedAt) }
            stats[reviewer]?.reviews += Set(inside.map { index.calendar.startOfDay(for: $0.submittedAt) }).count
            if inside.contains(where: { $0.state == "APPROVED" }) { stats[reviewer]?.approved += 1 }
            if inside.contains(where: { $0.state == "CHANGES_REQUESTED" }) { stats[reviewer]?.changesRequested += 1 }
        }
        for chance in entry.opportunities where stats[chance.reviewer] != nil && interval.holds(chance.at) {
            switch chance.outcome {
            case .onTime: stats[chance.reviewer]?.onTime += 1
            case .late: stats[chance.reviewer]?.late += 1
            case .missed: stats[chance.reviewer]?.missed += 1
            case .pending: stats[chance.reviewer]?.pending += 1
            }
            if let wait = chance.wait { stats[chance.reviewer]?.responseTimes.append(wait) }
        }
        if let first = entry.firstResponder, interval.holds(first.submittedAt) { stats[first.author]?.firstResponses += 1 }
        if let first = entry.unblocker, interval.holds(first.submittedAt) { stats[first.author]?.unblocked += 1 }
        if let done = entry.completion, stats[done.actor] != nil, interval.holds(done.at) {
            if done.isMerged { stats[done.actor]?.merged += 1 } else { stats[done.actor]?.closed += 1 }
            let whose: CompletionAuthor = entry.author == done.actor ? .own
                : entry.isBotAuthored ? .bot
                : stats[entry.author] != nil ? .teammate : .other
            stats[done.actor]?.completedByAuthor[whose, default: 0] += 1
        }
    }
    return unique(reviewers).compactMap { stats[$0] }
}

/// `reviewerStats` over loose PRs, with team requests expanding through `teams` (members by `org/slug`); deadlines
/// skip `calendar`'s weekends and are pending until `now` passes them.
public func reviewerStats(
    _ prs: [HistoryPr],
    in interval: DateInterval,
    reviewers: [String],
    teams: [String: [String]],
    now: Date,
    calendar: Calendar
) -> [ReviewerStats] {
    reviewerStats(StatsIndex(history: ReviewHistory(teamMembers: teams, prs: prs), now: now, calendar: calendar), in: interval, reviewers: reviewers)
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

/// The period graph's fixed geometry: one label row (weekdays or months) above a days area of the same height for every
/// period, so switching period never moves what is below. Calendar rows share the days area up to a cap, and cells
/// shorter than `compactBelow` put the date and count on one line.
public enum GraphLayout {
    public static let labelRow: Double = 16
    public static let labelGap: Double = 3
    public static let daysHeight: Double = 132
    public static let calendarGap: Double = 3
    public static let heatmapGap: Double = 2
    public static let maxRow: Double = 34
    public static let compactBelow: Double = 28

    public static var blockHeight: Double { labelRow + labelGap + daysHeight }

    /// The height of each of `rows` rows sharing the days area with `gap` between them, whole points, capped at `maxRow`.
    public static func rowHeight(rows: Int, gap: Double) -> Double {
        let count = Double(max(rows, 1))
        return min(maxRow, ((daysHeight - (count - 1) * gap) / count).rounded(.down))
    }

    public static func isCompact(_ height: Double) -> Bool {
        height < compactBelow
    }
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
/// your standing against the team, and the team's review backlog when the span ended (or now, while it runs). The
/// cards, the leaderboard and each trend point all read from this.
public struct PeriodStats: Equatable, Sendable {
    public let span: PeriodSpan
    public let me: String?
    public let rows: [ReviewerStats]
    public let waiting: Int

    public init(index: StatsIndex, span: PeriodSpan) {
        let history = index.history
        self.span = span
        me = history.me
        waiting = waitingForReview(history.prs, at: min(span.interval.end, index.now))
        let cohort = unique(history.members + (history.me.map { [$0] } ?? [])).filter { !$0.hasSuffix("[bot]") }
        rows = reviewerStats(index, in: span.interval, reviewers: cohort)
    }

    public init(history: ReviewHistory, span: PeriodSpan, now: Date, calendar: Calendar) {
        self.init(index: StatsIndex(history: history, now: now, calendar: calendar), span: span)
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

    public init(index: StatsIndex, period: StatsPeriod, offset: Int, cycles: [LinearCycle] = []) {
        let now = index.now
        let calendar = index.calendar
        stats = PeriodStats(index: index, span: periodSpan(period, offset: offset, cycles: cycles, now: now, calendar: calendar))
        let counts = index.dailyCounts
        graph = periodGraph(stats.span.interval, style: GraphStyle(period), counts: counts, thresholds: heatmapThresholds(Array(counts.values)), today: now, calendar: calendar)
    }

    public init(history: ReviewHistory, period: StatsPeriod, offset: Int, cycles: [LinearCycle] = [], now: Date, calendar: Calendar) {
        self.init(index: StatsIndex(history: history, now: now, calendar: calendar), period: period, offset: offset, cycles: cycles)
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
public func trend(_ period: StatsPeriod, endingAt offset: Int, index: StatsIndex, cycles: [LinearCycle]) -> [PeriodStats] {
    let now = index.now
    let calendar = index.calendar
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
    return spans.map { PeriodStats(index: index, span: $0) }
}

/// `trend` over a history not yet indexed.
public func trend(_ period: StatsPeriod, endingAt offset: Int, history: ReviewHistory, cycles: [LinearCycle], now: Date, calendar: Calendar) -> [PeriodStats] {
    trend(period, endingAt: offset, index: StatsIndex(history: history, now: now, calendar: calendar), cycles: cycles)
}
