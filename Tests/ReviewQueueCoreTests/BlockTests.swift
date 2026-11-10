import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct BlockTests {
    @Test func reviewStandingWinsOverAuthorLists() {
        var settings = QueueSettings()
        settings.highUsers = ["pinned"]
        settings.lowUsers = ["muted"]
        #expect(blockOf(makePr(1, myReview: .changesAddressed), settings) == .high)
        #expect(blockOf(makePr(1, isDraft: true, myReview: .changesAddressed), settings) == .drafts)
        #expect(blockOf(makePr(1, myReview: .changesPending), settings) == .waiting)
        #expect(blockOf(makePr(1, myReview: .approved), settings) == .approved)
        #expect(blockOf(makePr(1, author: "muted", myReview: .changesAddressed), settings) == .high)
        #expect(blockOf(makePr(1, author: "pinned", myReview: .approved), settings) == .approved)
        #expect(blockOf(makePr(1, author: "muted"), settings) == .low)
        #expect(blockOf(makePr(1, author: "pinned"), settings) == .high)
        #expect(blockOf(makePr(1), settings) == .needs)
    }

    @Test func blocksSortOldestFirstByDefaultAndNewestOnRequest() {
        let prs = [
            makePr(1, createdAt: "2026-10-02T00:00:00Z"),
            makePr(2, createdAt: "2026-10-01T00:00:00Z"),
            makePr(3, createdAt: "2026-10-03T00:00:00Z"),
        ]
        var settings = QueueSettings()
        #expect(blockLists(prs, settings)[.needs]?.shown.map(\.number) == [2, 1, 3])
        settings.blockPrefs[.needs] = BlockPrefs(sort: .newest, isOthersApprovedShown: false, isOthersChangesRequestedShown: false)
        #expect(blockLists(prs, settings)[.needs]?.shown.map(\.number) == [3, 1, 2])
    }

    @Test func approvedByOthersShowsOnlyInHighByDefault() {
        var settings = QueueSettings()
        settings.highUsers = ["pinned"]
        let prs = [
            makePr(1, approvedByOthers: ["alice"]),
            makePr(2),
            makePr(3, author: "pinned", approvedByOthers: ["alice"]),
        ]
        let lists = blockLists(prs, settings)
        #expect(lists[.needs] == BlockList(shown: [prs[1]], hidden: HiddenCounts(approved: 1)))
        #expect(lists[.high] == BlockList(shown: [prs[2]]))
        #expect(blockPrefsOf(settings, .high) == BlockPrefs(sort: .oldest, isOthersApprovedShown: true, isOthersChangesRequestedShown: true))
        #expect(blockPrefsOf(settings, .low) == BlockPrefs(sort: .oldest, isOthersApprovedShown: false, isOthersChangesRequestedShown: false))

        settings.blockPrefs[.needs] = BlockPrefs(sort: .oldest, isOthersApprovedShown: true, isOthersChangesRequestedShown: true)
        settings.blockPrefs[.high] = BlockPrefs(sort: .oldest, isOthersApprovedShown: false, isOthersChangesRequestedShown: false)
        let flipped = blockLists(prs, settings)
        #expect(flipped[.needs]?.shown.map(\.number) == [1, 2])
        #expect(flipped[.high] == BlockList(shown: [], hidden: HiddenCounts(approved: 1)))
    }

    @Test func changesRequestedByOthersHideOnTheirOwnToggle() {
        var settings = QueueSettings()
        settings.highUsers = ["pinned"]
        let prs = [
            makePr(1, changesRequestedByOthers: ["bob"]),
            makePr(2),
            makePr(3, approvedByOthers: ["alice"], changesRequestedByOthers: ["bob"]),
            makePr(4, author: "pinned", changesRequestedByOthers: ["bob"]),
        ]
        let lists = blockLists(prs, settings)
        #expect(lists[.needs] == BlockList(shown: [prs[1]], hidden: HiddenCounts(approved: 1, changesRequested: 2)))
        #expect(lists[.needs]?.hidden.note == "1 approved by others, 2 with changes requested by others hidden")
        #expect(lists[.high]?.shown == [prs[3]])

        settings.blockPrefs[.needs] = BlockPrefs(sort: .oldest, isOthersApprovedShown: false, isOthersChangesRequestedShown: true)
        let changesShown = blockLists(prs, settings)
        #expect(changesShown[.needs] == BlockList(shown: [prs[0], prs[1]], hidden: HiddenCounts(approved: 1)))
        #expect(changesShown[.needs]?.hidden.note == "1 approved by others hidden")
    }

    @Test func blockPrefsSavedBeforeTheChangesFilterFollowTheApprovalsFilter() throws {
        let decode = { (json: String) in try JSONDecoder().decode(BlockPrefs.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"sort":"oldest","isOthersApprovedShown":true}"#).isOthersChangesRequestedShown)
        #expect(try !decode(#"{"sort":"newest","isOthersApprovedShown":false}"#).isOthersChangesRequestedShown)
        #expect(try !decode(#"{"sort":"oldest","isOthersApprovedShown":true,"isOthersChangesRequestedShown":false}"#).isOthersChangesRequestedShown)
    }

    @Test func everyBlockIsPresentEvenWhenEmpty() {
        #expect(Set(blockLists([], QueueSettings()).keys) == Set(Block.allCases))
    }

    @Test func reasonsExplainHighAndWaitingPlacement() {
        var settings = QueueSettings()
        settings.highUsers = ["pinned"]
        #expect(reasonOf(makePr(1, myReview: .changesAddressed), settings) == "Updated after your changes")
        #expect(reasonOf(makePr(1, myReview: .changesPending), settings) == "Changes requested")
        #expect(reasonOf(makePr(1, author: "pinned"), settings) == "Daily group")
        #expect(reasonOf(makePr(1, author: "pinned", myReview: .approved), settings) == nil)
        #expect(reasonOf(makePr(1), settings) == nil)
    }

    @Test func pinAndMuteAreMutuallyExclusive() {
        var settings = QueueSettings()
        settings.togglePin("a")
        #expect(settings.highUsers == ["a"])
        settings.toggleMute("a")
        #expect(settings.highUsers.isEmpty && settings.lowUsers == ["a"])
        settings.toggleMute("a")
        #expect(settings.lowUsers.isEmpty)
    }

    @Test func settingsDecodeFillsDefaultsForMissingFields() throws {
        let settings = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"teams":["acme/team-eng"],"intervalMinutes":5}"#.utf8))
        #expect(settings.teams == ["acme/team-eng"])
        #expect(settings.intervalMinutes == 5)
        #expect(settings.repoAccess == .owned)
        #expect(settings.repeatHighReminders)
        var roundTrip = settings
        roundTrip.blockPrefs[.low] = BlockPrefs(sort: .newest, isOthersApprovedShown: true, isOthersChangesRequestedShown: true)
        #expect(try JSONDecoder().decode(QueueSettings.self, from: JSONEncoder().encode(roundTrip)) == roundTrip)
    }

    @Test func waitingTimesReadAsCoarseHumanAges() throws {
        let now = try Date("2026-11-04T12:00:00Z", strategy: .iso8601)
        #expect(timeAgo("2026-11-04T11:59:40Z", now: now) == "just now")
        #expect(timeAgo("2026-11-04T11:15:00Z", now: now) == "45m ago")
        #expect(timeAgo("2026-11-04T07:00:00Z", now: now) == "5h ago")
        #expect(timeAgo("2026-11-01T12:00:00Z", now: now) == "3d ago")
        #expect(timeAgo("2026-09-23T12:00:00Z", now: now) == "6w ago")
        #expect(timeAgo("2026-11-05T12:00:00Z", now: now) == "just now")
    }

    @Test func ciMarksAndNameLists() {
        #expect(ciMark("SUCCESS").text == "Passing ✓")
        #expect(ciMark("ERROR").tone == .error)
        #expect(ciMark("EXPECTED").text == "Running …")
        #expect(ciMark(nil).text == "None")
        #expect(nameList(["a", "b"]) == "a, b")
        #expect(nameList(["a", "b", "c", "d", "e"]) == "a, b, c +2 more")
    }
}

@Test func markedDonePrsHideUntilTheyChange() {
    let a = makePr(1)
    let b = makePr(2)
    let changed = makePr(1, updatedAt: "2026-12-01T00:00:00Z")
    let marks: Dismissals = [a.key: a.updatedAt]
    let lists = blockLists([a, b], QueueSettings(), dismissals: marks)
    #expect(lists[.needs]?.shown.map(\.number) == [2])
    #expect(lists[.needs]?.dismissed.map(\.number) == [1])
    #expect(lists[.needs]?.hidden.isEmpty == true)
    #expect(!isDismissed(changed, marks))
    #expect(blockLists([changed, b], QueueSettings(), dismissals: marks)[.needs]?.shown.count == 2)
    #expect(prunedDismissals(marks, prs: [changed, b]).isEmpty)
    #expect(prunedDismissals(marks, prs: [a, b]) == marks)
}

@Test func menuToneFollowsWhatIsWaiting() {
    #expect(menuTone(high: 0, needs: 0) == .clear)
    #expect(menuTone(high: 0, needs: 4) == .waiting)
    #expect(menuTone(high: 2, needs: 0) == .urgent)
    #expect(menuTone(high: 2, needs: 4) == .urgent)
}
