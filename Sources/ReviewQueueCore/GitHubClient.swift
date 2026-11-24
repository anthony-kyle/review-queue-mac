import Foundation

public struct FetchResult: Sendable {
    public let prs: [QueuePr]
    public let people: [String]
    public let me: String?

    public static let empty = FetchResult(prs: [], people: [], me: nil)
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [Message]?

    struct Message: Decodable {
        let message: String
    }
}

/// A review history refresh: the merged history, and why it stopped early when it did.
public struct HistoryFetchResult: Sendable {
    public let history: ReviewHistory
    public let note: String?
}

private struct RepoHistory: Sendable {
    let prs: [HistoryPr]
    let resetAt: String?
}

private struct UserJSON: Decodable {
    let login: String
}

private struct TeamJSON: Decodable {
    let slug: String
    let organization: UserJSON
}

private struct TeamRepoJSON: Decodable {
    let name: String
    let archived: Bool
    let roleName: String?
    let owner: UserJSON

    enum CodingKeys: String, CodingKey {
        case name, archived, owner
        case roleName = "role_name"
    }
}

private struct RepoPullRequests: Decodable, Sendable {
    let pullRequests: Nodes<ListNode>
}

private struct PullRequestWrapper: Decodable, Sendable {
    let pullRequest: DetailNode?
}

private struct SearchData: Decodable, Sendable {
    let search: SearchConnection

    struct SearchConnection: Decodable, Sendable {
        let pageInfo: PageInfo
        let nodes: [ListNode]
    }
}

private struct ClosureNodes: Decodable, Sendable {
    let nodes: [ClosureNode?]
}

/// GitHub over HTTPS with the gh CLI's token. The token is read once and re-read when GitHub answers 401.
public actor GitHubClient {
    private static let detailBatch = 25
    private static let repoBatch = 40
    private static let api = URL(string: "https://api.github.com/")!
    private static let listFields = "number title url isDraft headRefName createdAt updatedAt author { login __typename }"
    private static let closureBatch = 50
    private static let historyPage = 25
    private static let historyRateFloor = 200
    private static let requestedReviewer = "requestedReviewer { ... on User { login } ... on Team { slug organization { login } } }"
    private static let historyFields = "number createdAt updatedAt mergedAt closedAt author { login __typename } timelineItems(first: 100, itemTypes: [READY_FOR_REVIEW_EVENT, REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT]) { nodes { __typename ... on ReadyForReviewEvent { createdAt } ... on ReviewRequestedEvent { createdAt \(requestedReviewer) } ... on ReviewRequestRemovedEvent { createdAt \(requestedReviewer) } } } reviews(first: 100) { nodes { author { login __typename } state submittedAt } }"
    private static let queueFragment = """
        fragment D on PullRequest {
          headRefOid
          reviews(last: 50) { nodes { author { login __typename } state commit { oid } } }
          reviewThreads(first: 100) { nodes { isResolved comments(first: 10) { nodes { author { login __typename } url } } } }
          comments(last: 100) { totalCount nodes { author { login __typename } url } }
          reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { slug } } } }
          \(checksField)
        }
        """
    private static let myFragment = """
        fragment D on PullRequest {
          headRefOid mergeable mergeStateStatus reviewDecision
          reviews(last: 50) { nodes { id author { login __typename } state commit { oid } } }
          reviewThreads(first: 100) { nodes { isResolved comments(first: 20) { nodes { \(commentFields) } } } }
          comments(last: 100) { totalCount nodes { \(commentFields) } }
          reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { slug } } } }
          \(checksField)
        }
        """
    private static let commentFields = "id author { login __typename } createdAt bodyText url isMinimized"
    private static let checksField = "commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 50) { nodes { __typename ... on CheckRun { name status conclusion checkSuite { app { name } workflowRun { workflow { name } } } } ... on StatusContext { context state creator { login } } } } } } } }"

    private var token: String?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Every team the signed-in user belongs to, as `org/team-slug`, for the settings picker.
    public func listMyTeams() async throws -> [String] {
        try await restPages("user/teams", as: TeamJSON.self).map { "\($0.organization.login)/\($0.slug)" }.sorted()
    }

    /// Lists open PRs (not yours) by humans and by the bots `settings` allows in the repos the chosen teams hold at the chosen access, with your review
    /// standing, comment counts and CI state. Two passes: a light list over every repo, then details in batches, which
    /// keeps each GraphQL query under GitHub's node limit. Repos and members are unioned across `teams`.
    public func fetchQueue(teams: [String], access: RepoAccess, settings: QueueSettings) async throws -> FetchResult {
        let me = try await viewerLogin()
        let (repos, members) = try await teamScope(teams, access: access)
        let candidates = try await listCandidates(repos, me: me, settings: settings)
        let prs = try await detailed(candidates, fragment: Self.queueFragment).map { queuePr($0, detail: $1, me: me) }
        let people = Set(members.values.joined() + prs.map(\.author)).filter { $0 != me }.sorted()
        return FetchResult(prs: prs, people: people, me: me)
    }

    /// Your open PRs across every org, from a paged search, with reviews, comments, threads, CI and mergeability. Search
    /// gives the list; details come in the same batches as the queue's.
    public func fetchMyPrs() async throws -> MyPrsResult {
        let me = try await viewerLogin()
        var candidates: [Candidate] = []
        var cursor: String?
        repeat {
            let after = cursor.map { #", after: "\#($0)""# } ?? ""
            let query = #"query { search(query: "is:open is:pr author:\#(me) archived:false", type: ISSUE, first: 100\#(after)) { pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id \#(Self.listFields) repository { name owner { login } } } } } }"#
            let page = try await graphql(query, as: SearchData.self).search
            candidates += page.nodes.compactMap { node in
                node.repository.map { Candidate(node: node, repo: Repo(owner: $0.owner.login, name: $0.name)) }
            }
            cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while cursor != nil
        let prs = try await detailed(candidates, fragment: Self.myFragment).map { myPr($0, detail: $1, me: me) }
        return MyPrsResult(prs: prs, me: me)
    }

    /// How each PR (by node id) ended up: merged, closed, or still open. PRs GitHub no longer returns are left out.
    public func fetchClosures(nodeIds: [String]) async throws -> [String: PrClosure] {
        var closures: [String: PrClosure] = [:]
        for start in stride(from: 0, to: nodeIds.count, by: Self.closureBatch) {
            let ids = nodeIds[start..<min(start + Self.closureBatch, nodeIds.count)].map { #""\#($0)""# }.joined(separator: ",")
            let query = "query { nodes(ids: [\(ids)]) { ... on PullRequest { id state mergedBy { login } timelineItems(last: 1, itemTypes: [CLOSED_EVENT]) { nodes { ... on ClosedEvent { actor { login } } } } } } }"
            for case let node? in try await graphql(query, as: ClosureNodes.self).nodes {
                closures[node.id] = closureOf(node)
            }
        }
        return closures
    }

    /// Brings `cached` up to date for the chosen teams' repos and members: each repo is paged newest-updated first back
    /// to its last complete fetch (or the retention start), PRs are upserted, and anything outside the teams' repos or
    /// older than the retention start is dropped. Stops early, keeping what it has and saying why in `note`, when a repo
    /// fails or GitHub's GraphQL budget runs low. `progress` hears repos done out of the total after each one.
    public func fetchReviewHistory(
        teams: [String],
        access: RepoAccess,
        cached: ReviewHistory,
        now: Date,
        calendar: Calendar,
        progress: @Sendable (_ done: Int, _ total: Int) async -> Void
    ) async throws -> HistoryFetchResult {
        let me = try await viewerLogin()
        let (repos, members) = try await teamScope(teams, access: access)
        let start = historyStart(today: now, calendar: calendar)
        let names = repos.map(\.fullName)
        var history = cached.pruned(repos: Set(names), start: start)
        history.me = me
        history.teamMembers = members.mapValues { $0.filter { !$0.hasSuffix("[bot]") }.sorted() }
        history.members = Set(history.teamMembers.values.joined()).sorted()
        await progress(0, repos.count)
        for (done, repo) in repos.enumerated() {
            let fetched: RepoHistory
            do {
                fetched = try await repoHistory(repo, since: history.fetchSince(repo.fullName, start: start))
            } catch {
                return HistoryFetchResult(history: history.pruned(repos: Set(names), start: start), note: error.localizedDescription)
            }
            history = history.merged(fetched.prs, repo: repo.fullName, isComplete: fetched.resetAt == nil, at: now)
            if let resetAt = fetched.resetAt {
                let reset = isoDate(resetAt).map { " after \(clockTime($0))" } ?? " later"
                let note = "GitHub's API limit is nearly used up, so \(done) of \(repos.count) repos are up to date. Refresh\(reset) for the rest."
                return HistoryFetchResult(history: history.pruned(repos: Set(names), start: start), note: note)
            }
            await progress(done + 1, repos.count)
        }
        history.completedAt = now
        return HistoryFetchResult(history: history.pruned(repos: Set(names), start: start), note: nil)
    }

    /// One repo's PRs updated since `since`, newest first, `historyPage` at a time. `resetAt` is set when GitHub's
    /// remaining GraphQL budget dropped below `historyRateFloor`, which stops paging early.
    private func repoHistory(_ repo: Repo, since: Date) async throws -> RepoHistory {
        var prs: [HistoryPr] = []
        var cursor: String?
        repeat {
            let after = cursor.map { #", after: "\#($0)""# } ?? ""
            let query = #"query { rateLimit { remaining resetAt } repository(owner: "\#(repo.owner)", name: "\#(repo.name)") { pullRequests(states: [OPEN, MERGED, CLOSED], first: \#(Self.historyPage), orderBy: { field: UPDATED_AT, direction: DESC }\#(after)) { pageInfo { hasNextPage endCursor } nodes { \#(Self.historyFields) } } } }"#
            let page = try await graphql(query, as: HistoryPageData.self)
            guard let connection = page.repository?.pullRequests else { break }
            prs += connection.nodes.compactMap { historyPr($0, repo: repo.fullName) }
            if let limit = page.rateLimit, limit.remaining < Self.historyRateFloor {
                return RepoHistory(prs: prs, resetAt: limit.resetAt)
            }
            let isPastSince = prs.last.map { $0.updatedAt < since } ?? true
            cursor = connection.pageInfo.hasNextPage && !isPastSince ? connection.pageInfo.endCursor : nil
        } while cursor != nil
        return RepoHistory(prs: prs, resetAt: nil)
    }

    /// The chosen teams' repos (held at `access`, unarchived, unioned across `teams`) and each team's members, keyed by
    /// `org/slug`.
    private func teamScope(_ teams: [String], access: RepoAccess) async throws -> (repos: [Repo], members: [String: [String]]) {
        var repos: [Repo] = []
        var members: [String: [String]] = [:]
        for team in teams {
            repos += try await teamRepos(team, access: access)
            members[team] = try await teamMembers(team)
        }
        return (unique(repos), members)
    }

    private func viewerLogin() async throws -> String {
        try decode(UserJSON.self, from: try await perform(URLRequest(url: Self.api.appending(path: "user"))).0).login
    }

    /// Candidates paired with their details, fetched `detailBatch` at a time to stay under GitHub's node limit. PRs that
    /// came back without details are dropped.
    private func detailed(_ candidates: [Candidate], fragment: String) async throws -> [(Candidate, DetailNode)] {
        var pairs: [(Candidate, DetailNode)] = []
        for start in stride(from: 0, to: candidates.count, by: Self.detailBatch) {
            let batch = Array(candidates[start..<min(start + Self.detailBatch, candidates.count)])
            let details = try await fetchDetails(batch, fragment: fragment)
            for (candidate, detail) in zip(batch, details) {
                guard let detail else { continue }
                pairs.append((candidate, detail))
            }
        }
        return pairs
    }

    private func teamRepos(_ team: String, access: RepoAccess) async throws -> [Repo] {
        let (org, slug) = splitTeam(team)
        return try await restPages("orgs/\(org)/teams/\(slug)/repos", as: TeamRepoJSON.self)
            .filter { !$0.archived && access.roles.contains($0.roleName ?? "") }
            .map { Repo(owner: $0.owner.login, name: $0.name) }
    }

    private func teamMembers(_ team: String) async throws -> [String] {
        let (org, slug) = splitTeam(team)
        return try await restPages("orgs/\(org)/teams/\(slug)/members", as: UserJSON.self).map(\.login)
    }

    private func splitTeam(_ team: String) -> (String, String) {
        let parts = team.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    private func listCandidates(_ repos: [Repo], me: String, settings: QueueSettings) async throws -> [Candidate] {
        var found: [Candidate] = []
        for start in stride(from: 0, to: repos.count, by: Self.repoBatch) {
            let batch = Array(repos[start..<min(start + Self.repoBatch, repos.count)])
            let aliases = batch.enumerated().map { i, repo in
                "repo\(i): repository(owner: \"\(repo.owner)\", name: \"\(repo.name)\") { pullRequests(states: OPEN, first: 100, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes { \(Self.listFields) } } }"
            }
            let data = try await graphql("query { \(aliases.joined(separator: " ")) }", as: [String: RepoPullRequests?].self)
            for (i, repo) in batch.enumerated() {
                for node in data["repo\(i)"]??.pullRequests.nodes ?? [] {
                    found.append(Candidate(node: node, repo: repo))
                }
            }
        }
        return found.filter { isQueueAuthor($0.node.author, me: me, settings) }
    }

    private func fetchDetails(_ batch: [Candidate], fragment: String) async throws -> [DetailNode?] {
        let aliases = batch.enumerated().map { i, pr in
            "pr\(i): repository(owner: \"\(pr.repo.owner)\", name: \"\(pr.repo.name)\") { pullRequest(number: \(pr.node.number)) { ...D } }"
        }
        let query = "query { \(aliases.joined(separator: " ")) } \(fragment)"
        let data = try await graphql(query, as: [String: PullRequestWrapper?].self)
        return batch.indices.map { data["pr\($0)"]??.pullRequest }
    }

    private func graphql<T: Decodable>(_ query: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: Self.api.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["query": query])
        let parsed = try decode(GraphQLResponse<T>.self, from: try await perform(request).0)
        if let errors = parsed.errors, !errors.isEmpty { throw ReviewQueueError(errors.map(\.message).joined(separator: "; ")) }
        guard let data = parsed.data else { throw ReviewQueueError("GitHub returned no data") }
        return data
    }

    private func restPages<T: Decodable>(_ path: String, as type: T.Type) async throws -> [T] {
        var items: [T] = []
        var url: URL? = Self.api.appending(path: path).appending(queryItems: [URLQueryItem(name: "per_page", value: "100")])
        while let next = url {
            let (data, response) = try await perform(URLRequest(url: next))
            items += try decode([T].self, from: data)
            url = nextLink(response.value(forHTTPHeaderField: "Link"))
        }
        return items
    }

    private func perform(_ request: URLRequest, isRetry: Bool = false) async throws -> (Data, HTTPURLResponse) {
        if token == nil || isRetry { token = try await GhCLI.authToken() }
        var authorized = request
        authorized.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        authorized.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        authorized.setValue("ReviewQueue", forHTTPHeaderField: "User-Agent")
        authorized.timeoutInterval = 90
        let (data, response) = try await session.data(for: authorized)
        guard let http = response as? HTTPURLResponse else { throw ReviewQueueError("GitHub sent no HTTP response") }
        if http.statusCode == 401 && !isRetry { return try await perform(request, isRetry: true) }
        guard (200..<300).contains(http.statusCode) else {
            throw ReviewQueueError("GitHub \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
