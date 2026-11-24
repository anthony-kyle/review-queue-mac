import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct ReviewHistoryTests {
    private let pageJSON = #"""
    {
      "rateLimit": { "remaining": 4820, "resetAt": "2026-11-25T16:00:00Z" },
      "repository": {
        "pullRequests": {
          "pageInfo": { "hasNextPage": true, "endCursor": "Y3Vyc29yOjI=" },
          "nodes": [
            {
              "number": 42,
              "createdAt": "2026-11-02T09:00:00Z",
              "updatedAt": "2026-11-03T12:00:00Z",
              "author": { "login": "ana", "__typename": "User" },
              "timelineItems": { "nodes": [
                { "__typename": "ReadyForReviewEvent", "createdAt": "2026-11-02T10:00:00Z" },
                { "__typename": "ReviewRequestedEvent", "createdAt": "2026-11-02T10:05:00Z", "requestedReviewer": { "login": "me" } },
                { "__typename": "ReviewRequestedEvent", "createdAt": "2026-11-02T10:05:00Z", "requestedReviewer": {} },
                { "__typename": "ReadyForReviewEvent", "createdAt": "2026-11-02T11:00:00Z" }
              ] },
              "reviews": { "nodes": [
                { "author": { "login": "me", "__typename": "User" }, "state": "APPROVED", "submittedAt": "2026-11-02T13:00:00Z" },
                { "author": { "login": "me", "__typename": "User" }, "state": "PENDING", "submittedAt": null },
                { "author": { "login": "some-app", "__typename": "Bot" }, "state": "COMMENTED", "submittedAt": "2026-11-02T12:00:00Z" },
                { "author": null, "state": "COMMENTED", "submittedAt": "2026-11-02T12:00:00Z" }
              ] }
            },
            {
              "number": 41,
              "createdAt": "not a date",
              "updatedAt": "2026-11-01T00:00:00Z",
              "author": null,
              "timelineItems": { "nodes": [] },
              "reviews": { "nodes": [] }
            }
          ]
        }
      }
    }
    """#

    @Test func historyPagesDecodeIntoPrsWithReadyTimeRequestsAndSubmittedReviews() throws {
        let page = try JSONDecoder().decode(HistoryPageData.self, from: Data(pageJSON.utf8))
        #expect(page.rateLimit?.remaining == 4820)
        let connection = try #require(page.repository?.pullRequests)
        #expect(connection.pageInfo.hasNextPage)
        let prs = connection.nodes.compactMap { historyPr($0, repo: "acme/web") }
        #expect(prs.count == 1)
        let pr = try #require(prs.first)
        #expect(pr.key == "acme/web#42")
        #expect(pr.author == "ana")
        #expect(pr.readyAt == at("2026-11-02T11:00:00Z"))
        #expect(pr.requests == [HistoryRequest(reviewer: "me", at: at("2026-11-02T10:05:00Z"))])
        #expect(pr.reviews == [
            HistoryReview(author: "me", state: "APPROVED", submittedAt: at("2026-11-02T13:00:00Z")),
            HistoryReview(author: "some-app", isBot: true, state: "COMMENTED", submittedAt: at("2026-11-02T12:00:00Z")),
        ])
    }

    @Test func mergingUpsertsByKeyAndMarksOnlyCompleteFetches() {
        let old = ReviewHistory(prs: [historyPr(1, updated: "2026-11-01T00:00:00Z"), historyPr(2, updated: "2026-11-01T00:00:00Z")])
        let fetchedAt = at("2026-11-05T00:00:00Z")
        let merged = old.merged([historyPr(2, updated: "2026-11-04T00:00:00Z"), historyPr(3, updated: "2026-11-04T00:00:00Z")], repo: "acme/web", isComplete: true, at: fetchedAt)
        #expect(merged.prs.map(\.number) == [1, 2, 3])
        #expect(merged.prs[1].updatedAt == at("2026-11-04T00:00:00Z"))
        #expect(merged.fetchedAt == ["acme/web": fetchedAt])
        #expect(old.merged([], repo: "acme/web", isComplete: false, at: fetchedAt).fetchedAt.isEmpty)
    }

    @Test func pruningDropsOtherReposAndPrsOlderThanTheStart() {
        let history = ReviewHistory(
            fetchedAt: ["acme/web": at("2026-11-05T00:00:00Z"), "acme/old": at("2026-11-05T00:00:00Z")],
            prs: [
                historyPr(1, updated: "2025-11-01T00:00:00Z"),
                historyPr(2, updated: "2026-11-01T00:00:00Z"),
                HistoryPr(repo: "acme/old", number: 3, author: "a", createdAt: at("2026-11-01T00:00:00Z"), updatedAt: at("2026-11-01T00:00:00Z")),
            ]
        )
        let pruned = history.pruned(repos: ["acme/web"], start: at("2025-11-23T00:00:00Z"))
        #expect(pruned.prs.map(\.key) == ["acme/web#2"])
        #expect(pruned.fetchedAt.keys.sorted() == ["acme/web"])
    }

    @Test func refreshesPageBackToJustBeforeTheLastCompleteFetchButNeverPastTheStart() {
        let start = at("2025-11-23T00:00:00Z")
        let history = ReviewHistory(fetchedAt: ["acme/web": at("2026-11-05T12:00:00Z"), "acme/new": at("2025-11-23T00:05:00Z")])
        #expect(history.fetchSince("acme/web", start: start) == at("2026-11-05T11:50:00Z"))
        #expect(history.fetchSince("acme/new", start: start) == start)
        #expect(history.fetchSince("acme/never", start: start) == start)
    }

    @Test func historyRoundTripsThroughJSON() throws {
        let history = ReviewHistory(me: "me", members: ["ana"], fetchedAt: ["acme/web": at("2026-11-05T00:00:00Z")], prs: [historyPr(1, updated: "2026-11-01T00:00:00Z")], completedAt: at("2026-11-05T00:00:00Z"))
        let decoded = try JSONDecoder().decode(ReviewHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }

    @Test func leaderboardStartsHiddenForSettingsSavedBeforeIt() throws {
        let settings = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"teams":["acme/web"]}"#.utf8))
        #expect(settings.statsPanel == .trend)
    }

    @Test func theOldLeaderboardToggleDecodesAsTheMatchingPanel() throws {
        let decode = { (json: String) in try JSONDecoder().decode(QueueSettings.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"isLeaderboardShown":true}"#).statsPanel == .leaderboard)
        #expect(try decode(#"{"isLeaderboardShown":false}"#).statsPanel == .trend)
        #expect(try decode(#"{"isLeaderboardShown":true,"statsPanel":"trend"}"#).statsPanel == .trend)
        var settings = QueueSettings()
        settings.statsPanel = .leaderboard
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(QueueSettings.self, from: encoded) == settings)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("isLeaderboardShown"))
    }

    @Test func demoHistoryFillsTheGraphAndEveryTeammatesRow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: now)
        let report = StatsReport(history: demo.reviewHistory, period: .month, offset: 0, now: now, calendar: .current)
        #expect(report.rows.count == 8)
        #expect(report.rows.allSatisfy { $0.reviews > 0 })
        #expect(report.graph.total > 0)
        #expect(StatsReport(history: demo.reviewHistory, period: .year, offset: -1, now: now, calendar: .current).graph.total > 150)
        #expect(report.mine?.averageResponse != nil)
        #expect(demo.reviewHistory.prs.allSatisfy { $0.number < 1000 && $0.updatedAt <= now })
        #expect(DemoData(now: now).reviewHistory == demo.reviewHistory)
    }
}

private func historyPr(_ number: Int, updated: String) -> HistoryPr {
    HistoryPr(repo: "acme/web", number: number, author: "ana", createdAt: at("2025-10-01T00:00:00Z"), updatedAt: at(updated))
}
