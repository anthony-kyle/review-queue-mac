import Foundation

private let botLogins: Set<String> = ["cursor", "dependabot", "renovate", "github-actions", "copilot"]
private let decisiveStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]
private let passingConclusions: Set<String> = ["SUCCESS", "SKIPPED"]

struct Author: Decodable, Equatable, Sendable {
    let login: String
    var typename: String? = "User"

    enum CodingKeys: String, CodingKey {
        case login
        case typename = "__typename"
    }
}

struct Nodes<T: Decodable & Sendable>: Decodable, Sendable {
    let nodes: [T]
}

struct ListNode: Decodable, Sendable {
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let headRefName: String
    let createdAt: String
    let updatedAt: String
    let author: Author?
    var id: String?
    var repository: RepositoryRef?
}

struct RepositoryRef: Decodable, Sendable {
    let name: String
    let owner: Author
}

struct CommitRef: Decodable, Sendable {
    let oid: String
}

struct ReviewNode: Decodable, Sendable {
    let author: Author?
    let state: String
    var commit: CommitRef?
    var id: String?
    var submittedAt: String?
}

struct PageInfo: Decodable, Sendable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct CommentNode: Decodable, Sendable {
    let author: Author?
    var id: String?
    var createdAt: String?
    var bodyText: String?
    var url: String?
    var isMinimized: Bool?
}

struct ThreadNode: Decodable, Sendable {
    let isResolved: Bool
    let comments: Nodes<CommentNode>
}

struct CommentConnection: Decodable, Sendable {
    let totalCount: Int
    let nodes: [CommentNode]
}

struct Reviewer: Decodable, Sendable {
    var login: String?
    var slug: String?
}

struct ReviewRequestNode: Decodable, Sendable {
    let requestedReviewer: Reviewer?
}

struct Named: Decodable, Sendable {
    let name: String?
}

struct WorkflowRun: Decodable, Sendable {
    let workflow: Named?
}

struct CheckSuite: Decodable, Sendable {
    let app: Named?
    let workflowRun: WorkflowRun?
}

/// A CI check as GitHub reports it. `source` is the workflow or CI app (check runs) or the status's creator, with any
/// `[bot]` suffix removed; nil when GitHub names none.
enum CheckNode: Decodable, Sendable {
    case checkRun(name: String, status: String, conclusion: String?, source: String? = nil)
    case statusContext(context: String, state: String, source: String? = nil)

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, status, conclusion, context, state, checkSuite, creator
    }

    struct Creator: Decodable {
        let login: String?
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .typename) == "CheckRun" {
            self = .checkRun(
                name: try c.decode(String.self, forKey: .name),
                status: try c.decode(String.self, forKey: .status),
                conclusion: try c.decodeIfPresent(String.self, forKey: .conclusion),
                source: try c.decodeIfPresent(CheckSuite.self, forKey: .checkSuite).flatMap { $0.workflowRun?.workflow?.name ?? $0.app?.name }
            )
        } else {
            let login = try c.decodeIfPresent(Creator.self, forKey: .creator)?.login
            self = .statusContext(
                context: try c.decode(String.self, forKey: .context),
                state: try c.decode(String.self, forKey: .state),
                source: login.map { $0.hasSuffix("[bot]") ? String($0.dropLast("[bot]".count)) : $0 }
            )
        }
    }
}

struct StatusRollup: Decodable, Sendable {
    let state: String
    let contexts: Nodes<CheckNode>
}

struct CommitStatus: Decodable, Sendable {
    let statusCheckRollup: StatusRollup?
}

struct CommitNode: Decodable, Sendable {
    let commit: CommitStatus
}

struct DetailNode: Decodable, Sendable {
    var headRefOid = "head"
    var reviews = Nodes<ReviewNode>(nodes: [])
    var reviewThreads = Nodes<ThreadNode>(nodes: [])
    var comments = CommentConnection(totalCount: 0, nodes: [])
    var reviewRequests = Nodes<ReviewRequestNode>(nodes: [])
    var commits = Nodes<CommitNode>(nodes: [])
    var mergeable: String?
    var mergeStateStatus: String?
    var reviewDecision: String?

    var rollup: StatusRollup? { commits.nodes.first?.commit.statusCheckRollup }
}

struct Repo: Hashable, Sendable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
}

struct Candidate: Sendable {
    let node: ListNode
    let repo: Repo
}

func isBot(_ author: Author?) -> Bool {
    guard let author else { return true }
    return author.typename == "Bot" || author.login.hasSuffix("[bot]") || botLogins.contains(author.login)
}

/// A bot login reduced for comparison: trimmed, lowercased, without GitHub's REST `[bot]` suffix.
func botKey(_ login: String) -> String {
    let lowered = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowered.hasSuffix("[bot]") ? String(lowered.dropLast("[bot]".count)) : lowered
}

/// Whether the author is a bot the person listed in Settings; `karbi-github` and `Karbi-GitHub[bot]` both match `karbi-github`.
func isAllowedBot(_ author: Author?, _ settings: QueueSettings) -> Bool {
    guard let author else { return false }
    return settings.allowedBotAuthors.contains { botKey($0) == botKey(author.login) }
}

/// Whether a PR by this author belongs in the queue: humans and allowed bots, never you.
func isQueueAuthor(_ author: Author?, me: String, _ settings: QueueSettings) -> Bool {
    author?.login != me && (!isBot(author) || isAllowedBot(author, settings))
}

/// Pulls the Linear identifier out of a branch name or title: `eng-2368-foo` and `alex/eng-2291` both give `ENG-2368`/`ENG-2291`.
/// Single-letter prefixes and date-like numbers are skipped so `w-9` and `report-2026-08-04` never match.
public func storyIdOf(_ branch: String, _ title: String) -> String? {
    guard let pattern = try? NSRegularExpression(pattern: #"(?:^|[^a-z0-9])([a-z]{2,6})-(\d+)(?![\d.]|-\d)"#, options: .caseInsensitive) else {
        return nil
    }
    for source in [branch, title] {
        let text = source as NSString
        guard let match = pattern.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) else { continue }
        return "\(text.substring(with: match.range(at: 1)).uppercased())-\(text.substring(with: match.range(at: 2)))"
    }
    return nil
}

/// Your standing on a PR from your last decisive review. Changes count as addressed once the head moved past the
/// reviewed commit or the author re-requested you, since GitHub drops you from the requests when you submit.
func myReviewOf(_ detail: DetailNode, me: String, isRequested: Bool) -> MyReview {
    guard let last = myLastStandingReview(detail, me: me) else { return .none }
    if last.state == "APPROVED" { return .approved }
    return isRequested || last.commit?.oid != detail.headRefOid ? .changesAddressed : .changesPending
}

/// Your latest approval or changes-request, or nil when you have none or your latest decisive review was dismissed.
func myLastStandingReview(_ detail: DetailNode, me: String) -> ReviewNode? {
    let last = detail.reviews.nodes.last { $0.author?.login == me && decisiveStates.contains($0.state) }
    return last?.state == "DISMISSED" ? nil : last
}

/// GitHub's files view limited to commits pushed since your standing review, or nil when the head hasn't moved. After
/// a force-push GitHub may not resolve the reviewed commit; the full GitHub Review link stays as the fallback.
func sinceMyReviewUrlOf(_ detail: DetailNode, me: String, url: String) -> String? {
    guard let reviewed = myLastStandingReview(detail, me: me)?.commit?.oid, reviewed != detail.headRefOid else { return nil }
    return "\(url)/files/\(reviewed)..\(detail.headRefOid)"
}

/// Other humans whose latest decisive review is an approval. A later changes-request or dismissal withdraws it.
func approvedByOthersOf(_ detail: DetailNode, me: String) -> [String] {
    othersWithLatestReview(detail, me: me, state: "APPROVED")
}

/// Other humans whose latest decisive review is a changes-request. A later approval or dismissal withdraws it.
func changesRequestedByOthersOf(_ detail: DetailNode, me: String) -> [String] {
    othersWithLatestReview(detail, me: me, state: "CHANGES_REQUESTED")
}

private func othersWithLatestReview(_ detail: DetailNode, me: String, state: String) -> [String] {
    latestDecisive(detail.reviews.nodes.compactMap(PrReview.init), excluding: me).filter { $0.state == state }.map(\.author)
}

/// Each human reviewer's latest approval, changes-request or dismissal, in order of their first such review. Bots and
/// `excluding` are skipped.
func latestDecisive(_ reviews: [PrReview], excluding me: String? = nil) -> [PrReview] {
    var order: [String] = []
    var latest: [String: PrReview] = [:]
    for review in reviews where !review.isBot && review.author != me && decisiveStates.contains(review.state) {
        if latest[review.author] == nil { order.append(review.author) }
        latest[review.author] = review
    }
    return order.compactMap { latest[$0] }
}

extension PrReview {
    init?(_ node: ReviewNode) {
        guard let author = node.author else { return nil }
        self.init(id: node.id ?? "", author: author.login, isBot: ReviewQueueCore.isBot(author), state: node.state, commitOid: node.commit?.oid)
    }
}

extension PrComment {
    init?(_ node: CommentNode, isInResolvedThread: Bool = false) {
        guard let author = node.author, let id = node.id else { return nil }
        self.init(
            id: id,
            author: author.login,
            isBot: ReviewQueueCore.isBot(author),
            createdAt: node.createdAt ?? "",
            body: snippet(node.bodyText ?? ""),
            url: node.url ?? "",
            isResolved: isInResolvedThread || node.isMinimized == true
        )
    }
}

struct Checks: Equatable, Sendable {
    var failing: [FailedCheck] = []
    var neutral: [String] = []
    var pending: [String] = []
}

/// Splits a PR's latest CI checks into failing (with their source), neutral and still-running names; skipped runs count
/// as passing. A check with no known source is its own source. Neutral is kept apart because tools such as Cursor Bugbot report findings that way without failing the build.
func checksOf(_ detail: DetailNode) -> Checks {
    var checks = Checks()
    for check in detail.rollup?.contexts.nodes ?? [] {
        switch check {
        case let .checkRun(name, status, conclusion, source):
            if status != "COMPLETED" { checks.pending.append(name) }
            else if conclusion == "NEUTRAL" { checks.neutral.append(name) }
            else if !passingConclusions.contains(conclusion ?? "") { checks.failing.append(FailedCheck(name: name, source: source ?? name)) }
        case let .statusContext(context, state, source):
            if state == "PENDING" || state == "EXPECTED" { checks.pending.append(context) }
            else if state != "SUCCESS" { checks.failing.append(FailedCheck(name: context, source: source ?? context)) }
        }
    }
    return Checks(failing: unique(checks.failing), neutral: unique(checks.neutral), pending: unique(checks.pending))
}

func commentersOf(_ detail: DetailNode) -> [Commenter] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    let authors = detail.comments.nodes.map(\.author) + detail.reviewThreads.nodes.flatMap { $0.comments.nodes.map(\.author) }
    for case let author? in authors {
        if counts[author.login] == nil { order.append(author.login) }
        counts[author.login, default: 0] += 1
    }
    return order.map { Commenter(login: $0, count: counts[$0] ?? 0) }.sorted { $0.count > $1.count }
}

/// The newest conversation comment's URL, for the comments row; GitHub lists comments oldest first.
func latestCommentUrlOf(_ detail: DetailNode) -> String? {
    nonEmpty(detail.comments.nodes.last?.url)
}

/// The first comment of the first unresolved review thread, for the threads row.
func firstUnresolvedThreadUrlOf(_ detail: DetailNode) -> String? {
    nonEmpty(detail.reviewThreads.nodes.first { !$0.isResolved }?.comments.nodes.first?.url)
}

private func nonEmpty(_ text: String?) -> String? {
    text.flatMap { $0.isEmpty ? nil : $0 }
}

func queuePr(_ candidate: Candidate, detail: DetailNode, me: String) -> QueuePr {
    let pr = candidate.node
    let isReviewRequested = detail.reviewRequests.nodes.contains { $0.requestedReviewer?.login == me }
    let threads = detail.reviewThreads.nodes
    let checks = checksOf(detail)
    return QueuePr(
        key: "\(candidate.repo.owner)/\(candidate.repo.name)#\(pr.number)",
        owner: candidate.repo.owner,
        repo: candidate.repo.name,
        number: pr.number,
        title: pr.title,
        url: pr.url,
        author: pr.author?.login ?? "ghost",
        isDraft: pr.isDraft,
        storyId: storyIdOf(pr.headRefName, pr.title),
        linearReviewUrl: nil,
        myReview: myReviewOf(detail, me: me, isRequested: isReviewRequested),
        isReviewRequested: isReviewRequested,
        approvedByOthers: approvedByOthersOf(detail, me: me),
        changesRequestedByOthers: changesRequestedByOthersOf(detail, me: me),
        commentCount: detail.comments.totalCount,
        unresolvedThreads: threads.filter { !$0.isResolved }.count,
        totalThreads: threads.count,
        commenters: commentersOf(detail),
        ci: detail.rollup?.state,
        failingChecks: checks.failing,
        neutralChecks: checks.neutral,
        pendingChecks: checks.pending,
        createdAt: pr.createdAt,
        updatedAt: pr.updatedAt,
        latestCommentUrl: latestCommentUrlOf(detail),
        firstUnresolvedThreadUrl: firstUnresolvedThreadUrlOf(detail),
        sinceMyReviewUrl: sinceMyReviewUrlOf(detail, me: me, url: pr.url)
    )
}

/// One of your open PRs with everything My PRs classifies and alerts on. Your own reviews are left out of `reviews`;
/// your own comments stay in `comments` and are filtered where "new" is decided.
func myPr(_ candidate: Candidate, detail: DetailNode, me: String) -> MyPr {
    let pr = candidate.node
    let threads = detail.reviewThreads.nodes
    let checks = checksOf(detail)
    let comments = detail.comments.nodes.compactMap { PrComment($0) }
        + threads.flatMap { thread in thread.comments.nodes.compactMap { PrComment($0, isInResolvedThread: thread.isResolved) } }
    return MyPr(
        key: "\(candidate.repo.owner)/\(candidate.repo.name)#\(pr.number)",
        nodeId: pr.id ?? "",
        owner: candidate.repo.owner,
        repo: candidate.repo.name,
        number: pr.number,
        title: pr.title,
        url: pr.url,
        isDraft: pr.isDraft,
        storyId: storyIdOf(pr.headRefName, pr.title),
        linearReviewUrl: nil,
        headRefOid: detail.headRefOid,
        reviewDecision: detail.reviewDecision,
        mergeable: detail.mergeable,
        mergeStateStatus: detail.mergeStateStatus,
        reviews: detail.reviews.nodes.compactMap(PrReview.init).filter { $0.author != me },
        comments: comments.sorted { $0.createdAt < $1.createdAt },
        requestedReviewers: detail.reviewRequests.nodes.compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.slug },
        commentCount: detail.comments.totalCount,
        unresolvedThreads: threads.filter { !$0.isResolved }.count,
        totalThreads: threads.count,
        ci: detail.rollup?.state,
        failingChecks: checks.failing,
        neutralChecks: checks.neutral,
        pendingChecks: checks.pending,
        createdAt: pr.createdAt,
        updatedAt: pr.updatedAt,
        latestCommentUrl: latestCommentUrlOf(detail),
        firstUnresolvedThreadUrl: firstUnresolvedThreadUrlOf(detail)
    )
}

struct ClosureNode: Decodable, Sendable {
    let id: String
    let state: String
    var mergedBy: Author?
    var timelineItems = Nodes<ClosedEventNode>(nodes: [])
}

struct ClosedEventNode: Decodable, Sendable {
    var actor: Author?
}

/// How a PR that left your open list ended: merged (by `mergedBy`), closed (by the last close event's actor), or still
/// open, which is what an excluded or re-filtered PR reads as.
func closureOf(_ node: ClosureNode) -> PrClosure {
    switch node.state {
    case "MERGED": .merged(by: node.mergedBy?.login)
    case "CLOSED": .closed(by: node.timelineItems.nodes.last?.actor?.login)
    default: .open
    }
}

/// The URL in a `Link` header's `rel="next"` entry, which GitHub REST uses for pagination.
func nextLink(_ header: String?) -> URL? {
    guard let header else { return nil }
    for part in header.split(separator: ",") where part.contains(#"rel="next""#) {
        guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
        return URL(string: String(part[part.index(after: start)..<end]))
    }
    return nil
}

func unique<T: Hashable>(_ items: [T]) -> [T] {
    var seen = Set<T>()
    return items.filter { seen.insert($0).inserted }
}
