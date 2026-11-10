import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct SignalTests {
    @Test func queueSignalTakesTheMostUrgentInOrder() {
        let everything = makePr(1, myReview: .changesAddressed, isReviewRequested: true, commentCount: 2, unresolvedThreads: 3, ci: "FAILURE")
        #expect(queueSignal(everything) == PrSignal("CI failing", .error))
        #expect(queueSignal(makePr(1, myReview: .changesAddressed, isReviewRequested: true, commentCount: 2, unresolvedThreads: 3, ci: "SUCCESS")) == PrSignal("Updated", .warning))
        #expect(queueSignal(makePr(1, isReviewRequested: true, commentCount: 2, unresolvedThreads: 3)) == PrSignal("3 threads", .warning))
        #expect(queueSignal(makePr(1, unresolvedThreads: 1)) == PrSignal("1 thread", .warning))
        #expect(queueSignal(makePr(1, isReviewRequested: true, commentCount: 2)) == PrSignal("Requested", .info))
        #expect(queueSignal(makePr(1, commentCount: 2)) == PrSignal("2 comments", .info))
        #expect(queueSignal(makePr(1, commentCount: 1)) == PrSignal("1 comment", .info))
        #expect(queueSignal(makePr(1, ci: "PENDING")) == nil)
    }

    @Test func mySignalTakesTheMostUrgentInOrder() {
        let context = myContext()
        let changes = [prReview("r1", by: "alice", "CHANGES_REQUESTED")]
        let comments = [prComment("c1"), prComment("c2")]
        #expect(mySignal(makeMyPr(1, mergeable: "CONFLICTING", reviews: changes, comments: comments, ci: "FAILURE"), context) == PrSignal("Conflict", .error))
        #expect(mySignal(makeMyPr(1, reviews: changes, comments: comments, ci: "ERROR"), context) == PrSignal("CI failing", .error))
        #expect(mySignal(makeMyPr(1, reviews: changes, comments: comments, unresolvedThreads: 2), context) == PrSignal("Changes requested", .error))
        #expect(mySignal(makeMyPr(1, comments: comments, unresolvedThreads: 2), context) == PrSignal("2 new", .warning))
        #expect(mySignal(makeMyPr(1, reviewDecision: "APPROVED", unresolvedThreads: 2), context) == PrSignal("2 threads", .warning))
        #expect(mySignal(makeMyPr(1, reviewDecision: "APPROVED"), context) == PrSignal("Approved", .success))
        #expect(mySignal(makeMyPr(1, reviews: [prReview("r1", by: "alice", "APPROVED")]), context) == PrSignal("Approved", .success))
        #expect(mySignal(makeMyPr(1), context) == nil)
    }

    @Test func mySignalSkipsAcknowledgedCommentsAndPushedPastChangesRequests() {
        let acknowledged = myContext(acknowledged: ["c1"])
        #expect(mySignal(makeMyPr(1, comments: [prComment("c1")]), acknowledged) == nil)
        let pushedPast = makeMyPr(1, headRefOid: "newer", reviews: [prReview("r1", by: "alice", "CHANGES_REQUESTED", oid: "older")])
        #expect(mySignal(pushedPast, myContext()) == nil)
    }

    @Test func rowsFollowTheirBlockDefaultUntilToggled() {
        var expansion = RowExpansion()
        #expect(expansion.isExpanded("a#1", in: "high", byDefault: true))
        #expect(!expansion.isExpanded("a#2", in: "waiting", byDefault: false))

        expansion.toggle("a#1", in: "high")
        expansion.toggle("a#2", in: "waiting")
        #expect(!expansion.isExpanded("a#1", in: "high", byDefault: true))
        #expect(expansion.isExpanded("a#2", in: "waiting", byDefault: false))

        expansion.toggle("a#1", in: "high")
        #expect(expansion.isExpanded("a#1", in: "high", byDefault: true))
    }

    @Test func aToggleDoesNotFollowThePrIntoAnotherBlock() {
        var expansion = RowExpansion()
        expansion.toggle("a#30", in: Block.waiting.rawValue)
        #expect(expansion.isExpanded("a#30", in: Block.waiting.rawValue, byDefault: false))
        #expect(expansion.isExpanded("a#30", in: Block.high.rawValue, byDefault: true))
    }

    @Test func onlyTheUrgentBlocksExpandRowsByDefault() {
        #expect(Block.allCases.filter(\.areRowsExpandedByDefault) == [.high])
        #expect(MyBlock.allCases.filter(\.areRowsExpandedByDefault) == [.needsYou])
    }

    @Test func compactAgeDropsTheSuffix() throws {
        let now = try Date("2026-11-04T12:00:00Z", strategy: .iso8601)
        #expect(compactAge("2026-11-04T11:59:40Z", now: now) == "now")
        #expect(compactAge("2026-11-04T11:15:00Z", now: now) == "45m")
        #expect(compactAge("2026-11-01T12:00:00Z", now: now) == "3d")
        #expect(compactAge("2026-09-23T12:00:00Z", now: now) == "6w")
        #expect(compactAge("not a date", now: now) == "")
    }
}
