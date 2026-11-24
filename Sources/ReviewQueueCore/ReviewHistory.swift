import Foundation

/// One submitted review as the statistics read it.
public struct HistoryReview: Codable, Equatable, Sendable {
    public let author: String
    public let isBot: Bool
    public let state: String
    public let submittedAt: Date

    public init(author: String, isBot: Bool = false, state: String, submittedAt: Date) {
        self.author = author
        self.isBot = isBot
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// A request for `reviewer`'s review, from a review-requested timeline event.
public struct HistoryRequest: Codable, Equatable, Sendable {
    public let reviewer: String
    public let at: Date

    public init(reviewer: String, at: Date) {
        self.reviewer = reviewer
        self.at = at
    }
}

/// A PR in a team repo with what review counts and response times need: when it opened and was last marked ready,
/// whose review was requested and when, and every submitted review. `repo` is `owner/name`.
public struct HistoryPr: Codable, Equatable, Sendable {
    public let repo: String
    public let number: Int
    public let author: String
    public let createdAt: Date
    public let updatedAt: Date
    public let readyAt: Date?
    public let requests: [HistoryRequest]
    public let reviews: [HistoryReview]

    public init(
        repo: String,
        number: Int,
        author: String,
        createdAt: Date,
        updatedAt: Date,
        readyAt: Date? = nil,
        requests: [HistoryRequest] = [],
        reviews: [HistoryReview] = []
    ) {
        self.repo = repo
        self.number = number
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.readyAt = readyAt
        self.requests = requests
        self.reviews = reviews
    }

    public var key: String { "\(repo)#\(number)" }
}

/// The cached review history of the chosen teams' repos: who you are, the teams' members, each repo's last complete
/// fetch, and the PRs updated within the retention window. `completedAt` is the last refresh that reached every repo,
/// which decides staleness.
public struct ReviewHistory: Codable, Equatable, Sendable {
    static let overlap: TimeInterval = 10 * 60

    public var me: String?
    public var members: [String] = []
    public var fetchedAt: [String: Date] = [:]
    public var prs: [HistoryPr] = []
    public var completedAt: Date?

    public init(me: String? = nil, members: [String] = [], fetchedAt: [String: Date] = [:], prs: [HistoryPr] = [], completedAt: Date? = nil) {
        self.me = me
        self.members = members
        self.fetchedAt = fetchedAt
        self.prs = prs
        self.completedAt = completedAt
    }

    /// Where a refresh of `repo` can stop paging: a little before its last complete fetch, so edits racing that fetch
    /// are picked up, but never before `start`. A repo never fetched in full pages back to `start`.
    public func fetchSince(_ repo: String, start: Date) -> Date {
        guard let last = fetchedAt[repo] else { return start }
        return max(last.addingTimeInterval(-Self.overlap), start)
    }

    /// This history with `fetched` upserted by key, and `repo` marked fetched at `at` only when `isComplete`, so a
    /// fetch cut short pages back as far again next time.
    public func merged(_ fetched: [HistoryPr], repo: String, isComplete: Bool, at: Date) -> ReviewHistory {
        var byKey = Dictionary(prs.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        for pr in fetched { byKey[pr.key] = pr }
        var next = self
        next.prs = byKey.values.sorted { $0.key < $1.key }
        if isComplete { next.fetchedAt[repo] = at }
        return next
    }

    /// Only PRs and fetch marks for `repos`, and only PRs updated on or after `start`.
    public func pruned(repos: Set<String>, start: Date) -> ReviewHistory {
        var next = self
        next.prs = prs.filter { repos.contains($0.repo) && $0.updatedAt >= start }
        next.fetchedAt = fetchedAt.filter { repos.contains($0.key) }
        return next
    }
}

struct HistoryPageData: Decodable, Sendable {
    let rateLimit: RateLimit?
    let repository: Repository?

    struct RateLimit: Decodable, Sendable {
        let remaining: Int
        let resetAt: String
    }

    struct Repository: Decodable, Sendable {
        let pullRequests: Connection
    }

    struct Connection: Decodable, Sendable {
        let pageInfo: PageInfo
        let nodes: [HistoryNode]
    }
}

struct HistoryNode: Decodable, Sendable {
    let number: Int
    let createdAt: String
    let updatedAt: String
    let author: Author?
    let timelineItems: Nodes<TimelineNode>
    let reviews: Nodes<ReviewNode>
}

struct TimelineNode: Decodable, Sendable {
    let typename: String
    var createdAt: String?
    var requestedReviewer: Reviewer?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case createdAt, requestedReviewer
    }
}

/// A history page's PR as a `HistoryPr`, or nil when its times don't parse. The ready time is the last ready-for-review
/// event; requests keep only users, since a team request names no one. Reviews without an author or submission time
/// (pending drafts) are dropped.
func historyPr(_ node: HistoryNode, repo: String) -> HistoryPr? {
    guard let createdAt = isoDate(node.createdAt), let updatedAt = isoDate(node.updatedAt) else { return nil }
    let events = node.timelineItems.nodes
    return HistoryPr(
        repo: repo,
        number: node.number,
        author: node.author?.login ?? "ghost",
        createdAt: createdAt,
        updatedAt: updatedAt,
        readyAt: events.filter { $0.typename == "ReadyForReviewEvent" }.compactMap { $0.createdAt.flatMap(isoDate) }.max(),
        requests: events.compactMap { event in
            guard event.typename == "ReviewRequestedEvent", let login = event.requestedReviewer?.login,
                  let at = event.createdAt.flatMap(isoDate) else { return nil }
            return HistoryRequest(reviewer: login, at: at)
        },
        reviews: node.reviews.nodes.compactMap { review in
            guard let author = review.author, let at = review.submittedAt.flatMap(isoDate) else { return nil }
            return HistoryReview(author: author.login, isBot: isBot(author), state: review.state, submittedAt: at)
        }
    )
}

func isoDate(_ text: String) -> Date? {
    try? Date(text, strategy: .iso8601)
}
