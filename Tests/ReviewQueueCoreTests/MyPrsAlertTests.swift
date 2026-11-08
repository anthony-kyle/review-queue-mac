import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct MyPrsAlertTests {
    private let context = myContext()

    private func evaluate(
        _ previous: MyAlertState?,
        _ prs: [MyPr],
        closures: [String: PrClosure] = [:],
        context: MyPrsContext? = nil,
        dismissals: Dismissals = [:]
    ) -> MyAlertEvaluation {
        evaluateMyAlerts(previous: previous, prs: prs, closures: closures, context: context ?? self.context, dismissals: dismissals)
    }

    /// The state a previous refresh of `prs` would have left.
    private func seen(_ prs: [MyPr]) -> MyAlertState {
        evaluate(nil, prs).state
    }

    @Test func firstRunRecordsEverythingSilently() {
        let pr = makeMyPr(
            1,
            mergeable: "CONFLICTING",
            reviews: [prReview("r1", by: "alice", "CHANGES_REQUESTED")],
            comments: [prComment("c1")],
            ci: "FAILURE"
        )
        let result = evaluate(nil, [pr])
        #expect(result.alerts.isEmpty)
        #expect(result.state == MyAlertState(
            comments: ["c1"],
            reviews: ["r1"],
            failing: ["\(pr.key)@head"],
            conflicting: [pr.key],
            open: [pr.key: pr.ref]
        ))
        #expect(evaluate(result.state, [pr]).alerts.isEmpty)
    }

    @Test func newCommentsAlertOncePerPrWithCountAndFirstComment() throws {
        let before = makeMyPr(1, comments: [prComment("c0")])
        let after = makeMyPr(1, comments: [prComment("c0"), prComment("c1", body: "Rename this"), prComment("c2", by: "bob")])
        let result = evaluate(seen([before]), [after])
        let alert = try #require(result.alerts.first)
        #expect(result.alerts.count == 1)
        #expect(alert.kind == .normal)
        #expect(alert.title == "#1 PR 1")
        #expect(alert.subtitle == "2 new comments")
        #expect(alert.body == "alice: Rename this")
        #expect(alert.url == "https://github.com/c/c1")
        #expect(evaluate(result.state, [after]).alerts.isEmpty)
        #expect(evaluate(seen([before]), [makeMyPr(1, comments: [prComment("c0"), prComment("c1")])]).alerts.first?.subtitle == "New comment")
    }

    @Test func commentAlertsRespectOwnIgnoredBotsAcknowledgedAndToggle() {
        let previous = seen([makeMyPr(1)])
        let pr = makeMyPr(1, comments: [
            prComment("own", by: "me"),
            prComment("ignored", by: "noisy"),
            prComment("bot", by: "renovate[bot]", isBot: true),
            prComment("acked"),
        ])
        let strict = myContext(acknowledged: ["acked"]) {
            $0.ignoredCommenters = ["noisy"]
            $0.isBotCommentsShown = false
        }
        #expect(evaluate(previous, [pr], context: strict).alerts.isEmpty)
        let botsOn = myContext(acknowledged: ["acked"]) { $0.ignoredCommenters = ["noisy"] }
        #expect(evaluate(previous, [pr], context: botsOn).alerts.map(\.body) == ["renovate[bot]: Please rename this"])
        let off = myContext { $0.notifyComments = false }
        #expect(evaluate(previous, [pr], context: off).alerts.isEmpty)
    }

    @Test func approvalsAreNormalAndChangesRequestsAreLoud() {
        let previous = seen([makeMyPr(1, reviews: [prReview("r0", by: "carol", "COMMENTED")])])
        let pr = makeMyPr(1, reviews: [
            prReview("r0", by: "carol", "COMMENTED"),
            prReview("r1", by: "alice", "APPROVED"),
            prReview("r2", by: "bob", "CHANGES_REQUESTED"),
            prReview("r3", by: "dave", "COMMENTED"),
        ])
        let result = evaluate(previous, [pr])
        #expect(result.alerts.map(\.kind) == [.high, .normal])
        #expect(result.alerts.map(\.subtitle) == ["Changes requested by bob", "Approved by alice"])
        #expect(evaluate(result.state, [pr]).alerts.isEmpty)

        let quiet = myContext {
            $0.notifyApproved = false
            $0.notifyChangesRequested = false
        }
        #expect(evaluate(previous, [pr], context: quiet).alerts.isEmpty)
        let ignored = myContext { $0.ignoredCommenters = ["bob"] }
        #expect(evaluate(previous, [pr], context: ignored).alerts.map(\.subtitle) == ["Approved by alice"])
    }

    @Test func ciAlertsWhenItTurnsFailingOnTheHead() {
        let passing = makeMyPr(1, ci: "SUCCESS")
        let failing = makeMyPr(1, ci: "FAILURE", failingChecks: ["test", "lint"])
        let result = evaluate(seen([passing]), [failing])
        #expect(result.alerts.map(\.subtitle) == ["CI failing"])
        #expect(result.alerts.first?.body == "test, lint")
        #expect(evaluate(result.state, [failing]).alerts.isEmpty)
        #expect(evaluate(seen([makeMyPr(1, ci: "PENDING")]), [failing]).alerts.count == 1)
        #expect(evaluate(seen([makeMyPr(1, ci: nil)]), [failing]).alerts.count == 1)
        #expect(evaluate(result.state, [makeMyPr(1, headRefOid: "newer", ci: "FAILURE")]).alerts.map(\.subtitle) == ["CI failing"])
        #expect(evaluate(seen([passing]), [failing], context: myContext { $0.notifyCiFailing = false }).alerts.isEmpty)
    }

    @Test func conflictAlertsWhenItAppears() {
        let conflicting = makeMyPr(1, mergeable: "CONFLICTING")
        let result = evaluate(seen([makeMyPr(1)]), [conflicting])
        #expect(result.alerts.map(\.subtitle) == ["Merge conflict"])
        #expect(evaluate(result.state, [conflicting]).alerts.isEmpty)
        #expect(evaluate(seen([makeMyPr(1, mergeable: "UNKNOWN")]), [conflicting], context: myContext { $0.notifyConflict = false }).alerts.isEmpty)
    }

    @Test func brandNewPrAlertsForWhatItAlreadyHas() {
        let previous = seen([makeMyPr(1)])
        let fresh = makeMyPr(2, mergeable: "CONFLICTING", comments: [prComment("c1")], ci: "ERROR")
        #expect(evaluate(previous, [makeMyPr(1), fresh]).alerts.map(\.subtitle) == ["New comment", "CI failing", "Merge conflict"])
    }

    @Test func vanishedPrsAlertOnlyWhenSomeoneElseMergedOrClosedThem() {
        let a = makeMyPr(1)
        let b = makeMyPr(2)
        let c = makeMyPr(3)
        let d = makeMyPr(4)
        let previous = seen([a, b, c, d])
        #expect(vanishedPrs(previous: previous, prs: [d]).map(\.number) == [1, 2, 3])
        #expect(vanishedPrs(previous: nil, prs: []).isEmpty)

        let closures: [String: PrClosure] = [a.nodeId: .merged(by: "bob"), b.nodeId: .closed(by: "carol"), c.nodeId: .merged(by: "me")]
        let result = evaluate(previous, [d], closures: closures)
        #expect(result.alerts.map(\.subtitle) == ["Merged by bob", "Closed by carol"])
        #expect(result.alerts.first?.url == a.url)
        #expect(result.state.open.keys.sorted() == [d.key])

        #expect(evaluate(previous, [d], closures: [a.nodeId: .closed(by: "me"), b.nodeId: .open]).alerts.isEmpty)
        #expect(evaluate(previous, [d], closures: [a.nodeId: .merged(by: nil)]).alerts.map(\.subtitle) == ["Merged"])
        #expect(evaluate(previous, [d], closures: closures, context: myContext { $0.notifyClosed = false }).alerts.isEmpty)
    }

    @Test func moreThanThreeNormalAlertsCollapseButLoudOnesStay() throws {
        let before = (1...4).map { makeMyPr($0) }
        let after = (1...4).map { makeMyPr($0, comments: [prComment("c\($0)")]) }
            + [makeMyPr(5, reviews: [prReview("r5", by: "bob", "CHANGES_REQUESTED")])]
        let result = evaluate(seen(before + [makeMyPr(5)]), after)
        #expect(result.alerts.map(\.kind) == [.high, .summary])
        let summary = try #require(result.alerts.last)
        #expect(summary.title == "4 updates on your PRs")
        #expect(summary.subtitle == "My PRs")
        #expect(summary.body == "#1 PR 1\n#2 PR 2\n#3 PR 3\n+1 more")
        #expect(evaluate(seen(before), Array(after.prefix(3)) + [before[3]]).alerts.count == 3)
    }

    @Test func markedDonePrsStaySilentButAreRecorded() {
        let pr = makeMyPr(1, comments: [prComment("c1")], ci: "FAILURE")
        let previous = seen([makeMyPr(1)])
        let result = evaluate(previous, [pr], dismissals: [pr.key: pr.updatedAt])
        #expect(result.alerts.isEmpty)
        #expect(result.state.comments == ["c1"])
        #expect(evaluate(result.state, [pr]).alerts.isEmpty)
    }
}
