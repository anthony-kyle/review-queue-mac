import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct ReviewHistoryFetchTests {
    private let teams = ["acme/web": ["me", "ana", "bo"]]

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

    @Test func demoHistoryHasMissedRequestsFirstResponsesAndUnblockedPrs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: now)
        let quarter = StatsReport(history: demo.reviewHistory.counted(demo.settings), period: .quarter, offset: -1, now: now, calendar: .current)
        #expect((quarter.mine?.missed ?? 0) > 0)
        #expect((quarter.mine?.firstResponses ?? 0) > 0)
        #expect(quarter.rows.contains { $0.unblocked > 0 })
        #expect(quarter.mine?.medianResponse != nil)
        #expect(demo.reviewHistory.prs.contains { $0.requests.contains { $0.team != nil } })
        let sprint = StatsReport(history: demo.reviewHistory.counted(demo.settings), period: .sprint, offset: 0, cycles: demo.cycles, now: now, calendar: .current)
        let rate = sprint.mine?.responseRate ?? 0
        #expect(rate > 0 && rate < 1)
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
