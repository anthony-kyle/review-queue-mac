import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct AlertTests {
    private let pinned: QueueSettings = {
        var settings = QueueSettings()
        settings.highUsers = ["pinned"]
        return settings
    }()

    private func ids(_ evaluation: AlertEvaluation, _ kind: AlertKind) -> [String] {
        evaluation.alerts.filter { $0.kind == kind }.map(\.id)
    }

    @Test func firstRunRecordsStateAndAlertsOnlyHigh() {
        let prs = [makePr(1, author: "pinned"), makePr(2), makePr(3, isReviewRequested: true)]
        let result = evaluateAlerts(previous: nil, prs: prs, settings: pinned)
        #expect(result.alerts.map(\.kind) == [.high])
        #expect(result.alerts.first?.id == prs[0].key)
        #expect(result.state == AlertState(high: [prs[0].key], needs: [prs[1].key, prs[2].key], requested: [prs[2].key]))
    }

    @Test func prNewlyInHighAlertsHigh() {
        let pr = makePr(1, myReview: .changesAddressed)
        let previous = AlertState(needs: [pr.key])
        let result = evaluateAlerts(previous: previous, prs: [pr], settings: QueueSettings())
        #expect(ids(result, .high) == [pr.key])
        #expect(result.alerts.first?.subtitle == "High priority")
    }

    @Test func prStayingInHighRepeatsUnlessRemindersAreOff() {
        let pr = makePr(1, author: "pinned")
        let previous = AlertState(high: [pr.key])
        let repeated = evaluateAlerts(previous: previous, prs: [pr], settings: pinned)
        #expect(ids(repeated, .high) == [pr.key])
        #expect(repeated.alerts.first?.subtitle == "Still in High priority")

        var quiet = pinned
        quiet.repeatHighReminders = false
        #expect(evaluateAlerts(previous: previous, prs: [pr], settings: quiet).alerts.isEmpty)
        quiet.notifyHigh = false
        #expect(evaluateAlerts(previous: AlertState(), prs: [pr], settings: quiet).alerts.isEmpty)
    }

    @Test func prNewlyInNeedsAlertsOnce() {
        let pr = makePr(1)
        let first = evaluateAlerts(previous: AlertState(), prs: [pr], settings: QueueSettings())
        #expect(ids(first, .normal) == [pr.key])
        #expect(first.alerts.first?.subtitle == "Needs review")
        #expect(evaluateAlerts(previous: first.state, prs: [pr], settings: QueueSettings()).alerts.isEmpty)
    }

    @Test func hiddenNeedsPrsDoNotAlert() {
        let pr = makePr(1, approvedByOthers: ["alice"])
        #expect(evaluateAlerts(previous: AlertState(), prs: [pr], settings: QueueSettings()).alerts.isEmpty)
    }

    @Test func newReviewRequestAlertsOutsideNeeds() {
        let waiting = makePr(1, myReview: .changesPending, isReviewRequested: true)
        let previous = AlertState()
        let result = evaluateAlerts(previous: previous, prs: [waiting], settings: QueueSettings())
        #expect(ids(result, .normal) == [waiting.key])
        #expect(result.alerts.first?.subtitle == "Review requested")
        #expect(evaluateAlerts(previous: result.state, prs: [waiting], settings: QueueSettings()).alerts.isEmpty)
    }

    @Test func reviewRequestDoesNotDoubleAlertAPrAlreadyAlerted() {
        let needs = makePr(1, isReviewRequested: true)
        let high = makePr(2, author: "pinned", isReviewRequested: true)
        let result = evaluateAlerts(previous: AlertState(), prs: [needs, high], settings: pinned)
        #expect(ids(result, .high) == [high.key])
        #expect(ids(result, .normal) == [needs.key])
        #expect(result.alerts.first { $0.id == needs.key }?.subtitle == "Needs review")
    }

    @Test func togglesSilenceTheirRules() {
        var settings = QueueSettings()
        settings.notifyNeeds = false
        settings.notifyReviewRequested = false
        let prs = [makePr(1, isReviewRequested: true)]
        #expect(evaluateAlerts(previous: AlertState(), prs: prs, settings: settings).alerts.isEmpty)
        settings.notifyReviewRequested = true
        #expect(evaluateAlerts(previous: AlertState(), prs: prs, settings: settings).alerts.map(\.subtitle) == ["Review requested"])
    }

    @Test func moreThanThreeNormalAlertsCollapseIntoOneSummary() {
        let three = (1...3).map { makePr($0) }
        #expect(evaluateAlerts(previous: AlertState(), prs: three, settings: QueueSettings()).alerts.count == 3)

        let five = (1...5).map { makePr($0) } + [makePr(9, author: "pinned")]
        let result = evaluateAlerts(previous: AlertState(), prs: five, settings: pinned)
        #expect(result.alerts.map(\.kind) == [.high, .summary])
        let summary = result.alerts.last
        #expect(summary?.title == "5 PRs need your review")
        #expect(summary?.body == "#1 PR 1\n#2 PR 2\n#3 PR 3\n+2 more")
    }

    @Test func prThatLeavesNeedsAlertsAgainWhenItReturns() {
        let pr = makePr(1)
        let seen = evaluateAlerts(previous: AlertState(), prs: [pr], settings: QueueSettings()).state
        let gone = evaluateAlerts(previous: seen, prs: [], settings: QueueSettings()).state
        #expect(gone == AlertState())
        #expect(evaluateAlerts(previous: gone, prs: [pr], settings: QueueSettings()).alerts.count == 1)
    }

    @Test func alertCarriesLinksAndDetails() throws {
        var pr = makePr(1, myReview: .changesAddressed)
        pr.linearReviewUrl = "https://linear.app/acme/review/x"
        let alert = try #require(evaluateAlerts(previous: nil, prs: [pr], settings: QueueSettings()).alerts.first)
        #expect(alert.url == pr.url)
        #expect(alert.linearUrl == pr.linearReviewUrl)
        #expect(alert.title == "#1 PR 1")
        #expect(alert.body == "widgets · ENG-1 · octocat · Updated after your changes")
    }
}
