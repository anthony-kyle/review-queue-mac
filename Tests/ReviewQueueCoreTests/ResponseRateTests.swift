import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct ResponseRateTests {
    private let teams = ["acme/ruru": ["me", "ana", "bo", "cy"]]
    private let monday = "2026-11-02T10:00:00Z"

    private func pr(
        _ number: Int = 1,
        author: String = "cy",
        created: String = "2026-11-02T10:00:00Z",
        ready: String? = nil,
        merged: String? = nil,
        requests: [HistoryRequest],
        removals: [HistoryRequest] = [],
        reviews: [HistoryReview] = []
    ) -> HistoryPr {
        HistoryPr(
            repo: "acme/web", number: number, author: author, createdAt: at(created), updatedAt: at(created),
            readyAt: ready.map(at), mergedAt: merged.map(at), closedAt: merged.map(at),
            requests: requests, removals: removals, reviews: reviews
        )
    }

    private func chance(_ pr: HistoryPr, for person: String = "me", now: Date = farFuture) -> Opportunity? {
        opportunities(pr, teams: teams, now: now, calendar: utc()).first { $0.reviewer == person }
    }

    @Test func aRequestIsDueOneBusinessDayLaterSkippingWeekends() {
        let calendar = utc()
        #expect(businessDeadline(from: at("2026-11-02T10:00:00Z"), calendar: calendar) == at("2026-11-03T10:00:00Z"))
        #expect(businessDeadline(from: at("2026-11-06T16:00:00Z"), calendar: calendar) == at("2026-11-09T16:00:00Z"))
        #expect(businessDeadline(from: at("2026-11-07T10:00:00Z"), calendar: calendar) == at("2026-11-10T00:00:00Z"))
        #expect(businessDeadline(from: at("2026-11-08T23:00:00Z"), calendar: calendar) == at("2026-11-10T00:00:00Z"))
        var auckland = utc()
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        #expect(businessDeadline(from: at("2026-11-06T03:00:00Z"), calendar: auckland) == at("2026-11-09T03:00:00Z"))
        #expect(businessDeadline(from: at("2026-11-06T12:00:00Z"), calendar: auckland) == at("2026-11-09T11:00:00Z"))
    }

    @Test func aReviewIsOnTimeUpToTheDeadlineAndLateAfter() {
        let asked = [HistoryRequest(reviewer: "me", at: at(monday))]
        let onTime = chance(pr(requests: asked, reviews: [review("me", "APPROVED", "2026-11-03T10:00:00Z")]))
        #expect(onTime == Opportunity(reviewer: "me", start: at(monday), deadline: at("2026-11-03T10:00:00Z"), outcome: .onTime, at: at("2026-11-03T10:00:00Z"), wait: 24 * hour))
        let late = chance(pr(requests: asked, reviews: [review("me", "APPROVED", "2026-11-03T10:00:01Z")]))
        #expect(late?.outcome == .late)
        #expect(late?.at == at("2026-11-03T10:00:00Z"))
        #expect(late?.wait == 24 * hour + 1)
    }

    @Test func aNameAndATeamRequestGiveOnePersonOneOpportunityFromTheEarliest() {
        let both = pr(requests: [HistoryRequest(team: "acme/ruru", at: at("2026-11-02T12:00:00Z")), HistoryRequest(reviewer: "me", at: at(monday))])
        let all = opportunities(both, teams: teams, now: farFuture, calendar: utc())
        #expect(all.map(\.reviewer) == ["ana", "bo", "me"])
        #expect(all.first { $0.reviewer == "me" }?.start == at(monday))
        #expect(all.first { $0.reviewer == "ana" }?.start == at("2026-11-02T12:00:00Z"))
        #expect(chance(pr(requests: [HistoryRequest(team: "acme/other", at: at(monday))])) == nil)
    }

    @Test func theAuthorIsNeverAsked() {
        let own = pr(author: "me", requests: [HistoryRequest(team: "acme/ruru", at: at(monday)), HistoryRequest(reviewer: "me", at: at(monday))])
        #expect(chance(own) == nil)
    }

    @Test func aDraftRequestStartsWhenThePrIsReady() {
        let draft = pr(ready: "2026-11-04T09:00:00Z", requests: [HistoryRequest(reviewer: "me", at: at(monday))])
        #expect(chance(draft)?.start == at("2026-11-04T09:00:00Z"))
        #expect(chance(draft)?.deadline == at("2026-11-05T09:00:00Z"))
    }

    @Test func aRequestResolvedBeforeItsDeadlineIsDropped() {
        let asked = [HistoryRequest(reviewer: "me", at: at(monday))]
        #expect(chance(pr(merged: "2026-11-02T20:00:00Z", requests: asked)) == nil)
        #expect(chance(pr(requests: asked, removals: [HistoryRequest(reviewer: "me", at: at("2026-11-02T11:00:00Z"))])) == nil)
        #expect(chance(pr(requests: asked, removals: [HistoryRequest(reviewer: "ana", at: at("2026-11-02T11:00:00Z"))]))?.outcome == .missed)
        let teamRemoved = pr(requests: [HistoryRequest(team: "acme/ruru", at: at(monday))], removals: [HistoryRequest(team: "acme/ruru", at: at("2026-11-02T11:00:00Z"))])
        #expect(opportunities(teamRemoved, teams: teams, now: farFuture, calendar: utc()).isEmpty)
        #expect(chance(pr(merged: "2026-11-05T00:00:00Z", requests: asked))?.outcome == .missed)
    }

    @Test func anUnansweredRequestIsMissedAtItsDeadlineOrPendingBeforeIt() {
        let asked = pr(requests: [HistoryRequest(reviewer: "me", at: at(monday))])
        let missed = chance(asked)
        #expect(missed?.outcome == .missed)
        #expect(missed?.at == at("2026-11-03T10:00:00Z"))
        #expect(missed?.wait == nil)
        #expect(chance(asked, now: at("2026-11-03T09:00:00Z"))?.outcome == .pending)
        let november = DateInterval(start: at("2026-11-01T00:00:00Z"), end: at("2026-12-01T00:00:00Z"))
        let row = reviewerStats([asked], in: november, reviewers: ["me"], teams: teams, now: at("2026-11-03T09:00:00Z"), calendar: utc()).first
        #expect(row?.pending == 1)
        #expect(row?.responseRate == nil)
    }

    @Test func theRateIsOnTimeOverEverythingDueAndRanksHighestFirst() {
        #expect(stats("me", onTime: 19, late: 2, missed: 1).responseRate == 19.0 / 22)
        #expect(stats("me").responseRate == nil)
        #expect(StatsMetric.responseRate.text(stats("me")) == "—")
        #expect(!StatsMetric.responseRate.isLowerBetter)
        let rates = [stats("me", onTime: 3, late: 1), stats("ana", onTime: 1, missed: 1), stats("bo", onTime: 4), stats("cy")].map(StatsMetric.responseRate.value)
        #expect(benchmark(rates[0], among: rates, isLowerBetter: false) == Benchmark(median: 0.75, rank: 2, cohort: 3))
        #expect(benchmark(rates[3], among: rates, isLowerBetter: false).rank == nil)
    }

    @Test func pickingUpTeamPrsOnTimeRanksYouFirstAndIdleTeammatesAtZero() {
        let november = DateInterval(start: at("2026-11-01T00:00:00Z"), end: at("2026-12-01T00:00:00Z"))
        let prs = (2...6).map { day in
            pr(day, author: "zed", created: String(format: "2026-11-%02dT09:00:00Z", day), requests: [HistoryRequest(team: "acme/ruru", at: at(String(format: "2026-11-%02dT09:00:00Z", day)))], reviews: [
                review("me", "APPROVED", String(format: "2026-11-%02dT20:00:00Z", day)),
            ])
        }
        let rows = reviewerStats(prs, in: november, reviewers: ["me", "ana", "bo", "cy"], teams: teams, now: farFuture, calendar: utc())
        #expect(rows.map(\.responseRate) == [1, 0, 0, 0])
        #expect(rows.map(\.firstResponses) == [5, 0, 0, 0])
        let rates = rows.map(StatsMetric.responseRate.value)
        #expect(benchmark(rates[0], among: rates, isLowerBetter: false) == Benchmark(median: 0, rank: 1, cohort: 4))
        #expect(rows[0].medianResponse == 11 * hour)
    }

    @Test func firstResponsesNeedARequestAndNeverCountTheAuthor() {
        let asked = pr(requests: [HistoryRequest(reviewer: "me", at: at(monday))], reviews: [review("me", "COMMENTED", "2026-11-02T11:00:00Z"), review("ana", "APPROVED", "2026-11-02T12:00:00Z")])
        #expect(firstResponder(asked, teams: teams)?.author == "me")
        let unasked = pr(requests: [HistoryRequest(reviewer: "ana", at: at(monday))], reviews: [review("me", "COMMENTED", "2026-11-02T11:00:00Z")])
        #expect(firstResponder(unasked, teams: teams) == nil)
        let authorFirst = pr(author: "ana", requests: [HistoryRequest(team: "acme/ruru", at: at(monday))], reviews: [review("ana", "COMMENTED", "2026-11-02T10:30:00Z"), review("bo", "APPROVED", "2026-11-02T11:00:00Z")])
        #expect(firstResponder(authorFirst, teams: teams)?.author == "bo")
    }

    @Test func ownSpeedIsUnrankedAndOnlyFromAnsweredRequests() {
        #expect(!StatsMetric.ownSpeed.isRanked)
        #expect(StatsMetric.allCases.filter(\.isRanked) == [.reviews, .approved, .changesRequested, .responseRate, .firstResponses, .unblocked])
        #expect(StatsMetric.ownSpeed.trendTitle == "Your response time")
        let november = DateInterval(start: at("2026-11-01T00:00:00Z"), end: at("2026-12-01T00:00:00Z"))
        let prs = [
            pr(1, requests: [HistoryRequest(reviewer: "me", at: at(monday))], reviews: [review("me", "COMMENTED", "2026-11-02T12:00:00Z")]),
            pr(2, requests: [HistoryRequest(reviewer: "me", at: at(monday))], reviews: [review("me", "COMMENTED", "2026-11-04T10:00:00Z")]),
            pr(3, requests: [HistoryRequest(reviewer: "me", at: at(monday))]),
            pr(4, requests: [], reviews: [review("me", "COMMENTED", "2026-11-02T12:00:00Z")]),
        ]
        let row = reviewerStats(prs, in: november, reviewers: ["me"], teams: teams, now: farFuture, calendar: utc()).first
        #expect(row?.responseTimes.sorted() == [2 * hour, 48 * hour])
        #expect((row?.onTime, row?.late, row?.missed) == (1, 1, 1))
    }

    @Test func theTrendsLastPointMatchesTheCardsForEveryMetric() {
        let demoNow = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: demoNow)
        let history = demo.reviewHistory.counted(demo.settings)
        for period in StatsPeriod.allCases {
            let report = StatsReport(history: history, period: period, offset: 0, cycles: demo.cycles, now: demoNow, calendar: .current)
            let last = trend(period, endingAt: 0, history: history, cycles: demo.cycles, now: demoNow, calendar: .current).last
            for metric in StatsMetric.allCases {
                #expect(last.flatMap { $0.mine.flatMap(metric.value) } == report.mine.flatMap(metric.value))
                #expect(last?.benchmark(metric) == report.benchmark(metric))
            }
        }
    }
}
