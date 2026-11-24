import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct StatsBotTests {
    private let now = at("2026-11-25T15:00:00Z")

    private func allowing(_ bots: [String]) -> QueueSettings {
        var settings = QueueSettings()
        settings.allowedBotAuthors = bots
        return settings
    }

    /// A human PR, plus a bot PR that would add a review, an approval, an unblock, a late response and a missed request
    /// if it counted.
    private var history: ReviewHistory {
        let ready = at("2026-11-02T00:00:00Z")
        let human = HistoryPr(repo: "acme/web", number: 1, author: "ana", authorIsBot: false, createdAt: ready, updatedAt: ready, reviews: [review("me", "COMMENTED", "2026-11-02T02:00:00Z")])
        let bot = HistoryPr(
            repo: "acme/web", number: 2, author: "karbi-github", authorIsBot: true, createdAt: ready, updatedAt: ready,
            requests: [HistoryRequest(reviewer: "me", at: ready), HistoryRequest(reviewer: "bo", at: ready)],
            reviews: [review("me", "APPROVED", "2026-11-06T00:00:00Z")]
        )
        return ReviewHistory(me: "me", members: ["me", "bo"], prs: [human, bot])
    }

    @Test func botsNotAllowedAreLeftOutOfEveryFigure() {
        let report = StatsReport(history: history.counted(allowing([])), period: .month, offset: 0, now: now, calendar: utc())
        let mine = report.mine
        #expect(mine?.reviews == 1)
        #expect(mine?.approved == 0)
        #expect(mine?.unblocked == 0)
        #expect(mine?.responseTimes == [])
        #expect(mine?.late == 0)
        #expect(report.rows.first { $0.login == "bo" }?.missed == 0)
        #expect(report.graph.total == 1)
        #expect(trend(.month, endingAt: 0, history: history.counted(allowing([])), cycles: [], now: now, calendar: utc()).last == report.stats)
    }

    @Test func allowedBotsCountLikePeopleWhateverTheCaseOrSuffix() {
        for listed in ["karbi-github", "Karbi-GitHub[bot]", " KARBI-GITHUB "] {
            let report = StatsReport(history: history.counted(allowing([listed])), period: .month, offset: 0, now: now, calendar: utc())
            #expect(report.mine?.reviews == 2)
            #expect(report.mine?.approved == 1)
            #expect(report.mine?.unblocked == 1)
            #expect(report.mine?.late == 1)
            #expect(report.rows.first { $0.login == "bo" }?.missed == 1)
            #expect(trend(.month, endingAt: 0, history: history.counted(allowing([listed])), cycles: [], now: now, calendar: utc()).last == report.stats)
        }
    }

    @Test func cachesWithoutTheBotFlagFallBackToTheLogin() {
        let day = at("2026-11-02T00:00:00Z")
        let old = { (login: String) in HistoryPr(repo: "acme/web", number: 1, author: login, createdAt: day, updatedAt: day) }
        #expect(!old("dependabot").isCounted(allowing([])))
        #expect(!old("github-actions").isCounted(allowing([])))
        #expect(!old("copilot-swe-agent").isCounted(allowing([])))
        #expect(!old("release-bot[bot]").isCounted(allowing([])))
        #expect(old("release-bot[bot]").isCounted(allowing(["release-bot"])))
        #expect(old("dependabot").isCounted(allowing(["Dependabot[bot]"])))
        #expect(old("ana").isCounted(allowing([])))
        #expect(!HistoryPr(repo: "acme/web", number: 1, author: "some-app", authorIsBot: true, createdAt: day, updatedAt: day).isCounted(allowing([])))
        let decoded = try? JSONDecoder().decode(HistoryPr.self, from: JSONEncoder().encode(old("ana")))
        #expect(decoded?.authorIsBot == nil)
    }

    @Test func botAuthorsParseFromGraphQL() throws {
        let json = #"""
        {"number":9,"createdAt":"2026-11-02T09:00:00Z","updatedAt":"2026-11-02T10:00:00Z","author":{"login":"dependabot","__typename":"Bot"},
         "timelineItems":{"nodes":[]},"reviews":{"nodes":[]}}
        """#
        let bot = try #require(historyPr(try JSONDecoder().decode(HistoryNode.self, from: Data(json.utf8)), repo: "acme/web"))
        #expect(bot.author == "dependabot")
        #expect(bot.authorIsBot == true)
        let human = json.replacingOccurrences(of: #""login":"dependabot","__typename":"Bot""#, with: #""login":"ana","__typename":"User""#)
        #expect(historyPr(try JSONDecoder().decode(HistoryNode.self, from: Data(human.utf8)), repo: "acme/web")?.authorIsBot == false)
        let ghost = json.replacingOccurrences(of: #"{"login":"dependabot","__typename":"Bot"}"#, with: "null")
        let deleted = try #require(historyPr(try JSONDecoder().decode(HistoryNode.self, from: Data(ghost.utf8)), repo: "acme/web"))
        #expect(deleted.authorIsBot == nil)
        #expect(deleted.isCounted(QueueSettings()))
    }

    @Test func demoBotPrsAreExcludedSoYourFiguresDrop() {
        let demoNow = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: demoNow)
        #expect(demo.settings.allowedBotAuthors == ["release-bot"])
        let raw = StatsReport(history: demo.reviewHistory, period: .quarter, offset: -1, now: demoNow, calendar: .current)
        let counted = StatsReport(history: demo.reviewHistory.counted(demo.settings), period: .quarter, offset: -1, now: demoNow, calendar: .current)
        #expect(demo.reviewHistory.prs.contains { $0.author == "dependabot" })
        #expect(!demo.reviewHistory.counted(demo.settings).prs.contains { $0.author == "dependabot" })
        #expect((raw.mine?.reviews ?? 0) > (counted.mine?.reviews ?? 0))
    }
}
