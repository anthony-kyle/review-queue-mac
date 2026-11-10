import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct GitHubParsingTests {
    @Test func storyIdsComeFromTheBranchSkippingSingleLetterSlugs() {
        #expect(storyIdOf("eng-2110-w-9-tin-comparison", "") == "ENG-2110")
        #expect(storyIdOf("alex/eng-2291", "") == "ENG-2291")
        #expect(storyIdOf("ci/vec-859-deploy", "") == "VEC-859")
        #expect(storyIdOf("fix/bump-compression-1.8.2", "chore: bump") == nil)
        #expect(storyIdOf("proto/rich", "ENG-12 fix thing") == "ENG-12")
        #expect(storyIdOf("agent-readiness/report-2026-08-04", "Add ARI report 2026-08-04") == nil)
    }

    @Test func changesRequestCountsAsAddressedOnceHeadMovesOrYouAreReRequested() {
        let cr = detail(reviews: [review("me", "CHANGES_REQUESTED")])
        #expect(myReviewOf(cr, me: "me", isRequested: false) == .changesPending)
        #expect(myReviewOf(cr, me: "me", isRequested: true) == .changesAddressed)
        #expect(myReviewOf(detail(reviews: [review("me", "CHANGES_REQUESTED")], headRefOid: "newer"), me: "me", isRequested: false) == .changesAddressed)
        let commentedAfter = detail(reviews: [review("me", "CHANGES_REQUESTED"), review("me", "COMMENTED")])
        #expect(myReviewOf(commentedAfter, me: "me", isRequested: false) == .changesPending)
    }

    @Test func sinceMyReviewLinksReviewedCommitToHeadOnlyOnceHeadMoves() {
        let url = "https://github.com/o/r/pull/1"
        #expect(sinceMyReviewUrlOf(detail(reviews: [review("me", "CHANGES_REQUESTED", oid: "old")], headRefOid: "new"), me: "me", url: url) == "\(url)/files/old..new")
        #expect(sinceMyReviewUrlOf(detail(reviews: [review("me", "APPROVED", oid: "old")], headRefOid: "new"), me: "me", url: url) == "\(url)/files/old..new")
        #expect(sinceMyReviewUrlOf(detail(reviews: [review("me", "CHANGES_REQUESTED")]), me: "me", url: url) == nil)
        #expect(sinceMyReviewUrlOf(detail(reviews: [review("me", "APPROVED", oid: "old"), review("me", "DISMISSED")], headRefOid: "new"), me: "me", url: url) == nil)
        #expect(sinceMyReviewUrlOf(detail(reviews: [review("me", "COMMENTED", oid: "old")], headRefOid: "new"), me: "me", url: url) == nil)
        #expect(sinceMyReviewUrlOf(detail(reviews: [review("other", "APPROVED", oid: "old")], headRefOid: "new"), me: "me", url: url) == nil)
    }

    @Test func myReviewReadsApprovalDismissalAndNoReview() {
        #expect(myReviewOf(detail(), me: "me", isRequested: false) == .none)
        #expect(myReviewOf(detail(reviews: [review("me", "APPROVED")]), me: "me", isRequested: false) == .approved)
        #expect(myReviewOf(detail(reviews: [review("me", "APPROVED"), review("me", "DISMISSED")]), me: "me", isRequested: false) == .none)
        #expect(myReviewOf(detail(reviews: [review("other", "APPROVED")]), me: "me", isRequested: false) == .none)
    }

    @Test func approvedByOthersKeepsLatestDecisiveHumanApprovals() {
        let reviews = [
            review("alice", "APPROVED"),
            review("bob", "APPROVED"),
            review("bob", "CHANGES_REQUESTED"),
            review("carol", "APPROVED"),
            review("carol", "COMMENTED"),
            review("me", "APPROVED"),
            review("cursor", "APPROVED"),
            ReviewNode(author: Author(login: "some-app", typename: "Bot"), state: "APPROVED"),
            review("renovate[bot]", "APPROVED"),
            ReviewNode(author: nil, state: "APPROVED"),
        ]
        #expect(approvedByOthersOf(detail(reviews: reviews), me: "me") == ["alice", "carol"])
        #expect(changesRequestedByOthersOf(detail(reviews: reviews), me: "me") == ["bob"])
    }

    @Test func checksSplitIntoFailingNeutralAndRunningWithSkippedPassing() {
        let mixed = detail(checks: [
            .checkRun(name: "test", status: "COMPLETED", conclusion: "SUCCESS"),
            .checkRun(name: "deploy-dev", status: "COMPLETED", conclusion: "FAILURE"),
            .checkRun(name: "deploy-staging", status: "COMPLETED", conclusion: "SKIPPED"),
            .checkRun(name: "Cursor Bugbot", status: "COMPLETED", conclusion: "NEUTRAL"),
            .checkRun(name: "build", status: "IN_PROGRESS", conclusion: nil),
            .checkRun(name: "build", status: "QUEUED", conclusion: nil),
            .statusContext(context: "ci/legacy", state: "ERROR"),
            .statusContext(context: "ci/wait", state: "EXPECTED"),
        ], rollupState: "FAILURE")
        #expect(checksOf(mixed) == Checks(failing: ["deploy-dev", "ci/legacy"], neutral: ["Cursor Bugbot"], pending: ["build", "ci/wait"]))
        #expect(checksOf(detail()) == Checks())
        #expect(checksOf(DetailNode()) == Checks())
    }

    @Test func checkNodesDecodeFromGraphQL() throws {
        let json = #"[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":null},{"__typename":"StatusContext","context":"ci","state":"SUCCESS"}]"#
        let nodes = try JSONDecoder().decode([CheckNode].self, from: Data(json.utf8))
        #expect(checksOf(detail(checks: nodes)) == Checks(failing: ["test"]))
    }

    @Test func nextLinkReadsRelNext() {
        let header = #"<https://api.github.com/user/teams?page=2>; rel="next", <https://api.github.com/user/teams?page=5>; rel="last""#
        #expect(nextLink(header)?.absoluteString == "https://api.github.com/user/teams?page=2")
        #expect(nextLink(#"<https://api.github.com/x?page=1>; rel="prev""#) == nil)
        #expect(nextLink(nil) == nil)
    }

    @Test func commentLinksPointAtNewestCommentAndFirstUnresolvedThread() {
        let comment = { (url: String?) in CommentNode(author: user("alice"), url: url) }
        let linked = DetailNode(
            reviewThreads: Nodes(nodes: [
                ThreadNode(isResolved: true, comments: Nodes(nodes: [comment("https://x/resolved")])),
                ThreadNode(isResolved: false, comments: Nodes(nodes: [comment("https://x/r1"), comment("https://x/r2")])),
                ThreadNode(isResolved: false, comments: Nodes(nodes: [comment("https://x/r3")])),
            ]),
            comments: CommentConnection(totalCount: 2, nodes: [comment("https://x/c1"), comment("https://x/c2")])
        )
        #expect(latestCommentUrlOf(linked) == "https://x/c2")
        #expect(firstUnresolvedThreadUrlOf(linked) == "https://x/r1")
    }

    @Test func commentLinksAreNilWithNothingToOpen() {
        #expect(latestCommentUrlOf(DetailNode()) == nil)
        #expect(firstUnresolvedThreadUrlOf(DetailNode()) == nil)
        let resolvedOnly = DetailNode(
            reviewThreads: Nodes(nodes: [ThreadNode(isResolved: true, comments: Nodes(nodes: [CommentNode(author: user("a"), url: "https://x/r")]))]),
            comments: CommentConnection(totalCount: 1, nodes: [CommentNode(author: user("a"), url: "")])
        )
        #expect(latestCommentUrlOf(resolvedOnly) == nil)
        #expect(firstUnresolvedThreadUrlOf(resolvedOnly) == nil)
    }

    @Test func queuePrDecodesFromGraphQLWithCommentLinks() throws {
        let json = #"""
            {"headRefOid":"h","reviews":{"nodes":[]},"reviewRequests":{"nodes":[]},"commits":{"nodes":[]},
             "reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"bob","__typename":"User"},"url":"https://github.com/o/r/pull/1#discussion_r9"}]}}]},
             "comments":{"totalCount":1,"nodes":[{"author":{"login":"bob","__typename":"User"},"url":"https://github.com/o/r/pull/1#issuecomment-5"}]}}
            """#
        let detail = try JSONDecoder().decode(DetailNode.self, from: Data(json.utf8))
        let node = ListNode(number: 1, title: "t", url: "u", isDraft: false, headRefName: "b", createdAt: "c", updatedAt: "c", author: user("bob"))
        let pr = queuePr(Candidate(node: node, repo: Repo(owner: "o", name: "r")), detail: detail, me: "me")
        #expect(pr.latestCommentUrl == "https://github.com/o/r/pull/1#issuecomment-5")
        #expect(pr.firstUnresolvedThreadUrl == "https://github.com/o/r/pull/1#discussion_r9")
    }

    @Test func storedQueuePrsWithoutCommentLinksStillDecode() throws {
        var pr = makePr(1)
        pr.latestCommentUrl = "https://x/c"
        pr.firstUnresolvedThreadUrl = "https://x/t"
        let encoded = try JSONEncoder().encode(pr)
        #expect(try JSONDecoder().decode(QueuePr.self, from: encoded) == pr)
        var legacy = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["latestCommentUrl"] = nil
        legacy["firstUnresolvedThreadUrl"] = nil
        let decoded = try JSONDecoder().decode(QueuePr.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.latestCommentUrl == nil)
        #expect(decoded.firstUnresolvedThreadUrl == nil)
        #expect(decoded == makePr(1))
    }
}
