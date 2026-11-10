import Foundation

/// A comment on one of your PRs. `isResolved` is true when its review thread is resolved or the comment is hidden
/// (minimized) on GitHub, either of which means it needs nothing more from you.
public struct PrComment: Equatable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let isBot: Bool
    public let createdAt: String
    public let body: String
    public let url: String
    public var isResolved = false
}

public struct PrReview: Equatable, Sendable {
    public let id: String
    public let author: String
    public let isBot: Bool
    public let state: String
    public let commitOid: String?
}

public enum MyBlock: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case needsYou, ready, waiting, drafts

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .ready: "Ready to merge"
        case .waiting: "Waiting on reviewers"
        case .drafts: "Drafts"
        }
    }

    public var isOpenByDefault: Bool { self != .drafts }

    public var areRowsExpandedByDefault: Bool { self == .needsYou }
}

/// One of your own open PRs.
public struct MyPr: TrackedPr {
    public let key: String
    public let nodeId: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let isDraft: Bool
    public let storyId: String?
    public var linearReviewUrl: String?
    public let headRefOid: String
    public let reviewDecision: String?
    public let mergeable: String?
    public let reviews: [PrReview]
    public let comments: [PrComment]
    public let requestedReviewers: [String]
    public let commentCount: Int
    public let unresolvedThreads: Int
    public let totalThreads: Int
    public let ci: String?
    public let failingChecks: [String]
    public let neutralChecks: [String]
    public let createdAt: String
    public let updatedAt: String
    public var latestCommentUrl: String? = nil
    public var firstUnresolvedThreadUrl: String? = nil

    public var id: String { key }
    public var approvals: [String] { approvedBy }
    public var changesRequests: [String] { changesRequestedBy }
    public var approvedBy: [String] { latestDecisive(reviews).filter { $0.state == "APPROVED" }.map(\.author) }
    public var changesRequestedBy: [String] { latestDecisive(reviews).filter { $0.state == "CHANGES_REQUESTED" }.map(\.author) }

    /// Reviewers whose standing changes-request was made on the current head, so nothing has been pushed since.
    public var changesRequestedOnHead: [String] {
        latestDecisive(reviews).filter { $0.state == "CHANGES_REQUESTED" && $0.commitOid == headRefOid }.map(\.author)
    }

    public var isConflicting: Bool { mergeable == "CONFLICTING" }

    /// GitHub's review decision says approved, or someone approved and nobody's changes-request still stands.
    public var isApproved: Bool { reviewDecision == "APPROVED" || (!approvedBy.isEmpty && changesRequestedBy.isEmpty) }
    public var ref: MyPrRef { MyPrRef(nodeId: nodeId, owner: owner, repo: repo, number: number, title: title, url: url) }
}

/// Enough of an open PR to look it up and announce it after it leaves the open list.
public struct MyPrRef: Codable, Equatable, Sendable {
    public let nodeId: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
}

public enum PrClosure: Equatable, Sendable {
    case open
    case merged(by: String?)
    case closed(by: String?)
}

public struct MyPrsResult: Sendable {
    public let prs: [MyPr]
    public let me: String
}

/// Who you are plus the choices and acknowledgements that decide which comments are new.
public struct MyPrsContext: Equatable, Sendable {
    public let me: String
    public let settings: MyPrsSettings
    public let acknowledged: Set<String>

    public init(me: String, settings: MyPrsSettings, acknowledged: Set<String>) {
        self.me = me
        self.settings = settings
        self.acknowledged = acknowledged
    }
}

/// Left out of My PRs by an excluded org or `owner/name` repo, compared without case.
public func isExcluded(_ pr: MyPr, _ settings: MyPrsSettings) -> Bool {
    settings.excludedOrgs.contains { $0.caseInsensitiveCompare(pr.owner) == .orderedSame }
        || settings.excludedRepos.contains { $0.caseInsensitiveCompare("\(pr.owner)/\(pr.repo)") == .orderedSame }
}

public func withoutExcluded(_ prs: [MyPr], _ settings: MyPrsSettings) -> [MyPr] {
    prs.filter { !isExcluded($0, settings) }
}

/// A comment counts when it isn't yours or from an ignored commenter, and from a bot only while bot comments are on.
func isCounted(author: String, isBot: Bool, _ context: MyPrsContext) -> Bool {
    author != context.me
        && !context.settings.ignoredCommenters.contains(author)
        && (context.settings.isBotCommentsShown || !isBot)
}

/// Comments still waiting on you: counted (see `isCounted`), not resolved on GitHub and not yet acknowledged, oldest
/// first.
public func newComments(_ pr: MyPr, _ context: MyPrsContext) -> [PrComment] {
    pr.comments.filter {
        !$0.isResolved && !context.acknowledged.contains($0.id) && isCounted(author: $0.author, isBot: $0.isBot, context)
    }
}

/// Why a PR needs you, in card order: changes requested on the current head, new comments, failing CI, a conflict.
public func needsYouReasons(_ pr: MyPr, _ context: MyPrsContext) -> [String] {
    var reasons: [String] = []
    let requesters = pr.changesRequestedOnHead
    if !requesters.isEmpty { reasons.append("Changes requested by \(requesters.joined(separator: ", "))") }
    let fresh = newComments(pr, context).count
    if fresh > 0 { reasons.append(fresh == 1 ? "1 new comment" : "\(fresh) new comments") }
    if isCiFailing(pr.ci) { reasons.append("CI failing") }
    if pr.isConflicting { reasons.append("Conflict") }
    return reasons
}

public func myReasonOf(_ pr: MyPr, _ context: MyPrsContext) -> String? {
    let reasons = needsYouReasons(pr, context)
    return reasons.isEmpty ? nil : reasons.joined(separator: " · ")
}

/// Places a PR: anything that needs you wins, drafts included; then approved and mergeable; then waiting; then drafts.
public func myBlockOf(_ pr: MyPr, _ context: MyPrsContext) -> MyBlock {
    if !needsYouReasons(pr, context).isEmpty { return .needsYou }
    if pr.isDraft { return .drafts }
    return pr.isApproved ? .ready : .waiting
}

public func myBlockLists(_ prs: [MyPr], _ context: MyPrsContext, dismissals: Dismissals = [:]) -> [MyBlock: BlockList<MyPr>] {
    Dictionary(uniqueKeysWithValues: MyBlock.allCases.map { block in
        (block, blockList(prs.filter { myBlockOf($0, context) == block }, sort: context.settings.sort(block), dismissals: dismissals))
    })
}

/// The My PRs pill's colour: urgent while anything needs you, waiting while PRs are ready or with reviewers, clear
/// otherwise (drafts alone stay clear).
public func myMenuTone(needsYou: Int, ready: Int, waiting: Int) -> MenuTone {
    if needsYou > 0 { return .urgent }
    return ready + waiting > 0 ? .waiting : .clear
}
