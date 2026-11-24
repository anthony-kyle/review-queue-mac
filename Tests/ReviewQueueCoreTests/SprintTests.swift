import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct SprintTests {
    private let now = at("2026-11-25T15:00:00Z")

    @Test func cyclesDecodeFromListCyclesWithFractionalSecondsAndOptionalNames() throws {
        let text = #"""
        [
          {"id":"c29","number":29,"startsAt":"2026-11-22T11:00:00.000Z","endsAt":"2026-12-06T11:00:00.000Z","completedIssueCountHistory":[6],"issueCountHistory":[43],"completedScopeHistory":[12],"scopeHistory":[93],"isCurrent":true},
          {"id":"c28","number":28,"name":"Hardening","startsAt":"2026-11-08T11:00:00.000Z","endsAt":"2026-11-22T11:00:00.000Z","isCurrent":false},
          {"id":"bad","number":1,"startsAt":"soon","endsAt":"later"}
        ]
        """#
        let cycles = try cyclesOf(text)
        #expect(cycles == [
            LinearCycle(id: "c29", number: 29, startsAt: at("2026-11-22T11:00:00Z"), endsAt: at("2026-12-06T11:00:00Z")),
            LinearCycle(id: "c28", number: 28, name: "Hardening", startsAt: at("2026-11-08T11:00:00Z"), endsAt: at("2026-11-22T11:00:00Z")),
        ])
        #expect(cycles.map(\.title) == ["Cycle 29", "Hardening"])
        #expect(try cyclesOf(#"{"cycles":[]}"#).isEmpty)
        #expect(throws: (any Error).self) { try cyclesOf("Team not found") }
    }

    @Test func teamsDecodeFromListTeamsPages() throws {
        let text = #"""
        {"teams":[{"id":"t1","key":"WEB","parentId":null,"displayName":"Web","icon":"Ai","name":"Web","visibility":"public","createdAt":"2025-10-30T21:48:08.903Z","updatedAt":"2026-11-23T11:34:12.102Z"}],"hasNextPage":true,"cursor":"t1"}
        """#
        let page = try JSONDecoder().decode(TeamPage.self, from: Data(text.utf8))
        #expect(page.teams == [LinearTeam(id: "t1", key: "WEB", name: "Web")])
        #expect(page.hasNextPage == true)
        #expect(page.cursor == "t1")
        #expect(page.teams.first?.label == "Web (WEB)")
    }

    @Test func currentCycleHoldsNowAndReachableCyclesStopAtHistoryAndNow() {
        let cycles = twoWeekly(from: "2025-11-09T00:00:00Z", count: 30)
        #expect(currentCycle(cycles, now: now)?.number == 28)
        #expect(currentCycle(cycles, now: at("2027-06-01T00:00:00Z")) == nil)
        let reachable = reachableCycles(cycles.reversed(), now: now, start: at("2025-11-23T00:00:00Z"))
        #expect(reachable.first?.number == 2)
        #expect(reachable.last?.number == 28)
        #expect(reachable.map(\.startsAt) == reachable.map(\.startsAt).sorted())
    }

    @Test func sprintSpansStepThroughPastCyclesOnly() {
        let cycles = twoWeekly(from: "2025-11-09T00:00:00Z", count: 30)
        let current = periodSpan(.sprint, offset: 0, cycles: cycles, now: now, calendar: utc())
        #expect(current.cycle?.number == 28)
        #expect(current.interval == DateInterval(start: at("2026-11-22T00:00:00Z"), end: at("2026-12-06T00:00:00Z")))
        #expect(current.canGoBack)
        #expect(!current.canGoForward)
        #expect(periodSpan(.sprint, offset: 3, cycles: cycles, now: now, calendar: utc()).cycle?.number == 28)
        let back = periodSpan(.sprint, offset: -2, cycles: cycles, now: now, calendar: utc())
        #expect(back.cycle?.number == 26)
        #expect(back.canGoForward)
        let oldest = periodSpan(.sprint, offset: -100, cycles: cycles, now: now, calendar: utc())
        #expect(oldest.cycle?.number == 2)
        #expect(!oldest.canGoBack)
    }

    @Test func sprintWithoutReachableCyclesFallsBackToTheMonth() {
        let span = periodSpan(.sprint, offset: 0, cycles: [], now: now, calendar: utc())
        #expect(span.cycle == nil)
        #expect(span.interval == periodInterval(.month, containing: now, calendar: utc()))
    }

    @Test func calendarSpansStepBackUntilHistoryRunsOut() {
        let month = periodSpan(.month, offset: 0, cycles: [], now: now, calendar: utc())
        #expect(month.canGoBack)
        #expect(!month.canGoForward)
        #expect(periodSpan(.month, offset: -1, cycles: [], now: now, calendar: utc()).canGoForward)
        #expect(periodSpan(.month, offset: 4, cycles: [], now: now, calendar: utc()) == month)
        #expect(!periodSpan(.year, offset: -1, cycles: [], now: now, calendar: utc()).canGoBack)
    }

    @Test func sprintIsTheDefaultOnlyWhenOfferedWithACycleRunning() {
        let cycles = twoWeekly(from: "2025-11-09T00:00:00Z", count: 30)
        #expect(defaultPeriod(isSprintOffered: true, cycles: cycles, now: now) == .sprint)
        #expect(defaultPeriod(isSprintOffered: false, cycles: cycles, now: now) == .month)
        #expect(defaultPeriod(isSprintOffered: true, cycles: Array(cycles.prefix(20)), now: now) == .month)
    }

    @Test func reportCountsReviewsInTheSelectedCycle() {
        let history = ReviewHistory(me: "me", members: ["ana"], prs: [
            HistoryPr(repo: "acme/web", number: 1, author: "ana", createdAt: at("2026-11-01T00:00:00Z"), updatedAt: at("2026-11-23T00:00:00Z"), reviews: [
                review("me", "APPROVED", "2026-11-21T09:00:00Z"),
                review("me", "COMMENTED", "2026-11-23T09:00:00Z"),
            ]),
        ])
        let cycles = twoWeekly(from: "2025-11-09T00:00:00Z", count: 30)
        let report = StatsReport(history: history, period: .sprint, offset: 0, cycles: cycles, now: now, calendar: utc())
        #expect(report.mine?.reviews == 1)
        #expect(report.mine?.approved == 0)
        let previous = StatsReport(history: history, period: .sprint, offset: -1, cycles: cycles, now: now, calendar: utc())
        #expect(previous.mine?.approved == 1)
    }

    @Test func sprintTeamDefaultsToNoneAndRoundTrips() throws {
        let old = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"teams":["acme/web"]}"#.utf8))
        #expect(old.sprintTeam == nil)
        var settings = QueueSettings()
        settings.sprintTeam = LinearTeam(id: "t1", key: "WEB", name: "Web")
        #expect(try JSONDecoder().decode(QueueSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func demoOpensOnTheCurrentSprint() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: now)
        #expect(demo.settings.sprintTeam == DemoData.linearTeams.last)
        #expect(currentCycle(demo.cycles, now: now)?.number == 42)
        #expect(defaultPeriod(isSprintOffered: true, cycles: demo.cycles, now: now) == .sprint)
        let report = StatsReport(history: demo.reviewHistory.counted(demo.settings), period: .sprint, offset: 0, cycles: demo.cycles, now: now, calendar: .current)
        #expect(report.span.cycle?.number == 42)
        #expect(report.span.canGoBack)
        #expect(report.mine?.reviews ?? 0 > 0)
    }
}

/// `count` back-to-back two-week cycles numbered from 1, the first starting at `from`.
private func twoWeekly(from: String, count: Int) -> [LinearCycle] {
    (0..<count).map { index in
        let start = at(from).addingTimeInterval(Double(index) * 14 * 24 * hour)
        return LinearCycle(id: "c\(index + 1)", number: index + 1, startsAt: start, endsAt: start.addingTimeInterval(14 * 24 * hour))
    }
}
