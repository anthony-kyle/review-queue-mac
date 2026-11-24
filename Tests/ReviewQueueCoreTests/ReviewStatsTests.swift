import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct ReviewStatsTests {
    @Test func weeksFollowTheCalendarsFirstWeekday() {
        let wednesday = at("2026-11-25T15:00:00Z")
        #expect(periodInterval(.week, containing: wednesday, calendar: utc(firstWeekday: 2)) == span("2026-11-23", "2026-11-30"))
        #expect(periodInterval(.week, containing: wednesday, calendar: utc(firstWeekday: 1)) == span("2026-11-22", "2026-11-29"))
        #expect(periodInterval(.week, offset: -1, containing: wednesday, calendar: utc(firstWeekday: 2)) == span("2026-11-16", "2026-11-23"))
    }

    @Test func monthsQuartersAndYearsAreCalendarPeriodsThatShift() {
        let calendar = utc()
        let date = at("2026-11-25T15:00:00Z")
        #expect(periodInterval(.month, containing: date, calendar: calendar) == span("2026-11-01", "2026-12-01"))
        #expect(periodInterval(.month, offset: -11, containing: date, calendar: calendar) == span("2025-12-01", "2026-01-01"))
        #expect(periodInterval(.quarter, containing: date, calendar: calendar) == span("2026-10-01", "2027-01-01"))
        #expect(periodInterval(.quarter, offset: -1, containing: date, calendar: calendar) == span("2026-07-01", "2026-10-01"))
        #expect(periodInterval(.quarter, containing: at("2026-02-14T00:00:00Z"), calendar: calendar) == span("2026-01-01", "2026-04-01"))
        #expect(periodInterval(.year, offset: -1, containing: date, calendar: calendar) == span("2025-01-01", "2026-01-01"))
    }

    @Test func periodsAndDaysUseTheCalendarsTimeZone() {
        var auckland = utc()
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let lateUtc = at("2026-11-30T12:00:00Z")
        #expect(periodInterval(.month, containing: lateUtc, calendar: auckland)?.start == at("2026-11-30T11:00:00Z"))
        let pr = HistoryPr(repo: "o/r", number: 1, author: "a", createdAt: lateUtc, updatedAt: lateUtc, reviews: [
            review("me", "COMMENTED", "2026-11-30T10:00:00Z"),
            review("me", "COMMENTED", "2026-11-30T12:00:00Z"),
        ])
        #expect(dailyReviewCounts([pr], reviewer: "me", calendar: utc()).count == 1)
        #expect(dailyReviewCounts([pr], reviewer: "me", calendar: auckland).count == 2)
    }

    @Test func reviewsCountEachPrOncePerDay() {
        let prs = [
            pr(1, reviews: [review("me", "COMMENTED", "2026-11-02T09:00:00Z"), review("me", "APPROVED", "2026-11-02T17:00:00Z"), review("me", "COMMENTED", "2026-11-03T09:00:00Z")]),
            pr(2, reviews: [review("me", "CHANGES_REQUESTED", "2026-11-02T10:00:00Z")]),
        ]
        let stats = reviewerStats(prs, in: november, reviewers: ["me"], calendar: utc())
        #expect(stats.first?.reviews == 3)
        #expect(dailyReviewCounts(prs, reviewer: "me", calendar: utc()) == [at("2026-11-02T00:00:00Z"): 2, at("2026-11-03T00:00:00Z"): 1])
    }

    @Test func approvalsAndChangesRequestsCountDistinctPrsInThePeriod() {
        let prs = [
            pr(1, reviews: [review("me", "APPROVED", "2026-11-02T09:00:00Z"), review("me", "APPROVED", "2026-11-05T09:00:00Z")]),
            pr(2, reviews: [review("me", "CHANGES_REQUESTED", "2026-11-02T09:00:00Z"), review("me", "APPROVED", "2026-11-03T09:00:00Z")]),
            pr(3, reviews: [review("me", "APPROVED", "2026-10-30T09:00:00Z")]),
        ]
        let stats = reviewerStats(prs, in: november, reviewers: ["me"], calendar: utc()).first
        #expect(stats?.approved == 2)
        #expect(stats?.changesRequested == 1)
    }

    @Test func ownPrsBotsDismissedAndPendingReviewsDoNotCount() {
        let prs = [
            pr(1, author: "me", reviews: [review("me", "COMMENTED", "2026-11-02T09:00:00Z")]),
            pr(2, reviews: [
                review("me", "DISMISSED", "2026-11-02T09:00:00Z"),
                review("me", "PENDING", "2026-11-02T10:00:00Z"),
                HistoryReview(author: "renovate[bot]", isBot: true, state: "APPROVED", submittedAt: at("2026-11-02T09:00:00Z")),
            ]),
        ]
        let stats = reviewerStats(prs, in: november, reviewers: ["me", "renovate[bot]"], calendar: utc())
        #expect(stats.map(\.reviews) == [0, 0])
        #expect(stats.allSatisfy { $0.responseTimes.isEmpty })
    }

    @Test func responseStartsAtTheLaterOfReadyAndYourRequest() {
        let created = at("2026-11-02T09:00:00Z")
        let first = at("2026-11-02T15:00:00Z")
        let base = HistoryPr(repo: "o/r", number: 1, author: "a", createdAt: created, updatedAt: first)
        #expect(responseTime(base, reviewer: "me", firstReview: first) == 6 * hour)
        let requested = HistoryPr(repo: "o/r", number: 1, author: "a", createdAt: created, updatedAt: first, requests: [
            HistoryRequest(reviewer: "me", at: at("2026-11-02T13:00:00Z")),
            HistoryRequest(reviewer: "me", at: at("2026-11-02T14:00:00Z")),
            HistoryRequest(reviewer: "other", at: at("2026-11-02T14:30:00Z")),
        ])
        #expect(responseTime(requested, reviewer: "me", firstReview: first) == 2 * hour)
        let readyLater = HistoryPr(repo: "o/r", number: 1, author: "a", createdAt: created, updatedAt: first, readyAt: at("2026-11-02T14:00:00Z"), requests: [
            HistoryRequest(reviewer: "me", at: at("2026-11-02T10:00:00Z")),
        ])
        #expect(responseTime(readyLater, reviewer: "me", firstReview: first) == hour)
    }

    @Test func responseFallsBackToReadyWhenRequestedAfterReviewingAndNeverGoesNegative() {
        let created = at("2026-11-02T09:00:00Z")
        let first = at("2026-11-02T12:00:00Z")
        let lateRequest = HistoryPr(repo: "o/r", number: 1, author: "a", createdAt: created, updatedAt: first, requests: [
            HistoryRequest(reviewer: "me", at: at("2026-11-02T13:00:00Z")),
        ])
        #expect(responseTime(lateRequest, reviewer: "me", firstReview: first) == 3 * hour)
        let readiedAfter = HistoryPr(repo: "o/r", number: 1, author: "a", createdAt: created, updatedAt: first, readyAt: at("2026-11-02T13:00:00Z"))
        #expect(responseTime(readiedAfter, reviewer: "me", firstReview: first) == 0)
    }

    @Test func responseTimeBelongsToThePeriodOfTheFirstReview() {
        let prs = [
            HistoryPr(repo: "o/r", number: 1, author: "a", createdAt: at("2026-10-31T20:00:00Z"), updatedAt: at("2026-11-02T00:00:00Z"), reviews: [
                review("me", "COMMENTED", "2026-10-31T22:00:00Z"),
                review("me", "APPROVED", "2026-11-01T09:00:00Z"),
            ]),
            HistoryPr(repo: "o/r", number: 2, author: "a", createdAt: at("2026-11-03T08:00:00Z"), updatedAt: at("2026-11-03T12:00:00Z"), reviews: [
                review("me", "APPROVED", "2026-11-03T12:00:00Z"),
            ]),
        ]
        let stats = reviewerStats(prs, in: november, reviewers: ["me"], calendar: utc()).first
        #expect(stats?.responseTimes == [4 * hour])
        #expect(stats?.averageResponse == 4 * hour)
        #expect(stats?.reviews == 2)
    }

    @Test func medianTakesTheMiddleOrTheMeanOfTheMiddleTwo() {
        #expect(median([]) == nil)
        #expect(median([5, 1, 3]) == 3)
        #expect(median([4, 1, 3, 10]) == 3.5)
    }

    @Test func ranksShareTiesAndSkipMissingValues() {
        let tied = benchmark(4, among: [4, 4, 4, 1, 0], isLowerBetter: false)
        #expect(tied == Benchmark(median: 4, rank: 1, cohort: 5))
        #expect(tied.topPercent == 20)
        #expect(benchmark(1, among: [4, 4, 1, 0], isLowerBetter: false).rank == 3)
        let faster = benchmark(2 * hour, among: [2 * hour, nil, 5 * hour, hour], isLowerBetter: true)
        #expect(faster == Benchmark(median: 2 * hour, rank: 2, cohort: 3))
        #expect(faster.topPercent == 67)
        #expect(benchmark(nil, among: [nil, hour], isLowerBetter: true) == Benchmark(median: hour, rank: nil, cohort: 1))
    }

    @Test func rankTextUsesEnglishOrdinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 111].map { rankText($0, of: 120) } == [
            "1st of 120", "2nd of 120", "3rd of 120", "4th of 120", "11th of 120", "12th of 120", "13th of 120",
            "21st of 120", "22nd of 120", "23rd of 120", "111th of 120",
        ])
    }

    @Test func leaderboardSortsEitherWayWithMissingValuesLast() {
        let rows = [
            ReviewerStats(login: "b", reviews: 3, responseTimes: [hour]),
            ReviewerStats(login: "a", reviews: 3),
            ReviewerStats(login: "c", reviews: 5, responseTimes: [3 * hour]),
        ]
        #expect(leaderboard(rows, by: .reviews, isAscending: false).map(\.login) == ["c", "a", "b"])
        #expect(leaderboard(rows, by: .reviews, isAscending: true).map(\.login) == ["a", "b", "c"])
        #expect(leaderboard(rows, by: .response, isAscending: true).map(\.login) == ["b", "c", "a"])
        #expect(leaderboard(rows, by: .response, isAscending: false).map(\.login) == ["c", "b", "a"])
    }

    @Test func metricsFormatCountsMediansAndDurations() {
        #expect(StatsMetric.reviews.format(4) == "4")
        #expect(StatsMetric.reviews.format(4.5) == "4.5")
        #expect(StatsMetric.response.format(90 * 60) == "1h")
        #expect(StatsMetric.response.format(nil) == "—")
        #expect(compactDuration(20) == "<1m")
        #expect(compactDuration(3 * 24 * hour) == "3d")
    }

    @Test func heatmapLevelsFollowQuartilesOfBusyDays() {
        let thresholds = heatmapThresholds([0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(thresholds == [2, 4, 6])
        #expect([0, 1, 2, 3, 4, 5, 6, 7, 8].map { heatmapLevel($0, thresholds: thresholds) } == [0, 1, 1, 2, 2, 3, 3, 4, 4])
        #expect(heatmapThresholds([0, 0]) == [])
        #expect(heatmapLevel(3, thresholds: heatmapThresholds([3, 3, 3])) == 1)
    }

    @Test func reportBenchmarksAgainstEveryTeamMemberIncludingIdleOnes() {
        let history = ReviewHistory(me: "me", members: ["me", "ana", "bo", "dependabot[bot]"], prs: [
            pr(1, reviews: [review("me", "APPROVED", "2026-11-02T09:00:00Z"), review("ana", "APPROVED", "2026-11-02T10:00:00Z")]),
            pr(2, reviews: [review("ana", "COMMENTED", "2026-11-03T09:00:00Z"), review("outsider", "APPROVED", "2026-11-03T09:00:00Z")]),
        ])
        let report = StatsReport(history: history, period: .month, offset: 0, now: at("2026-11-25T15:00:00Z"), calendar: utc())
        #expect(report.rows.map(\.login) == ["me", "ana", "bo"])
        #expect(report.mine?.reviews == 1)
        #expect(report.benchmark(.reviews) == Benchmark(median: 1, rank: 2, cohort: 3))
        #expect(report.benchmark(.response).cohort == 2)
        #expect(report.graph.total == 1)
        #expect(report.span.canGoBack)
        #expect(!StatsReport(history: history, period: .year, offset: -1, now: at("2026-11-25T15:00:00Z"), calendar: utc()).span.canGoBack)
    }

    private var november: DateInterval { span("2026-11-01", "2026-12-01") }
}

let hour: TimeInterval = 3600

func at(_ iso: String) -> Date {
    (try? Date(iso, strategy: .iso8601)) ?? .distantPast
}

func utc(firstWeekday: Int = 1) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = firstWeekday
    return calendar
}

func review(_ author: String, _ state: String, _ submitted: String) -> HistoryReview {
    HistoryReview(author: author, state: state, submittedAt: at(submitted))
}

private func span(_ start: String, _ end: String) -> DateInterval {
    DateInterval(start: at("\(start)T00:00:00Z"), end: at("\(end)T00:00:00Z"))
}

private func pr(_ number: Int, author: String = "author", reviews: [HistoryReview]) -> HistoryPr {
    HistoryPr(repo: "acme/widgets", number: number, author: author, createdAt: at("2026-10-01T00:00:00Z"), updatedAt: at("2026-11-20T00:00:00Z"), reviews: reviews)
}
