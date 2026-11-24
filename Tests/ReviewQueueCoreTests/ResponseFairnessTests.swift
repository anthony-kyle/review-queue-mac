import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct ResponseFairnessTests {
    private let teams = ["acme/web": ["me", "ana", "bo"]]

    @Test func responseTimeIsTheMedianOfSamples() {
        #expect(ReviewerStats(login: "me", responseTimes: [hour, 2 * hour, 100 * hour]).medianResponse == 2 * hour)
        #expect(ReviewerStats(login: "me", responseTimes: [hour, 3 * hour]).medianResponse == 2 * hour)
        #expect(ReviewerStats(login: "me").medianResponse == nil)
        #expect(StatsMetric.response.value(ReviewerStats(login: "me", responseTimes: [hour, 9 * hour, 2 * hour])) == 2 * hour)
        #expect(StatsMetric.response.title == "Median time to respond")
    }

    @Test func teamRequestsCountForKnownMembersOnly() {
        let known = pr(requests: [HistoryRequest(team: "acme/web", at: at("2026-11-02T10:00:00Z"))])
        #expect(answeredWait(known, by: "me", at: at("2026-11-02T12:00:00Z"), teams: teams) == 2 * hour)
        let unknown = pr(requests: [HistoryRequest(team: "acme/other", at: at("2026-11-02T10:00:00Z"))])
        #expect(answeredWait(unknown, by: "me", at: at("2026-11-02T12:00:00Z"), teams: teams) == 3 * hour)
        #expect(responseSamples(unknown, teams: teams, now: farFuture).isEmpty)
    }

    @Test func aTeamRequestAnsweredByAnyMemberPenalisesNoOne() {
        let answered = pr(
            requests: [HistoryRequest(team: "acme/web", at: at("2026-11-02T10:00:00Z"))],
            reviews: [review("ana", "APPROVED", "2026-11-02T11:00:00Z")]
        )
        let samples = responseSamples(answered, teams: teams, now: farFuture)
        #expect(samples.map(\.reviewer) == ["ana"])
        #expect(samples.allSatisfy { $0.isAnswered })
    }

    @Test func anUnansweredRequestWaitsUntilRemovedMergedClosedOrNow() {
        let asked = [HistoryRequest(reviewer: "me", at: at("2026-11-02T10:00:00Z"))]
        func wait(_ pr: HistoryPr, now: Date = farFuture) -> ResponseSample? {
            responseSamples(pr, teams: teams, now: now).first { $0.reviewer == "me" }
        }
        let merged = wait(pr(merged: "2026-11-02T15:00:00Z", requests: asked))
        #expect(merged == ResponseSample(reviewer: "me", wait: 5 * hour, at: at("2026-11-02T15:00:00Z"), isAnswered: false))
        #expect(wait(pr(closed: "2026-11-02T14:00:00Z", requests: asked))?.wait == 4 * hour)
        let removals = [
            HistoryRequest(reviewer: "ana", at: at("2026-11-02T11:00:00Z")),
            HistoryRequest(team: "acme/web", at: at("2026-11-02T11:30:00Z")),
            HistoryRequest(reviewer: "me", at: at("2026-11-02T12:00:00Z")),
        ]
        #expect(wait(pr(merged: "2026-11-02T15:00:00Z", requests: asked, removals: removals))?.wait == 2 * hour)
        #expect(wait(pr(requests: asked), now: at("2026-11-02T20:00:00Z"))?.wait == 10 * hour)
    }

    @Test func anUnansweredTeamRequestCountsAgainstEveryMemberButTheAuthor() {
        let ignored = pr(author: "bo", closed: "2026-11-02T13:00:00Z", requests: [HistoryRequest(team: "acme/web", at: at("2026-11-02T10:00:00Z"))])
        let samples = responseSamples(ignored, teams: teams, now: farFuture)
        #expect(samples.map(\.reviewer) == ["ana", "me"])
        #expect(samples.allSatisfy { !$0.isAnswered && $0.wait == 3 * hour })
        let removed = pr(requests: [HistoryRequest(team: "acme/web", at: at("2026-11-02T10:00:00Z"))], removals: [HistoryRequest(team: "acme/web", at: at("2026-11-02T10:30:00Z"))])
        #expect(responseSamples(removed, teams: teams, now: farFuture).map(\.wait) == [hour / 2, hour / 2, hour / 2])
    }

    @Test func requestsOnADraftStartWhenItBecameReady() {
        let draft = pr(ready: "2026-11-02T12:00:00Z", requests: [HistoryRequest(reviewer: "me", at: at("2026-11-02T09:30:00Z"))])
        #expect(answeredWait(draft, by: "me", at: at("2026-11-02T13:00:00Z")) == hour)
        let unanswered = pr(ready: "2026-11-02T12:00:00Z", merged: "2026-11-02T16:00:00Z", requests: [HistoryRequest(reviewer: "me", at: at("2026-11-02T09:30:00Z"))])
        #expect(responseSamples(unanswered, teams: [:], now: farFuture).first?.wait == 4 * hour)
    }

    @Test func answeredSamplesCountWhenReviewedAndUnansweredOnesWhenTheWaitEnded() {
        let november = DateInterval(start: at("2026-11-01T00:00:00Z"), end: at("2026-12-01T00:00:00Z"))
        let october = DateInterval(start: at("2026-10-01T00:00:00Z"), end: at("2026-11-01T00:00:00Z"))
        let prs = [
            HistoryPr(repo: "o/r", number: 1, author: "ana", createdAt: at("2026-10-30T00:00:00Z"), updatedAt: at("2026-11-02T00:00:00Z"), mergedAt: at("2026-11-02T00:00:00Z"), requests: [HistoryRequest(reviewer: "me", at: at("2026-10-30T00:00:00Z"))]),
            HistoryPr(repo: "o/r", number: 2, author: "ana", createdAt: at("2026-10-30T00:00:00Z"), updatedAt: at("2026-11-01T06:00:00Z"), requests: [HistoryRequest(reviewer: "me", at: at("2026-10-30T00:00:00Z"))], reviews: [review("me", "APPROVED", "2026-11-01T06:00:00Z")]),
        ]
        let inNovember = reviewerStats(prs, in: november, reviewers: ["me"], teams: [:], now: farFuture, calendar: utc()).first
        #expect(inNovember?.responseTimes.sorted() == [54 * hour, 72 * hour])
        #expect(inNovember?.unanswered == 1)
        #expect(reviewerStats(prs, in: october, reviewers: ["me"], teams: [:], now: farFuture, calendar: utc()).first?.responseTimes.isEmpty == true)
    }

    @Test func unblockingNeedsTheFirstHumanReviewAfterSeventyTwoHours() {
        let ready = at("2026-11-02T00:00:00Z")
        let atThreshold = pr(reviews: [HistoryReview(author: "me", state: "COMMENTED", submittedAt: ready.addingTimeInterval(unblockedWait))], createdAt: ready)
        #expect(unblocker(atThreshold)?.author == "me")
        let justUnder = pr(reviews: [HistoryReview(author: "me", state: "COMMENTED", submittedAt: ready.addingTimeInterval(unblockedWait - 1))], createdAt: ready)
        #expect(unblocker(justUnder) == nil)
        let authorAndBotFirst = pr(author: "bo", reviews: [
            HistoryReview(author: "bo", state: "COMMENTED", submittedAt: ready.addingTimeInterval(80 * hour)),
            HistoryReview(author: "cursor", isBot: true, state: "COMMENTED", submittedAt: ready.addingTimeInterval(81 * hour)),
            HistoryReview(author: "ana", state: "APPROVED", submittedAt: ready.addingTimeInterval(90 * hour)),
            HistoryReview(author: "me", state: "APPROVED", submittedAt: ready.addingTimeInterval(91 * hour)),
        ], createdAt: ready)
        #expect(unblocker(authorAndBotFirst)?.author == "ana")
        let november = DateInterval(start: at("2026-11-01T00:00:00Z"), end: at("2026-12-01T00:00:00Z"))
        let rows = reviewerStats([authorAndBotFirst, atThreshold], in: november, reviewers: ["me", "ana"], teams: [:], now: farFuture, calendar: utc())
        #expect(rows.map(\.unblocked) == [1, 1])
        #expect(StatsMetric.unblocked.value(rows[0]) == 1)
        #expect(!StatsMetric.unblocked.isLowerBetter)
    }

    @Test func historyFromAnotherSchemaIsDroppedSoItIsFetchedAgain() throws {
        let old = #"{"me":"me","members":[],"fetchedAt":{},"prs":[]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewHistory.self, from: Data(old.utf8)) }
        let older = #"{"schema":1,"me":"me","members":[],"teamMembers":{},"fetchedAt":{},"prs":[]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewHistory.self, from: Data(older.utf8)) }
        let history = ReviewHistory(me: "me", teamMembers: teams, prs: [pr(merged: "2026-11-03T00:00:00Z", requests: [HistoryRequest(team: "acme/web", at: at("2026-11-02T10:00:00Z"))], removals: [HistoryRequest(reviewer: "me", at: at("2026-11-02T11:00:00Z"))])])
        let encoded = try JSONEncoder().encode(history)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""schema":\#(ReviewHistory.schema)"#))
        #expect(try JSONDecoder().decode(ReviewHistory.self, from: encoded) == history)
    }

    @Test func demoHistoryHasUnansweredRequestsAndUnblockedPrs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: now)
        let year = StatsReport(history: demo.reviewHistory, period: .quarter, offset: -1, now: now, calendar: .current)
        #expect((year.mine?.unanswered ?? 0) > 0)
        #expect(year.rows.contains { $0.unblocked > 0 })
        #expect(year.mine?.medianResponse != nil)
        #expect(demo.reviewHistory.prs.contains { $0.requests.contains { $0.team != nil } })
        let sprint = StatsReport(history: demo.reviewHistory, period: .sprint, offset: 0, cycles: demo.cycles, now: now, calendar: .current)
        #expect((sprint.mine?.unanswered ?? 0) <= 5)
        #expect((sprint.mine?.medianResponse ?? .infinity) < 72 * hour)
    }

    @Test func teamRequestsRemovalsAndEndTimesParse() throws {
        let json = #"""
        {"number":7,"createdAt":"2026-11-02T09:00:00Z","updatedAt":"2026-11-03T00:00:00Z","mergedAt":"2026-11-03T00:00:00Z","closedAt":"2026-11-03T00:00:00Z",
         "author":{"login":"ana","__typename":"User"},
         "timelineItems":{"nodes":[
           {"__typename":"ReviewRequestedEvent","createdAt":"2026-11-02T10:00:00Z","requestedReviewer":{"slug":"web","organization":{"login":"acme"}}},
           {"__typename":"ReviewRequestedEvent","createdAt":"2026-11-02T10:05:00Z","requestedReviewer":{"login":"me"}},
           {"__typename":"ReviewRequestRemovedEvent","createdAt":"2026-11-02T11:00:00Z","requestedReviewer":{"login":"me"}},
           {"__typename":"ReviewRequestRemovedEvent","createdAt":"2026-11-02T12:00:00Z","requestedReviewer":{"slug":"web","organization":{"login":"acme"}}},
           {"__typename":"ReviewRequestRemovedEvent","createdAt":"2026-11-02T12:30:00Z","requestedReviewer":null}
         ]},
         "reviews":{"nodes":[]}}
        """#
        let node = try JSONDecoder().decode(HistoryNode.self, from: Data(json.utf8))
        let parsed = try #require(historyPr(node, repo: "acme/web"))
        #expect(parsed.requests == [HistoryRequest(team: "acme/web", at: at("2026-11-02T10:00:00Z")), HistoryRequest(reviewer: "me", at: at("2026-11-02T10:05:00Z"))])
        #expect(parsed.removals == [HistoryRequest(reviewer: "me", at: at("2026-11-02T11:00:00Z")), HistoryRequest(team: "acme/web", at: at("2026-11-02T12:00:00Z"))])
        #expect(parsed.mergedAt == at("2026-11-03T00:00:00Z"))
        #expect(parsed.endedAt == at("2026-11-03T00:00:00Z"))
    }
}

private func pr(
    author: String = "author",
    ready: String? = nil,
    merged: String? = nil,
    closed: String? = nil,
    requests: [HistoryRequest] = [],
    removals: [HistoryRequest] = [],
    reviews: [HistoryReview] = [],
    createdAt: Date = at("2026-11-02T09:00:00Z")
) -> HistoryPr {
    HistoryPr(
        repo: "acme/web", number: 1, author: author, createdAt: createdAt, updatedAt: at("2026-11-20T00:00:00Z"),
        readyAt: ready.map(at), mergedAt: merged.map(at), closedAt: closed.map(at),
        requests: requests, removals: removals, reviews: reviews
    )
}
