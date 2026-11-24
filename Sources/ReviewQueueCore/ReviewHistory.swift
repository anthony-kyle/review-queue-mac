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

/// A review request to one person (`reviewer`) or a team (`team`, as `org/slug`) at `at`, or the removal of one, from
/// the PR's timeline. Team requests are kept as the team and expanded to its members only when stats are computed, so
/// the cache never bakes in who was on the team.
public struct HistoryRequest: Codable, Equatable, Sendable {
    public let reviewer: String?
    public let team: String?
    public let at: Date

    public init(reviewer: String, at: Date) {
        self.reviewer = reviewer
        team = nil
        self.at = at
    }

    public init(team: String, at: Date) {
        reviewer = nil
        self.team = team
        self.at = at
    }

    /// Whether this request (or removal) names `other`'s target.
    func isSameTarget(as other: HistoryRequest) -> Bool {
        reviewer == other.reviewer && team == other.team
    }
}

/// A PR in a team repo with what review counts and response times need: when it opened, was last marked ready and
/// was merged or closed, which review requests were made and removed and when, and every submitted review. `repo` is
/// `owner/name`.
public struct HistoryPr: Codable, Equatable, Sendable {
    public let repo: String
    public let number: Int
    public let author: String
    public let createdAt: Date
    public let updatedAt: Date
    public let readyAt: Date?
    public let mergedAt: Date?
    public let closedAt: Date?
    public let requests: [HistoryRequest]
    public let removals: [HistoryRequest]
    public let reviews: [HistoryReview]

    public init(
        repo: String,
        number: Int,
        author: String,
        createdAt: Date,
        updatedAt: Date,
        readyAt: Date? = nil,
        mergedAt: Date? = nil,
        closedAt: Date? = nil,
        requests: [HistoryRequest] = [],
        removals: [HistoryRequest] = [],
        reviews: [HistoryReview] = []
    ) {
        self.repo = repo
        self.number = number
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.readyAt = readyAt
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.requests = requests
        self.removals = removals
        self.reviews = reviews
    }

    public var key: String { "\(repo)#\(number)" }

    /// When the PR became reviewable: its last ready-for-review event, else its creation.
    public var readyTime: Date { readyAt ?? createdAt }

    /// When the PR stopped waiting on anyone: merged or closed, whichever came first; nil while open.
    public var endedAt: Date? { [mergedAt, closedAt].compactMap(\.self).min() }
}

/// The cached review history of the chosen teams' repos: who you are, the teams' members (all together, and per
/// `org/slug` team for expanding team requests), each repo's last complete fetch, and the PRs updated within the
/// retention window. `completedAt` is the last refresh that reached every repo, which decides staleness. A cache
/// written under another `schema` fails to decode, so it is dropped and fetched again in full.
public struct ReviewHistory: Codable, Equatable, Sendable {
    public static let schema = 2
    static let overlap: TimeInterval = 10 * 60

    public var me: String?
    public var members: [String] = []
    public var teamMembers: [String: [String]] = [:]
    public var fetchedAt: [String: Date] = [:]
    public var prs: [HistoryPr] = []
    public var completedAt: Date?

    public init(
        me: String? = nil,
        members: [String] = [],
        teamMembers: [String: [String]] = [:],
        fetchedAt: [String: Date] = [:],
        prs: [HistoryPr] = [],
        completedAt: Date? = nil
    ) {
        self.me = me
        self.members = members
        self.teamMembers = teamMembers
        self.fetchedAt = fetchedAt
        self.prs = prs
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case schema, me, members, teamMembers, fetchedAt, prs, completedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        guard schema == Self.schema else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: c, debugDescription: "review history schema \(schema.map(String.init) ?? "none"), expected \(Self.schema)")
        }
        me = try c.decodeIfPresent(String.self, forKey: .me)
        members = try c.decode([String].self, forKey: .members)
        teamMembers = try c.decode([String: [String]].self, forKey: .teamMembers)
        fetchedAt = try c.decode([String: Date].self, forKey: .fetchedAt)
        prs = try c.decode([HistoryPr].self, forKey: .prs)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schema, forKey: .schema)
        try c.encodeIfPresent(me, forKey: .me)
        try c.encode(members, forKey: .members)
        try c.encode(teamMembers, forKey: .teamMembers)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encode(prs, forKey: .prs)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
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
    var mergedAt: String?
    var closedAt: String?
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

    /// The event as a request or removal of a user or `org/slug` team; nil for other events or reviewers GitHub hid.
    var request: HistoryRequest? {
        guard let at = createdAt.flatMap(isoDate), let reviewer = requestedReviewer else { return nil }
        if let login = reviewer.login { return HistoryRequest(reviewer: login, at: at) }
        guard let slug = reviewer.slug, let org = reviewer.organization?.login else { return nil }
        return HistoryRequest(team: "\(org)/\(slug)", at: at)
    }
}

/// A history page's PR as a `HistoryPr`, or nil when its times don't parse. The ready time is the last ready-for-review
/// event; review requests and their removals keep users and teams. Reviews without an author or submission time
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
        mergedAt: node.mergedAt.flatMap(isoDate),
        closedAt: node.closedAt.flatMap(isoDate),
        requests: events.filter { $0.typename == "ReviewRequestedEvent" }.compactMap(\.request),
        removals: events.filter { $0.typename == "ReviewRequestRemovedEvent" }.compactMap(\.request),
        reviews: node.reviews.nodes.compactMap { review in
            guard let author = review.author, let at = review.submittedAt.flatMap(isoDate) else { return nil }
            return HistoryReview(author: author.login, isBot: isBot(author), state: review.state, submittedAt: at)
        }
    )
}

func isoDate(_ text: String) -> Date? {
    try? Date(text, strategy: .iso8601)
}
