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

    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
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
          headRefOid mergeable reviewDecision
          reviews(last: 50) { nodes { id author { login __typename } state commit { oid } } }
          reviewThreads(first: 100) { nodes { isResolved comments(first: 20) { nodes { \(commentFields) } } } }
          comments(last: 100) { totalCount nodes { \(commentFields) } }
          reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { slug } } } }
          \(checksField)
        }
        """
    private static let commentFields = "id author { login __typename } createdAt bodyText url isMinimized"
    private static let checksField = "commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 50) { nodes { __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } }"

    private var token: String?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Every team the signed-in user belongs to, as `org/team-slug`, for the settings picker.
    public func listMyTeams() async throws -> [String] {
        try await restPages("user/teams", as: TeamJSON.self).map { "\($0.organization.login)/\($0.slug)" }.sorted()
    }

    /// Lists open, human-authored PRs (not yours) in the repos the chosen teams hold at the chosen access, with your review
    /// standing, comment counts and CI state. Two passes: a light list over every repo, then details in batches, which
    /// keeps each GraphQL query under GitHub's node limit. Repos and members are unioned across `teams`.
    public func fetchQueue(teams: [String], access: RepoAccess) async throws -> FetchResult {
        let me = try await viewerLogin()
        var repos: [Repo] = []
        var members: [String] = []
        for team in teams {
            repos += try await teamRepos(team, access: access)
            members += try await teamMembers(team)
        }
        let candidates = try await listCandidates(unique(repos), me: me)
        let prs = try await detailed(candidates, fragment: Self.queueFragment).map { queuePr($0, detail: $1, me: me) }
        let people = Set(members + prs.map(\.author)).filter { $0 != me }.sorted()
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

    private func listCandidates(_ repos: [Repo], me: String) async throws -> [Candidate] {
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
        return found.filter { !isBot($0.node.author) && $0.node.author?.login != me }
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
