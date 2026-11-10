import Foundation
@testable import ReviewQueueCore

func makePr(
    _ number: Int,
    author: String = "octocat",
    isDraft: Bool = false,
    myReview: MyReview = .none,
    isReviewRequested: Bool = false,
    approvedByOthers: [String] = [],
    changesRequestedByOthers: [String] = [],
    commentCount: Int = 0,
    unresolvedThreads: Int = 0,
    ci: String? = nil,
    createdAt: String = "2026-10-01T00:00:00Z",
    updatedAt: String? = nil
) -> QueuePr {
    QueuePr(
        key: "acme/widgets#\(number)",
        owner: "acme",
        repo: "widgets",
        number: number,
        title: "PR \(number)",
        url: "https://github.com/acme/widgets/pull/\(number)",
        author: author,
        isDraft: isDraft,
        storyId: "ENG-\(number)",
        linearReviewUrl: nil,
        myReview: myReview,
        isReviewRequested: isReviewRequested,
        approvedByOthers: approvedByOthers,
        changesRequestedByOthers: changesRequestedByOthers,
        commentCount: commentCount,
        unresolvedThreads: unresolvedThreads,
        totalThreads: unresolvedThreads,
        commenters: [],
        ci: ci,
        failingChecks: [],
        neutralChecks: [],
        pendingChecks: [],
        createdAt: createdAt,
        updatedAt: updatedAt ?? createdAt
    )
}

func user(_ login: String) -> Author {
    Author(login: login)
}

func review(_ login: String, _ state: String, oid: String = "head") -> ReviewNode {
    ReviewNode(author: user(login), state: state, commit: CommitRef(oid: oid))
}

func detail(reviews: [ReviewNode] = [], headRefOid: String = "head", checks: [CheckNode] = [], rollupState: String = "SUCCESS") -> DetailNode {
    DetailNode(
        headRefOid: headRefOid,
        reviews: Nodes(nodes: reviews),
        commits: Nodes(nodes: [CommitNode(commit: CommitStatus(statusCheckRollup: StatusRollup(state: rollupState, contexts: Nodes(nodes: checks))))])
    )
}

func makeMyPr(
    _ number: Int,
    owner: String = "acme",
    repo: String = "widgets",
    isDraft: Bool = false,
    headRefOid: String = "head",
    reviewDecision: String? = nil,
    mergeable: String? = "MERGEABLE",
    reviews: [PrReview] = [],
    comments: [PrComment] = [],
    unresolvedThreads: Int = 0,
    ci: String? = "SUCCESS",
    failingChecks: [String] = [],
    createdAt: String = "2026-10-01T00:00:00Z",
    updatedAt: String? = nil
) -> MyPr {
    MyPr(
        key: "\(owner)/\(repo)#\(number)",
        nodeId: "PR_\(number)",
        owner: owner,
        repo: repo,
        number: number,
        title: "PR \(number)",
        url: "https://github.com/\(owner)/\(repo)/pull/\(number)",
        isDraft: isDraft,
        storyId: "ENG-\(number)",
        linearReviewUrl: nil,
        headRefOid: headRefOid,
        reviewDecision: reviewDecision,
        mergeable: mergeable,
        reviews: reviews,
        comments: comments,
        requestedReviewers: [],
        commentCount: comments.count,
        unresolvedThreads: unresolvedThreads,
        totalThreads: unresolvedThreads,
        ci: ci,
        failingChecks: failingChecks,
        neutralChecks: [],
        createdAt: createdAt,
        updatedAt: updatedAt ?? createdAt
    )
}

func prComment(_ id: String, by author: String = "alice", isBot: Bool = false, body: String = "Please rename this", isResolved: Bool = false) -> PrComment {
    PrComment(id: id, author: author, isBot: isBot, createdAt: "2026-10-02T00:00:00Z", body: body, url: "https://github.com/c/\(id)", isResolved: isResolved)
}

func prReview(_ id: String, by author: String, _ state: String, oid: String = "head", isBot: Bool = false) -> PrReview {
    PrReview(id: id, author: author, isBot: isBot, state: state, commitOid: oid)
}

func myContext(
    me: String = "me",
    acknowledged: Set<String> = [],
    _ change: (inout MyPrsSettings) -> Void = { _ in }
) -> MyPrsContext {
    var settings = MyPrsSettings()
    change(&settings)
    return MyPrsContext(me: me, settings: settings, acknowledged: acknowledged)
}
