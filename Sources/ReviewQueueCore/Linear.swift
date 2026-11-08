import Foundation

public struct ListDiffsArgs: Encodable, Equatable, Sendable {
    let owner: String
    let repo: String
    var orderBy: String?
    var query: String?
    let limit: Int
    var cursor: String?
}

public struct Diff: Decodable, Equatable, Sendable {
    let url: String
    let appUrl: String
}

public struct DiffPage: Decodable, Equatable, Sendable {
    var diffs: [Diff]?
    var hasNextPage: Bool?
    var cursor: String?
}

/// Linear review URLs already looked up, keyed by GitHub PR URL. Hits are kept for good; misses carry when they missed.
public struct LinearCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        var appUrl: String?
        var missedAt: Date?
    }

    public var entries: [String: Entry] = [:]

    public init() {}
}

public struct LinearPrRef: Sendable {
    public let owner: String
    public let repo: String
    public let number: Int
    public let url: String

    public init(_ pr: some TrackedPr) {
        owner = pr.owner
        repo = pr.repo
        number = pr.number
        url = pr.url
    }
}

public struct LinearResult: Equatable, Sendable {
    public let urls: [String: String]
    public let workspace: String?
}

private let repoPages = 5
private let pageSize = 20
private let missRetry: TimeInterval = 6 * 60 * 60

/// The workspace slug in a `linear.app/<ws>/review/<slug>` URL.
func workspaceOf(_ appUrl: String) -> String? {
    guard let range = appUrl.range(of: #"linear\.app/[^/]+/review/"#, options: .regularExpression) else { return nil }
    return appUrl[range].split(separator: "/").dropFirst().first.map(String.init)
}

/// Maps GitHub PR URLs to their Linear review page, which can't be derived from GitHub alone. Linear tracks a PR under
/// statuses beyond `open`, so repos are read without a status filter, newest first, and any PR still unseen is then
/// looked up by its number. Misses are retried after six hours, since Linear may sync a PR late. Page size stays at 20
/// because larger `list_diffs` pages overflow. Returns the cache pruned to `prs`, ready to persist.
public func resolveLinearReviewUrls(
    prs: [LinearPrRef],
    cache initial: LinearCache,
    now: Date,
    listDiffs: @Sendable (ListDiffsArgs) async throws -> DiffPage
) async throws -> (LinearResult, LinearCache) {
    var cache = initial
    func isWanted(_ pr: LinearPrRef) -> Bool {
        guard let entry = cache.entries[pr.url] else { return true }
        guard let missedAt = entry.missedAt, entry.appUrl == nil else { return false }
        return now.timeIntervalSince(missedAt) > missRetry
    }
    func remember(_ page: DiffPage) {
        for diff in page.diffs ?? [] { cache.entries[diff.url] = .init(appUrl: diff.appUrl) }
    }

    let wantedRepos = unique(prs.filter(isWanted).map { Repo(owner: $0.owner, name: $0.repo) })
    for repo in wantedRepos {
        var cursor: String?
        for _ in 0..<repoPages {
            let page = try await listDiffs(ListDiffsArgs(owner: repo.owner, repo: repo.name, orderBy: "updatedAt", limit: pageSize, cursor: cursor))
            remember(page)
            guard page.hasNextPage == true, let next = page.cursor else { break }
            cursor = next
        }
    }

    for pr in prs.filter(isWanted) {
        remember(try await listDiffs(ListDiffsArgs(owner: pr.owner, repo: pr.repo, query: String(pr.number), limit: 10)))
        if cache.entries[pr.url]?.appUrl == nil { cache.entries[pr.url] = .init(missedAt: now) }
    }

    let live = Set(prs.map(\.url))
    cache.entries = cache.entries.filter { live.contains($0.key) }
    let urls = cache.entries.compactMapValues(\.appUrl)
    let workspace = prs.lazy.compactMap { urls[$0.url].flatMap(workspaceOf) }.first
    return (LinearResult(urls: urls, workspace: workspace), cache)
}

/// `prs` with the Review tab of each one's Linear review page from `urls` (keyed by GitHub PR URL), or nil when unknown.
public func withLinearReviewUrls<P: TrackedPr>(_ prs: [P], _ urls: [String: String]) -> [P] {
    prs.map { pr in
        var linked = pr
        linked.linearReviewUrl = urls[pr.url].map(reviewTabURL)
        return linked
    }
}

/// The Review tab of a Linear review page: `list_diffs` gives `linear.app/<ws>/review/<slug>`, which opens on the
/// overview, so `/review` is appended unless already there.
public func reviewTabURL(_ appUrl: String) -> String {
    let trimmed = appUrl.hasSuffix("/") ? String(appUrl.dropLast()) : appUrl
    let segments = trimmed.split(separator: "/")
    let isReviewTab = segments.last == "review" && segments.filter { $0 == "review" }.count >= 2
    return isReviewTab ? trimmed : trimmed + "/review"
}

/// Linear's hosted MCP server spoken over streamable HTTP with an OAuth bearer token. One session is opened lazily and
/// reopened when the server forgets it. A 401 asks `accessToken` for a fresh token and retries once.
public actor LinearMCPClient {
    private static let endpoint = URL(string: "https://mcp.linear.app/mcp")!

    private struct InitializeParams: Encodable, Sendable {
        var protocolVersion = "2025-06-18"
        var capabilities: [String: String] = [:]
        var clientInfo = ["name": "ReviewQueue", "version": "1.0"]
    }

    private struct ToolCall<Arguments: Encodable & Sendable>: Encodable, Sendable {
        let name: String
        let arguments: Arguments
    }

    private struct Empty: Encodable, Sendable {}

    /// Returns the token to send; `rejected` is the token the server just answered 401 to, nil on a first try.
    public typealias AccessToken = @Sendable (_ rejected: String?) async throws -> String

    private let accessToken: AccessToken
    private let session: URLSession
    private var sessionId: String?
    private var isReady = false
    private var nextId = 1
    private var diffTool: String?

    public init(session: URLSession = .shared, accessToken: @escaping AccessToken) {
        self.accessToken = accessToken
        self.session = session
    }

    /// One `list_diffs` page. A reply that is not JSON reads as an empty last page, so the per-PR lookup still covers it.
    public func listDiffs(_ args: ListDiffsArgs) async throws -> DiffPage {
        let text = try await callTool(try await resolveDiffTool(), arguments: args)
        guard text.drop(while: \.isWhitespace).hasPrefix("{") else { return DiffPage() }
        return try JSONDecoder().decode(DiffPage.self, from: Data(text.utf8))
    }

    private func resolveDiffTool() async throws -> String {
        if let diffTool { return diffTool }
        try await ensureReady()
        let id = takeId()
        let (data, response) = try await post(RPCRequest<Empty>(id: id, method: "tools/list", params: Empty()))
        try check(response, data)
        let listed = try mcpResponse(body: data, contentType: response.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = listed.error { throw ReviewQueueError("tools/list: \(error.message)") }
        let names = listed.result?.tools?.map(\.name) ?? []
        guard let name = diffToolName(in: names) else {
            throw ReviewQueueError("Linear MCP offers no diff tool to this sign-in (\(names.count) tools: \(names.prefix(12).joined(separator: ", ")))")
        }
        diffTool = name
        return name
    }

    private func callTool<A: Encodable & Sendable>(_ name: String, arguments: A, isRetry: Bool = false) async throws -> String {
        try await ensureReady()
        let id = takeId()
        let (data, response) = try await post(RPCRequest(id: id, method: "tools/call", params: ToolCall(name: name, arguments: arguments)))
        if response.statusCode == 404 && sessionId != nil && !isRetry {
            isReady = false
            sessionId = nil
            return try await callTool(name, arguments: arguments, isRetry: true)
        }
        try check(response, data)
        return try toolText(try mcpResponse(body: data, contentType: response.value(forHTTPHeaderField: "Content-Type"), id: id), tool: name)
    }

    private func ensureReady() async throws {
        guard !isReady else { return }
        let id = takeId()
        let (data, response) = try await post(RPCRequest(id: id, method: "initialize", params: InitializeParams()))
        try check(response, data)
        if let header = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = header }
        let initialized = try mcpResponse(body: data, contentType: response.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = initialized.error { throw ReviewQueueError("initialize: \(error.message)") }
        let (ackData, ack) = try await post(RPCRequest<Empty>(id: nil, method: "notifications/initialized", params: nil))
        try check(ack, ackData)
        isReady = true
    }

    private func takeId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ReviewQueueError("Linear MCP refused the access token (HTTP \(response.statusCode))")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ReviewQueueError("Linear MCP HTTP \(response.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    private func post<P: Encodable & Sendable>(_ message: RPCRequest<P>) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONEncoder().encode(message)
        let token = try await accessToken(nil)
        let first = try await send(body, token: token)
        guard first.1.statusCode == 401 else { return first }
        return try await send(body, token: try await accessToken(token))
    }

    private func send(_ body: Data, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReviewQueueError("Linear sent no HTTP response") }
        return (data, http)
    }
}
