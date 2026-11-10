import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct DemoDataTests {
    private let demo = DemoData(now: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func queueShowcasesEveryBlockAndBothHiddenReasons() {
        let lists = blockLists(demo.prs, demo.settings)
        let high = lists[.high]?.shown ?? []
        #expect(high.count == 2)
        #expect(high.first.map { !$0.approvedByOthers.isEmpty && !$0.changesRequestedByOthers.isEmpty } == true)
        #expect(high.last?.sinceMyReviewUrl != nil)
        #expect(lists[.needs]?.shown.count == 3)
        #expect(lists[.needs]?.hidden.note == "2 approved by others, 1 with changes requested by others hidden")
        #expect(lists[.waiting]?.shown.count == 1)
        #expect(lists[.approved]?.shown.count == 1)
    }

    @Test func myPrsFillNeedsYouReadyWaitingAndDrafts() {
        let context = MyPrsContext(me: DemoData.me, settings: demo.settings.myPrs, acknowledged: [])
        let lists = myBlockLists(withoutExcluded(demo.myPrs, demo.settings.myPrs), context)
        #expect(lists[.needsYou]?.shown.count == 2)
        #expect(lists[.ready]?.shown.count == 2)
        #expect(lists[.waiting]?.shown.count == 1)
        #expect(lists[.drafts]?.shown.count == 1)
        #expect(demo.myPrs.count == 7)
        #expect(lists[.needsYou]?.shown.flatMap { newComments($0, context) }.map(\.author) == ["priya-n", "cursor"])
    }

    @Test func agesAreRelativeToNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ages = blockLists(demo.prs, demo.settings)[.high]?.shown.map { compactAge($0.createdAt, now: now) }
        #expect(ages == ["2d", "20h"])
    }
}
