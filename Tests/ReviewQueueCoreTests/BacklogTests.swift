import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct BacklogTests {
    private func pr(
        _ number: Int,
        author: String = "ana",
        authorIsBot: Bool? = nil,
        created: String = "2026-11-02T09:00:00Z",
        ready: String? = nil,
        ended: String? = nil,
        reviews: [HistoryReview] = []
    ) -> HistoryPr {
        HistoryPr(
            repo: "acme/web", number: number, author: author, authorIsBot: authorIsBot, createdAt: at(created), updatedAt: at(created),
            readyAt: ready.map(at), mergedAt: ended.map(at), closedAt: ended.map(at), reviews: reviews
        )
    }

    @Test func openMeansCreatedByThenAndNotYetMergedOrClosed() {
        let closing = pr(1, ended: "2026-11-03T00:00:00Z")
        #expect(waitingForReview([closing], at: at("2026-11-02T08:59:59Z")) == 0)
        #expect(waitingForReview([closing], at: at("2026-11-02T09:00:00Z")) == 1)
        #expect(waitingForReview([closing], at: at("2026-11-02T23:59:59Z")) == 1)
        #expect(waitingForReview([closing], at: at("2026-11-03T00:00:00Z")) == 0)
    }

    @Test func aDraftWaitsOnlyOnceItIsReady() {
        let draft = pr(1, ready: "2026-11-04T00:00:00Z")
        #expect(waitingForReview([draft], at: at("2026-11-03T00:00:00Z")) == 0)
        #expect(waitingForReview([draft], at: at("2026-11-04T00:00:00Z")) == 1)
    }

    @Test func onlyAReviewFromSomeoneElseEndsTheWait() {
        let selfReviewed = pr(1, reviews: [review("ana", "COMMENTED", "2026-11-02T10:00:00Z")])
        let botReviewed = pr(2, reviews: [HistoryReview(author: "cursor", isBot: true, state: "COMMENTED", submittedAt: at("2026-11-02T10:00:00Z"))])
        let reviewed = pr(3, reviews: [review("me", "COMMENTED", "2026-11-02T12:00:00Z")])
        let dismissedOnly = pr(4, reviews: [review("me", "DISMISSED", "2026-11-02T10:00:00Z")])
        #expect(waitingForReview([selfReviewed, botReviewed, reviewed, dismissedOnly], at: at("2026-11-02T11:00:00Z")) == 4)
        #expect(waitingForReview([selfReviewed, botReviewed, reviewed, dismissedOnly], at: at("2026-11-02T12:00:00Z")) == 3)
    }

    @Test func botPrsOutsideTheAllowlistNeverWait() {
        let history = ReviewHistory(me: "me", prs: [pr(1), pr(2, author: "dependabot", authorIsBot: true)])
        #expect(waitingForReview(history.counted(QueueSettings()).prs, at: at("2026-11-03T00:00:00Z")) == 1)
        var allowing = QueueSettings()
        allowing.allowedBotAuthors = ["dependabot"]
        #expect(waitingForReview(history.counted(allowing).prs, at: at("2026-11-03T00:00:00Z")) == 2)
    }

    @Test func eachBucketCountsAtItsOwnEndAndTheRunningOneAtNow() {
        let now = at("2026-11-25T15:00:00Z")
        let history = ReviewHistory(me: "me", prs: [
            pr(1, created: "2026-09-10T00:00:00Z", ended: "2026-10-15T00:00:00Z"),
            pr(2, created: "2026-10-20T00:00:00Z", reviews: [review("me", "APPROVED", "2026-11-20T00:00:00Z")]),
            pr(3, created: "2026-11-24T00:00:00Z"),
            pr(4, created: "2026-11-26T00:00:00Z"),
        ])
        let months = trend(.month, endingAt: 0, history: history, cycles: [], now: now, calendar: utc())
        #expect(months.suffix(3).map(\.waiting) == [1, 1, 1])
        #expect(months.dropLast(3).allSatisfy { $0.waiting == 0 })
        let october = StatsReport(history: history, period: .month, offset: -1, now: now, calendar: utc())
        #expect(october.stats.waiting == 1)
        #expect(months.last?.waiting == StatsReport(history: history, period: .month, offset: 0, now: now, calendar: utc()).stats.waiting)
    }

    @Test func demoBacklogTrendsDown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: now)
        let months = trend(.month, endingAt: 0, history: demo.reviewHistory.counted(demo.settings), cycles: [], now: now, calendar: .current).map(\.waiting)
        #expect(months.count == 12)
        #expect(months.prefix(4).reduce(0, +) > months.suffix(4).reduce(0, +))
    }
}
