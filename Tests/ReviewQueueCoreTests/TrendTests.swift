import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct TrendTests {
    private let now = at("2026-11-25T15:00:00Z")

    @Test func bucketsPerKindStopAtTheKeptHistory() {
        let history = ReviewHistory(me: "me")
        let count = { (period: StatsPeriod, offset: Int) in
            trend(period, endingAt: offset, history: history, cycles: [], now: self.now, calendar: utc()).count
        }
        #expect(count(.week, 0) == 12)
        #expect(count(.month, 0) == 12)
        #expect(count(.quarter, 0) == 4)
        #expect(count(.year, 0) == 1)
        #expect(count(.month, -8) == 4)
        #expect(count(.week, -50) == 3)
        #expect(count(.week, -52) == 1)
        let months = trend(.month, endingAt: 0, history: history, cycles: [], now: now, calendar: utc())
        #expect(months.first?.span.interval.start == at("2025-12-01T00:00:00Z"))
        #expect(months.last?.span.interval.start == at("2026-11-01T00:00:00Z"))
        #expect(months.allSatisfy { $0.span.interval.start >= historyStart(today: now, calendar: utc()) })
    }

    @Test func sprintBucketsAreTheLastCyclesUpToTheSelectedOne() {
        let cycles = (0..<30).map { index in
            let start = at("2025-11-09T00:00:00Z").addingTimeInterval(Double(index) * 14 * 24 * hour)
            return LinearCycle(id: "c\(index + 1)", number: index + 1, startsAt: start, endsAt: start.addingTimeInterval(14 * 24 * hour))
        }
        let current = trend(.sprint, endingAt: 0, history: ReviewHistory(me: "me"), cycles: cycles, now: now, calendar: utc())
        #expect(current.map { $0.span.cycle?.number } == Array(17...28))
        let early = trend(.sprint, endingAt: -23, history: ReviewHistory(me: "me"), cycles: cycles, now: now, calendar: utc())
        #expect(early.map { $0.span.cycle?.number } == [2, 3, 4, 5])
    }

    @Test func onlyTheRunningPeriodIsPartial() {
        let weeks = trend(.week, endingAt: 0, history: ReviewHistory(me: "me"), cycles: [], now: now, calendar: utc())
        #expect(weeks.map { $0.isPartial(now: now) } == Array(repeating: false, count: 11) + [true])
        #expect(trend(.week, endingAt: -1, history: ReviewHistory(me: "me"), cycles: [], now: now, calendar: utc()).last?.isPartial(now: now) == false)
    }

    @Test func eachBucketCarriesYourValueAndTheTeamMedian() {
        let history = ReviewHistory(me: "me", members: ["ana", "bo"], prs: [
            pr(1, reviews: [review("me", "APPROVED", "2026-11-02T10:00:00Z"), review("ana", "COMMENTED", "2026-11-02T11:00:00Z")]),
            pr(2, reviews: [review("ana", "APPROVED", "2026-10-05T10:00:00Z"), review("bo", "APPROVED", "2026-10-05T10:00:00Z")]),
            pr(3, reviews: [review("bo", "APPROVED", "2026-10-06T10:00:00Z")]),
        ])
        let months = trend(.month, endingAt: 0, history: history, cycles: [], now: now, calendar: utc())
        let october = months[months.count - 2]
        let november = months[months.count - 1]
        #expect(october.mine?.reviews == 0)
        #expect(october.benchmark(.reviews).median == 1)
        #expect(october.mine.flatMap(StatsMetric.response.value) == nil)
        #expect(october.benchmark(.response).median != nil)
        #expect(november.mine?.reviews == 1)
        #expect(november.benchmark(.reviews).median == 1)
    }

    @Test func theLastPointMatchesTheCards() {
        let demoNow = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: demoNow)
        for period in StatsPeriod.allCases {
            for offset in [0, -1] {
                let report = StatsReport(history: demo.reviewHistory.counted(demo.settings), period: period, offset: offset, cycles: demo.cycles, now: demoNow, calendar: .current)
                let last = trend(period, endingAt: offset, history: demo.reviewHistory.counted(demo.settings), cycles: demo.cycles, now: demoNow, calendar: .current).last
                #expect(last == report.stats)
                for metric in StatsMetric.allCases {
                    #expect(last?.benchmark(metric) == report.benchmark(metric))
                }
            }
        }
    }

    @Test func demoTrendVaries() {
        let demoNow = Date(timeIntervalSince1970: 1_800_000_000)
        let demo = DemoData(now: demoNow)
        let sprints = trend(.sprint, endingAt: 0, history: demo.reviewHistory.counted(demo.settings), cycles: demo.cycles, now: demoNow, calendar: .current)
        #expect(sprints.count == 12)
        #expect(Set(sprints.compactMap { $0.mine?.reviews }).count >= 4)
    }
}

private func pr(_ number: Int, reviews: [HistoryReview]) -> HistoryPr {
    HistoryPr(repo: "acme/widgets", number: number, author: "author", createdAt: at("2026-09-01T00:00:00Z"), updatedAt: at("2026-11-20T00:00:00Z"), reviews: reviews)
}
