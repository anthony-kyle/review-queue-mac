import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct PeriodGraphTests {
    private let today = at("2026-11-25T15:00:00Z")

    @Test func stylesSplitCalendarPeriodsFromHeatmapPeriods() {
        #expect([StatsPeriod.sprint, .week, .month, .quarter, .year].map(GraphStyle.init) == [.calendar, .calendar, .calendar, .heatmap, .heatmap])
    }

    @Test func aWeekIsOneRowWithFutureDaysFlagged() {
        let calendar = utc(firstWeekday: 2)
        let week = periodInterval(.week, containing: today, calendar: calendar)!
        let graph = periodGraph(week, style: .calendar, counts: [at("2026-11-24T00:00:00Z"): 2, at("2026-11-27T00:00:00Z"): 5], thresholds: [], today: today, calendar: calendar)
        #expect(graph.weeks.count == 1)
        #expect(graph.weekdays == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        #expect(graph.weeks[0].map { $0?.isFuture } == [false, false, false, true, true, true, true])
        #expect(graph.weeks[0].map { $0?.count } == [0, 2, 0, 0, 0, 0, 0])
        #expect(graph.total == 2)
    }

    @Test func monthGridsPadToWholeWeeksForEveryStartingWeekday() {
        for firstWeekday in [1, 2] {
            let calendar = utc(firstWeekday: firstWeekday)
            var startingWeekdays: Set<Int> = []
            for month in 1...12 {
                let start = at(String(format: "2026-%02d-01T00:00:00Z", month))
                let interval = periodInterval(.month, containing: start, calendar: calendar)!
                let graph = periodGraph(interval, style: .calendar, counts: [:], thresholds: [], today: today, calendar: calendar)
                let days = calendar.range(of: .day, in: .month, for: start)!.count
                let lead = (calendar.component(.weekday, from: start) - firstWeekday + 7) % 7
                startingWeekdays.insert(calendar.component(.weekday, from: start))
                #expect(graph.weeks.count == (lead + days + 6) / 7)
                #expect(graph.weeks.flatMap { $0 }.prefix(lead).allSatisfy { $0 == nil })
                #expect(graph.weeks.flatMap { $0 }.compactMap(\.self).count == days)
                #expect(graph.weeks.flatMap { $0 }.compactMap(\.self).first?.date == start)
                #expect(graph.months.isEmpty)
            }
            #expect(startingWeekdays.count == 7)
        }
    }

    @Test func februaryFillsFourRowsOrFiveInALeapYear() {
        let sundays = utc(firstWeekday: 1)
        let february = periodGraph(periodInterval(.month, containing: at("2026-02-10T00:00:00Z"), calendar: sundays)!, style: .calendar, counts: [:], thresholds: [], today: today, calendar: sundays)
        #expect(february.weeks.count == 4)
        #expect(february.weeks.allSatisfy { $0.allSatisfy { $0 != nil } })
        let leap = periodGraph(periodInterval(.month, containing: at("2028-02-10T00:00:00Z"), calendar: sundays)!, style: .calendar, counts: [:], thresholds: [], today: today, calendar: sundays)
        #expect(leap.weeks.count == 5)
        #expect(leap.weeks.flatMap { $0 }.compactMap(\.self).count == 29)
        #expect(leap.weeks[0].map { $0 == nil } == [true, true, false, false, false, false, false])
        #expect(leap.weeks.flatMap { $0 }.allSatisfy { $0?.isFuture != false })
    }

    @Test func aCycleOffTheWeekStartKeepsOnlyItsDays() {
        let cycle = DateInterval(start: at("2026-11-19T00:00:00Z"), end: at("2026-12-03T00:00:00Z"))
        let sundays = periodGraph(cycle, style: .calendar, counts: [:], thresholds: [], today: today, calendar: utc(firstWeekday: 1))
        #expect(sundays.weeks.count == 3)
        #expect(sundays.weeks[0].map { $0 == nil } == [true, true, true, true, false, false, false])
        #expect(sundays.weeks[2].map { $0 == nil } == [false, false, false, false, true, true, true])
        #expect(sundays.weeks.flatMap { $0 }.compactMap(\.self).count == 14)
        let mondays = periodGraph(cycle, style: .calendar, counts: [:], thresholds: [], today: today, calendar: utc(firstWeekday: 2))
        #expect(mondays.weeks[0].map { $0 == nil } == [true, true, true, false, false, false, false])
        #expect(mondays.weeks[2].map { $0 == nil } == [false, false, false, true, true, true, true])
        let midday = DateInterval(start: at("2026-11-19T11:00:00Z"), end: at("2026-12-03T11:00:00Z"))
        #expect(periodGraph(midday, style: .calendar, counts: [:], thresholds: [], today: today, calendar: utc()).weeks.flatMap { $0 }.compactMap(\.self).count == 15)
    }

    @Test func aQuarterIsFourteenColumnsWithMonthLabels() {
        let calendar = utc()
        let quarter = periodGraph(periodInterval(.quarter, containing: today, calendar: calendar)!, style: .heatmap, counts: [:], thresholds: [], today: today, calendar: calendar)
        #expect(quarter.weeks.count == 14)
        #expect(quarter.weeks[0].map { $0 == nil } == [true, true, true, true, false, false, false])
        #expect(quarter.months == [GraphMonth(column: 0, name: "Oct"), GraphMonth(column: 5, name: "Nov"), GraphMonth(column: 10, name: "Dec")])
    }

    @Test func aYearRunsJanuaryToDecember() {
        let calendar = utc()
        let year = periodGraph(periodInterval(.year, containing: today, calendar: calendar)!, style: .heatmap, counts: [:], thresholds: [], today: today, calendar: calendar)
        #expect(year.weeks.count == 53)
        #expect(year.months.count == 12)
        #expect(year.months.first == GraphMonth(column: 0, name: "Jan"))
        #expect(year.months[1] == GraphMonth(column: 5, name: "Feb"))
        #expect(year.weeks.flatMap { $0 }.compactMap(\.self).first?.date == at("2026-01-01T00:00:00Z"))
        #expect(year.weeks.flatMap { $0 }.compactMap(\.self).last?.date == at("2026-12-31T00:00:00Z"))
        #expect(graphMonths([nil, at("2026-01-04T00:00:00Z"), at("2026-02-01T00:00:00Z")], calendar: calendar) == [GraphMonth(column: 1, name: "Jan"), GraphMonth(column: 2, name: "Feb")])
    }

    @Test func shadesComeFromTheWholeHistoryNotThePeriod() {
        let busy = (1...8).map { number in
            HistoryPr(repo: "acme/web", number: number, author: "ana", createdAt: at("2026-01-01T00:00:00Z"), updatedAt: at("2026-11-23T12:00:00Z"), reviews: [review("me", "APPROVED", "2026-11-23T12:00:00Z")])
        }
        let quiet = HistoryPr(repo: "acme/web", number: 99, author: "ana", createdAt: at("2026-01-01T00:00:00Z"), updatedAt: at("2026-01-05T12:00:00Z"), reviews: [review("me", "APPROVED", "2026-01-05T12:00:00Z")])
        let history = ReviewHistory(me: "me", prs: busy + [quiet])
        let week = StatsReport(history: history, period: .week, offset: 0, now: today, calendar: utc())
        let monday = week.graph.weeks.flatMap { $0 }.compactMap(\.self).first { $0.count == 8 }
        #expect(monday?.level == 3)
        #expect(week.graph.total == 8)
        #expect(periodGraph(week.interval, style: .calendar, counts: [at("2026-11-23T00:00:00Z"): 8], thresholds: heatmapThresholds([8]), today: today, calendar: utc()).weeks[0][1]?.level == 1)
    }

    @Test func historyKeepsFiftyThreeWeeksFromTheCalendarsWeekStart() {
        #expect(historyStart(today: today, calendar: utc(firstWeekday: 1)) == at("2025-11-23T00:00:00Z"))
        #expect(historyStart(today: today, calendar: utc(firstWeekday: 2)) == at("2025-11-24T00:00:00Z"))
    }
}

@Suite struct GraphLayoutTests {
    @Test func everyPeriodSharesOneBlockAndRowsFillItUpToTheCap() {
        #expect(GraphLayout.blockHeight == 151)
        let row = { (rows: Int) in GraphLayout.rowHeight(rows: rows, gap: GraphLayout.calendarGap) }
        #expect(row(1) == 34)
        #expect(row(2) == 34)
        #expect(row(3) == 34)
        #expect(row(5) == 24)
        #expect(row(6) == 19)
        #expect(GraphLayout.rowHeight(rows: 7, gap: GraphLayout.heatmapGap) == 17)
        #expect(row(0) == 34)
        for rows in 1...6 {
            #expect(Double(rows) * row(rows) + Double(rows - 1) * GraphLayout.calendarGap <= GraphLayout.daysHeight)
        }
    }

    @Test func shortCellsPutDateAndCountOnOneLine() {
        #expect(GraphLayout.isCompact(19))
        #expect(GraphLayout.isCompact(27.9))
        #expect(!GraphLayout.isCompact(28))
        #expect(!GraphLayout.isCompact(34))
    }
}
