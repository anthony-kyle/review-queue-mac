import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct MyPrsTests {
    private let context = myContext()

    @Test func anythingThatNeedsYouWinsOverEveryOtherBlock() {
        #expect(myBlockOf(makeMyPr(1, reviews: [prReview("r1", by: "alice", "CHANGES_REQUESTED")]), context) == .needsYou)
        #expect(myBlockOf(makeMyPr(1, comments: [prComment("c1")]), context) == .needsYou)
        #expect(myBlockOf(makeMyPr(1, reviewDecision: "APPROVED", ci: "FAILURE"), context) == .needsYou)
        #expect(myBlockOf(makeMyPr(1, reviewDecision: "APPROVED", mergeable: "CONFLICTING"), context) == .needsYou)
        #expect(myBlockOf(makeMyPr(1, isDraft: true, ci: "ERROR"), context) == .needsYou)
    }

    @Test func changesRequestedOnlyNeedsYouUntilYouPushPastIt() {
        let pushedPast = makeMyPr(1, headRefOid: "newer", reviews: [prReview("r1", by: "alice", "CHANGES_REQUESTED", oid: "older")])
        #expect(pushedPast.changesRequestedOnHead.isEmpty)
        #expect(pushedPast.changesRequestedBy == ["alice"])
        #expect(myBlockOf(pushedPast, context) == .waiting)

        let reApproved = makeMyPr(1, reviews: [prReview("r1", by: "alice", "CHANGES_REQUESTED"), prReview("r2", by: "alice", "APPROVED")])
        #expect(reApproved.changesRequestedOnHead.isEmpty)
        #expect(myBlockOf(reApproved, context) == .ready)

        let commentedAfter = makeMyPr(1, reviews: [prReview("r1", by: "alice", "CHANGES_REQUESTED"), prReview("r2", by: "alice", "COMMENTED")])
        #expect(myBlockOf(commentedAfter, context) == .needsYou)

        let botRequest = makeMyPr(1, reviews: [prReview("r1", by: "cursor", "CHANGES_REQUESTED", isBot: true)])
        #expect(myBlockOf(botRequest, context) == .waiting)
    }

    @Test func readyNeedsAnApprovalAndNoStandingChangesRequest() {
        #expect(myBlockOf(makeMyPr(1, reviewDecision: "APPROVED"), context) == .ready)
        #expect(myBlockOf(makeMyPr(1, reviews: [prReview("r1", by: "alice", "APPROVED")]), context) == .ready)
        let mixed = makeMyPr(1, headRefOid: "newer", reviews: [
            prReview("r1", by: "alice", "APPROVED", oid: "older"),
            prReview("r2", by: "bob", "CHANGES_REQUESTED", oid: "older"),
        ])
        #expect(myBlockOf(mixed, context) == .waiting)
        #expect(myBlockOf(makeMyPr(1, reviews: [prReview("r1", by: "alice", "APPROVED"), prReview("r2", by: "alice", "DISMISSED")]), context) == .waiting)
        #expect(myBlockOf(makeMyPr(1, reviewDecision: "REVIEW_REQUIRED", ci: "PENDING"), context) == .waiting)
        #expect(myBlockOf(makeMyPr(1, isDraft: true, reviewDecision: "APPROVED"), context) == .drafts)
    }

    @Test func reasonLineListsEveryCauseInOrder() {
        let pr = makeMyPr(
            1,
            mergeable: "CONFLICTING",
            reviews: [prReview("r1", by: "alice", "CHANGES_REQUESTED"), prReview("r2", by: "bob", "CHANGES_REQUESTED")],
            comments: [prComment("c1"), prComment("c2", by: "bob")],
            ci: "FAILURE"
        )
        #expect(myReasonOf(pr, context) == "Changes requested by alice, bob · 2 new comments · CI failing · Conflict")
        #expect(myReasonOf(makeMyPr(1, comments: [prComment("c1")]), context) == "1 new comment")
        #expect(myReasonOf(makeMyPr(1), context) == nil)
    }

    @Test func newCommentsSkipOwnIgnoredAcknowledgedAndOptionallyBots() {
        let comments = [
            prComment("own", by: "me"),
            prComment("ignored", by: "noisy"),
            prComment("bot", by: "cursor[bot]", isBot: true),
            prComment("seen"),
            prComment("resolved", isResolved: true),
            prComment("fresh"),
        ]
        let pr = makeMyPr(1, comments: comments)
        let base = myContext(acknowledged: ["seen"]) { $0.ignoredCommenters = ["noisy"] }
        #expect(newComments(pr, base).map(\.id) == ["bot", "fresh"])
        let noBots = myContext(acknowledged: ["seen"]) {
            $0.ignoredCommenters = ["noisy"]
            $0.isBotCommentsShown = false
        }
        #expect(newComments(pr, noBots).map(\.id) == ["fresh"])
        #expect(myBlockOf(makeMyPr(2, comments: [prComment("bot", by: "x", isBot: true)]), noBots) == .waiting)
    }

    @Test func exclusionsMatchOrgsAndReposWithoutCase() {
        var settings = MyPrsSettings()
        settings.setExcludedOrg(" OldOrg ", isOn: true)
        settings.setExcludedRepo("acme/Sandbox", isOn: true)
        settings.setExcludedRepo("no-slash", isOn: true)
        settings.setExcludedOrg("", isOn: true)
        #expect(settings.excludedOrgs == ["OldOrg"])
        #expect(settings.excludedRepos == ["acme/Sandbox"])

        let prs = [makeMyPr(1, owner: "oldorg"), makeMyPr(2, repo: "sandbox"), makeMyPr(3)]
        #expect(isExcluded(prs[0], settings))
        #expect(isExcluded(prs[1], settings))
        #expect(withoutExcluded(prs, settings).map(\.number) == [3])

        settings.setExcludedOrg("OldOrg", isOn: false)
        #expect(withoutExcluded(prs, settings).map(\.number) == [1, 3])
    }

    @Test func blocksSortPerBlockAndSetDonePrsApart() {
        let prs = [
            makeMyPr(1, createdAt: "2026-10-02T00:00:00Z"),
            makeMyPr(2, createdAt: "2026-10-01T00:00:00Z"),
            makeMyPr(3, createdAt: "2026-10-03T00:00:00Z"),
        ]
        #expect(myBlockLists(prs, context)[.waiting]?.shown.map(\.number) == [2, 1, 3])
        let newest = myContext { $0.blockSorts[.waiting] = .newest }
        #expect(myBlockLists(prs, newest)[.waiting]?.shown.map(\.number) == [3, 1, 2])

        let lists = myBlockLists(prs, context, dismissals: [prs[0].key: prs[0].updatedAt])
        #expect(lists[.waiting]?.shown.map(\.number) == [2, 3])
        #expect(lists[.waiting]?.dismissed.map(\.number) == [1])
        #expect(Set(lists.keys) == Set(MyBlock.allCases))
    }

    @Test func pillToneFollowsWhatNeedsYou() {
        #expect(myMenuTone(needsYou: 0, ready: 0, waiting: 0) == .idle)
        #expect(myMenuTone(needsYou: 0, ready: 0, waiting: 3) == .waiting)
        #expect(myMenuTone(needsYou: 0, ready: 1, waiting: 0) == .ready)
        #expect(myMenuTone(needsYou: 0, ready: 1, waiting: 3) == .ready)
        #expect(myMenuTone(needsYou: 2, ready: 0, waiting: 0) == .urgent)
        #expect(myMenuTone(needsYou: 2, ready: 1, waiting: 3) == .urgent)
    }

    @Test func settingsDecodeFillsMyPrsDefaults() throws {
        let old = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"teams":["acme/team-eng"]}"#.utf8))
        #expect(old.myPrs == MyPrsSettings())
        #expect(old.myPrs.isBotCommentsShown && old.myPrs.notifyClosed)
        let partial = try JSONDecoder().decode(MyPrsSettings.self, from: Data(#"{"ignoredCommenters":["noisy"],"notifyComments":false}"#.utf8))
        #expect(partial.ignoredCommenters == ["noisy"])
        #expect(!partial.notifyComments && partial.notifyApproved)
        var roundTrip = MyPrsSettings()
        roundTrip.blockSorts[.ready] = .newest
        roundTrip.excludedRepos = ["a/b"]
        #expect(try JSONDecoder().decode(MyPrsSettings.self, from: JSONEncoder().encode(roundTrip)) == roundTrip)
    }

    @Test func snippetsSqueezeAndCutBodies() {
        #expect(snippet("Looks\n\n  good   to me") == "Looks good to me")
        let long = String(repeating: "a", count: 200)
        #expect(snippet(long).count == 140)
        #expect(snippet(long).hasSuffix("…"))
    }
}

@Suite struct MyPrsParsingTests {
    private let searchNode = #"{"id":"PR_kw1","number":7,"title":"ENG-7 thing","url":"https://github.com/acme/app/pull/7","isDraft":false,"headRefName":"eng-7-thing","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-02T00:00:00Z","author":{"login":"me","__typename":"User"},"repository":{"name":"app","owner":{"login":"acme"}}}"#

    private let detailJSON = #"""
        {"headRefOid":"abc","mergeable":"CONFLICTING","reviewDecision":"CHANGES_REQUESTED",
         "reviews":{"nodes":[
           {"id":"R1","author":{"login":"alice","__typename":"User"},"state":"CHANGES_REQUESTED","commit":{"oid":"abc"}},
           {"id":"R2","author":{"login":"me","__typename":"User"},"state":"COMMENTED","commit":{"oid":"abc"}}]},
         "reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[
           {"id":"T1","author":{"login":"alice","__typename":"User"},"createdAt":"2026-10-03T00:00:00Z","bodyText":"Why\nthis?","url":"https://github.com/acme/app/pull/7#discussion_r1"}]}},
           {"isResolved":true,"comments":{"nodes":[
           {"id":"T2","author":{"login":"alice","__typename":"User"},"createdAt":"2026-10-04T00:00:00Z","bodyText":"Fixed","url":"https://github.com/acme/app/pull/7#discussion_r2"}]}}]},
         "comments":{"totalCount":2,"nodes":[
           {"id":"C1","author":{"login":"cursor","__typename":"Bot"},"createdAt":"2026-10-02T00:00:00Z","bodyText":"Bugbot found 1 issue","url":"https://github.com/acme/app/pull/7#issuecomment-1"},
           {"id":"C2","author":null,"createdAt":"2026-10-02T01:00:00Z","bodyText":"ghost","url":"u"},
           {"id":"C3","author":{"login":"bob","__typename":"User"},"createdAt":"2026-10-02T02:00:00Z","bodyText":"Outdated","url":"https://github.com/acme/app/pull/7#issuecomment-3","isMinimized":true}]},
         "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"bob"}},{"requestedReviewer":{"slug":"team-eng"}}]},
         "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"}]}}}}]}}
        """#

    @Test func myPrDecodesFromSearchAndDetailJSON() throws {
        let node = try JSONDecoder().decode(ListNode.self, from: Data(searchNode.utf8))
        let repo = try #require(node.repository)
        let detail = try JSONDecoder().decode(DetailNode.self, from: Data(detailJSON.utf8))
        let pr = myPr(Candidate(node: node, repo: Repo(owner: repo.owner.login, name: repo.name)), detail: detail, me: "me")
        #expect(pr.key == "acme/app#7")
        #expect(pr.nodeId == "PR_kw1")
        #expect(pr.storyId == "ENG-7")
        #expect(pr.isConflicting)
        #expect(pr.reviews.map(\.id) == ["R1"])
        #expect(pr.changesRequestedOnHead == ["alice"])
        #expect(pr.comments.map(\.id) == ["C1", "C3", "T1", "T2"])
        #expect(pr.comments.filter(\.isResolved).map(\.id) == ["C3", "T2"])
        #expect(pr.comments.first?.isBot == true)
        #expect(pr.comments.first { $0.id == "T1" }?.body == "Why this?")
        #expect(pr.requestedReviewers == ["bob", "team-eng"])
        #expect(pr.failingChecks == ["test"])
        #expect(pr.unresolvedThreads == 1)
        #expect(pr.latestCommentUrl == "https://github.com/acme/app/pull/7#issuecomment-3")
        #expect(pr.firstUnresolvedThreadUrl == "https://github.com/acme/app/pull/7#discussion_r1")
        #expect(myReasonOf(pr, myContext()) == "Changes requested by alice · 2 new comments · CI failing · Conflict")
    }

    @Test func closuresReadMergedByAndClosedBy() throws {
        let json = #"""
            [{"id":"A","state":"MERGED","mergedBy":{"login":"bob"},"timelineItems":{"nodes":[]}},
             {"id":"B","state":"CLOSED","mergedBy":null,"timelineItems":{"nodes":[{"actor":{"login":"carol"}}]}},
             {"id":"C","state":"OPEN","mergedBy":null,"timelineItems":{"nodes":[]}}]
            """#
        let nodes = try JSONDecoder().decode([ClosureNode].self, from: Data(json.utf8))
        #expect(nodes.map(closureOf) == [.merged(by: "bob"), .closed(by: "carol"), .open])
    }
}
