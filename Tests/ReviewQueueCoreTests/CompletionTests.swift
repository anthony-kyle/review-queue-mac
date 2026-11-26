import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct CompletionTests {
    private let november = DateInterval(start: at("2026-11-01T00:00:00Z"), end: at("2026-12-01T00:00:00Z"))

    private func pr(
        _ number: Int,
        author: String = "ana",
        authorIsBot: Bool? = nil,
        merged: String? = nil,
        closed: String? = nil,
        mergedBy: String? = nil,
        closedBy: String? = nil
    ) -> HistoryPr {
        HistoryPr(
            repo: "acme/web", number: number, author: author, authorIsBot: authorIsBot,
            createdAt: at("2026-10-20T00:00:00Z"), updatedAt: at("2026-11-20T00:00:00Z"),
            mergedAt: merged.map(at), closedAt: closed.map(at), mergedBy: mergedBy, closedBy: closedBy
        )
    }

    private func rows(_ prs: [HistoryPr], settings: QueueSettings = QueueSettings()) -> [String: ReviewerStats] {
        let history = ReviewHistory(me: "me", members: ["me", "ana", "bo"], prs: prs).counted(settings)
        let stats = reviewerStats(history.prs, in: november, reviewers: ["me", "ana", "bo"], teams: [:], now: farFuture, calendar: utc())
        return Dictionary(uniqueKeysWithValues: stats.map { ($0.login, $0) })
    }

    @Test func aMergeIsCreditedToWhoeverMergedItWhenItMerged() {
        let merged = pr(1, merged: "2026-11-05T00:00:00Z", closed: "2026-11-05T00:00:00Z", mergedBy: "me", closedBy: "me")
        #expect(completion(merged)?.actor == "me")
        #expect(completion(merged)?.at == at("2026-11-05T00:00:00Z"))
        #expect(completion(merged)?.isMerged == true)
        let row = rows([merged])["me"]
        #expect((row?.merged, row?.closed, row?.completed) == (1, 0, 1))
        #expect(rows([pr(2, merged: "2026-10-31T23:59:59Z", mergedBy: "me")])["me"]?.merged == 0)
    }

    @Test func anUnmergedCloseIsCreditedToTheLastCloser() {
        let closed = pr(1, closed: "2026-11-06T00:00:00Z", closedBy: "bo")
        #expect(completion(closed)?.isMerged == false)
        #expect(rows([closed])["bo"]?.closed == 1)
        #expect(rows([closed])["ana"]?.closed == 0)
    }

    @Test func aPrClosedReopenedAndMergedCountsOnceAsMerged() {
        let reopened = pr(1, merged: "2026-11-10T00:00:00Z", closed: "2026-11-10T00:00:00Z", mergedBy: "ana", closedBy: "bo")
        let all = rows([reopened])
        #expect(all["ana"]?.merged == 1)
        #expect(all["bo"]?.closed == 0)
        #expect(all.values.map(\.completed).reduce(0, +) == 1)
    }

    @Test func noOneIsCreditedWhenGitHubNamesNoActorOrABot() {
        #expect(completion(pr(1, merged: "2026-11-05T00:00:00Z")) == nil)
        #expect(completion(pr(2, closed: "2026-11-05T00:00:00Z")) == nil)
        let byBot = rows([pr(3, merged: "2026-11-05T00:00:00Z", mergedBy: "github-actions")])
        #expect(byBot.values.allSatisfy { $0.completed == 0 })
        #expect(completion(pr(4)) == nil)
    }

    @Test func botAuthoredPrsCountOnlyWhenTheBotIsAllowed() {
        let bump = pr(1, author: "dependabot", authorIsBot: true, merged: "2026-11-05T00:00:00Z", mergedBy: "me")
        #expect(rows([bump])["me"]?.merged == 0)
        var allowing = QueueSettings()
        allowing.allowedBotAuthors = ["Dependabot[bot]"]
        let counted = rows([bump], settings: allowing)["me"]
        #expect(counted?.merged == 1)
        #expect(counted?.completedByAuthor == [.bot: 1])
    }

    @Test func completionsSplitByWhosePrItWas() {
        let row = rows([
            pr(1, author: "me", merged: "2026-11-02T00:00:00Z", mergedBy: "me"),
            pr(2, author: "ana", merged: "2026-11-03T00:00:00Z", mergedBy: "me"),
            pr(3, author: "zed", closed: "2026-11-04T00:00:00Z", closedBy: "me"),
            pr(4, author: "bo", closed: "2026-11-05T00:00:00Z", closedBy: "me"),
        ])["me"]
        #expect(row?.completedByAuthor == [.own: 1, .teammate: 2, .other: 1])
        #expect((row?.merged, row?.closed) == (2, 2))
    }

    @Test func completedRanksMoreFirstAndOnlyItHasACard() {
        #expect(!StatsMetric.completed.isLowerBetter)
        #expect(StatsMetric.allCases.filter(\.isCard) == [.reviews, .approved, .changesRequested, .completed, .responseRate, .firstResponses, .unblocked])
        #expect(StatsMetric.merged.isRanked && !StatsMetric.merged.isCard)
    }

    @Test func theTrendsLastPointMatchesTheCardsForCompletions() {
        let demoNow = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: demoNow)
        let index = StatsIndex(history: demo.reviewHistory.counted(demo.settings), now: demoNow, calendar: .current)
        for period in StatsPeriod.allCases {
            let report = StatsReport(index: index, period: period, offset: -1, cycles: demo.cycles)
            let last = trend(period, endingAt: -1, index: index, cycles: demo.cycles).last
            for metric in [StatsMetric.completed, .merged, .closed] {
                #expect(last?.mine.flatMap(metric.value) == report.mine.flatMap(metric.value))
                #expect(last?.benchmark(metric) == report.benchmark(metric))
            }
        }
    }

    @Test func demoHasMergesAndClosesByYouAndTeammates() {
        let demoNow = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: demoNow)
        let report = StatsReport(history: demo.reviewHistory.counted(demo.settings), period: .quarter, offset: -1, now: demoNow, calendar: .current)
        #expect((report.mine?.merged ?? 0) > 0)
        #expect((report.mine?.closed ?? 0) > 0)
        #expect(report.rows.contains { $0.login != DemoData.me && $0.merged > 0 })
        #expect(report.rows.contains { $0.login != DemoData.me && $0.closed > 0 })
        #expect((report.mine?.completedByAuthor[.teammate] ?? 0) > 0)
    }
}
