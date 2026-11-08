import CryptoKit
import Foundation

/// An OAuth grant for Linear's MCP server, persisted as JSON in the Keychain. `clientId` rides along because refresh and
/// revocation need the dynamically registered client that issued the grant.
public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var clientId: String

    /// Due for a refresh when it expires within 60 seconds. A grant without an expiry is only refreshed after a 401.
    public func needsRefresh(at now: Date) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) < 60 } ?? false
    }
}

struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    var refreshToken: String?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    /// The grant this response describes. A refresh response may omit `refresh_token`, in which case the previous one
    /// stays valid and is kept.
    func tokens(clientId: String, issuedAt: Date, previousRefreshToken: String? = nil) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken ?? previousRefreshToken,
            expiresAt: expiresIn.map { issuedAt.addingTimeInterval($0) },
            clientId: clientId
        )
    }
}

/// An RFC 7636 S256 code verifier and its challenge.
struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    init(verifier: String = randomURLSafeToken()) {
        self.verifier = verifier
        challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// 32 random bytes as unpadded base64url: 43 characters, enough entropy for a PKCE verifier or an OAuth `state`.
func randomURLSafeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
}

/// The query of the redirect Linear sends back to the loopback listener.
struct OAuthCallbackParams: Equatable, Sendable {
    var code: String?
    var state: String?
    var issuer: String?
    var error: String?
    var errorDescription: String?

    /// Parses an HTTP request target such as `/callback?code=…&state=…` with form decoding (`+` is a space); nil when
    /// the path is not `/callback`.
    init?(requestTarget: String) {
        guard let components = URLComponents(string: "http://127.0.0.1\(requestTarget)"), components.path == "/callback" else { return nil }
        let items = components.percentEncodedQueryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding }
        }
        code = value("code")
        state = value("state")
        issuer = value("iss")
        error = value("error")
        errorDescription = value("error_description")
    }

    /// The authorization code, once `state` matches and `iss`, when present, names Linear's MCP issuer (RFC 9207).
    func authorizationCode(expectedState: String) throws -> String {
        if let error { throw ReviewQueueError("Linear sign-in failed: \(errorDescription ?? error)") }
        guard state == expectedState else { throw ReviewQueueError("Linear sign-in failed: state mismatch") }
        if let issuer, issuer != LinearOAuth.issuer { throw ReviewQueueError("Linear sign-in failed: unexpected issuer \(issuer)") }
        guard let code, !code.isEmpty else { throw ReviewQueueError("Linear sign-in failed: no authorization code") }
        return code
    }
}

/// The client registered with Linear for one loopback redirect URI. Not secret; kept in Application Support.
public struct LinearOAuthClient: Codable, Equatable, Sendable {
    public let clientId: String
    public let redirectURI: String
}

/// A non-2xx answer from Linear's token or registration endpoint. 4xx from the token endpoint means the grant is dead.
struct OAuthHTTPError: LocalizedError, Sendable {
    let status: Int
    let body: String

    var errorDescription: String? { "Linear OAuth HTTP \(status): \(body)" }
}

/// "Sign in with Linear" against Linear's MCP authorization server: RFC 7591 dynamic registration of a public client,
/// authorization code with PKCE through the browser and a loopback redirect, refresh, and revocation.
public struct LinearOAuth: Sendable {
    static let issuer = "https://mcp.linear.app"
    static let resource = "https://mcp.linear.app/mcp"
    static let scope = "read write"
    private static let authorizeEndpoint = URL(string: "https://mcp.linear.app/authorize")!
    private static let tokenEndpoint = URL(string: "https://mcp.linear.app/token")!
    private static let registrationEndpoint = URL(string: "https://mcp.linear.app/register")!
    private static let callbackTimeout: Duration = .seconds(5 * 60)

    private struct Registration: Encodable, Sendable {
        let clientName = "ReviewQueue"
        let redirectURIs: [String]
        let grantTypes = ["authorization_code", "refresh_token"]
        let responseTypes = ["code"]
        let tokenEndpointAuthMethod = "none"
        let scope = LinearOAuth.scope

        enum CodingKeys: String, CodingKey {
            case clientName = "client_name"
            case redirectURIs = "redirect_uris"
            case grantTypes = "grant_types"
            case responseTypes = "response_types"
            case tokenEndpointAuthMethod = "token_endpoint_auth_method"
            case scope
        }
    }

    private struct RegisteredClient: Decodable, Sendable {
        let clientId: String

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
        }
    }

    private let session: URLSession
    private let store: JSONStore

    public init(session: URLSession = .shared, store: JSONStore = JSONStore()) {
        self.session = session
        self.store = store
    }

    static func authorizeURL(clientId: String, redirectURI: String, state: String, challenge: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource),
        ]
        return components.url!
    }

    /// Runs the browser sign-in and returns the new grant. The loopback listener first tries the port of the last
    /// registered redirect URI so that client can be reused; when that port is taken it binds any free port and
    /// registers a client for the new redirect URI, since loopback redirects may be matched exactly, port included.
    public func signIn(open: @Sendable (URL) async -> Void) async throws -> OAuthTokens {
        let pkce = PKCE()
        let state = randomURLSafeToken()
        let validate: @Sendable (OAuthCallbackParams) throws -> String = { try $0.authorizationCode(expectedState: state) }
        let previous = store.load(LinearOAuthClient.self, from: JSONStore.linearOAuthClient)
        let previousPort = previous.flatMap { URLComponents(string: $0.redirectURI)?.port }.flatMap(UInt16.init(exactly:))

        let server: LoopbackCallbackServer
        let port: UInt16
        if let previousPort, let reused = try? await LoopbackCallbackServer.start(port: previousPort, validate: validate) {
            (server, port) = reused
        } else {
            (server, port) = try await LoopbackCallbackServer.start(port: nil, validate: validate)
        }
        defer { server.stop() }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let client: LinearOAuthClient
        if let previous, previous.redirectURI == redirectURI {
            client = previous
        } else {
            client = LinearOAuthClient(clientId: try await register(redirectURI: redirectURI), redirectURI: redirectURI)
            store.save(client, to: JSONStore.linearOAuthClient)
        }

        await open(Self.authorizeURL(clientId: client.clientId, redirectURI: redirectURI, state: state, challenge: pkce.challenge))
        let code = try await server.awaitCallback(timeout: Self.callbackTimeout)
        let response = try await postForm([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", client.clientId),
            ("code_verifier", pkce.verifier),
            ("resource", Self.resource),
        ])
        return response.tokens(clientId: client.clientId, issuedAt: Date())
    }

    /// Exchanges the refresh token for a new grant. Throws `OAuthHTTPError` when the token endpoint refuses.
    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw OAuthHTTPError(status: 400, body: "no refresh token") }
        let response = try await postForm([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", tokens.clientId),
            ("resource", Self.resource),
        ])
        return response.tokens(clientId: tokens.clientId, issuedAt: Date(), previousRefreshToken: refreshToken)
    }

    /// RFC 7009 revocation of the refresh token (or the access token when there is none). Best effort.
    func revoke(_ tokens: OAuthTokens) async {
        let pair = tokens.refreshToken.map { ($0, "refresh_token") } ?? (tokens.accessToken, "access_token")
        _ = try? await send(formRequest([("token", pair.0), ("token_type_hint", pair.1), ("client_id", tokens.clientId)]))
    }

    private func register(redirectURI: String) async throws -> String {
        var request = URLRequest(url: Self.registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Registration(redirectURIs: [redirectURI]))
        return try JSONDecoder().decode(RegisteredClient.self, from: try await send(request)).clientId
    }

    private func postForm(_ fields: [(String, String)]) async throws -> TokenResponse {
        try JSONDecoder().decode(TokenResponse.self, from: try await send(formRequest(fields)))
    }

    private func formRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(fields).utf8)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReviewQueueError("Linear sent no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthHTTPError(status: http.statusCode, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }
}

/// `application/x-www-form-urlencoded`, escaping everything outside RFC 3986's unreserved set so `+` survives.
func formEncoded(_ fields: [(String, String)]) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
    return fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
}

/// Hands `LinearMCPClient` a live access token, refreshing within 60 seconds of expiry or when the server rejected the
/// one it was given. Concurrent callers share one refresh. When the token endpoint refuses the refresh, the grant is
/// deleted and callers are told to sign in again.
public actor LinearTokenProvider {
    /// Where the grant's JSON lives; the app backs this with the Keychain.
    public struct Storage: Sendable {
        let read: @Sendable () -> String?
        let write: @Sendable (String) -> Void
        let delete: @Sendable () -> Void

        public init(read: @escaping @Sendable () -> String?, write: @escaping @Sendable (String) -> Void, delete: @escaping @Sendable () -> Void) {
            self.read = read
            self.write = write
            self.delete = delete
        }
    }

    static let signedOut = ReviewQueueError("sign in again")

    private let oauth: LinearOAuth
    private let storage: Storage
    private let now: @Sendable () -> Date
    private var tokens: OAuthTokens?
    private var refreshing: Task<OAuthTokens, any Error>?

    public init(oauth: LinearOAuth, storage: Storage, now: @escaping @Sendable () -> Date = Date.init) {
        self.oauth = oauth
        self.storage = storage
        self.now = now
        tokens = storage.read().flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: Data($0.utf8)) }
    }

    public var isSignedIn: Bool { tokens != nil }

    /// A token to send. Pass the token the server just answered 401 to as `rejected` to force a refresh, unless another
    /// caller has already replaced it.
    public func accessToken(rejected: String? = nil) async throws -> String {
        guard let current = tokens else { throw Self.signedOut }
        let isRejected = rejected == current.accessToken
        if !isRejected && !current.needsRefresh(at: now()) { return current.accessToken }
        return try await refreshed(from: current).accessToken
    }

    public func replace(with tokens: OAuthTokens) {
        refreshing?.cancel()
        refreshing = nil
        save(tokens)
    }

    /// Forgets the grant at once, then revokes it with Linear best effort.
    public func signOut() async {
        guard let current = tokens else { return }
        refreshing?.cancel()
        refreshing = nil
        tokens = nil
        storage.delete()
        await oauth.revoke(current)
    }

    private func refreshed(from current: OAuthTokens) async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        let task = Task { [oauth] in try await oauth.refresh(current) }
        refreshing = task
        defer { if refreshing == task { refreshing = nil } }
        do {
            let next = try await task.value
            if tokens == current { save(next) }
            return next
        } catch let error as OAuthHTTPError where (400..<500).contains(error.status) {
            if tokens == current {
                tokens = nil
                storage.delete()
            }
            throw Self.signedOut
        }
    }

    private func save(_ next: OAuthTokens) {
        tokens = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        storage.write(String(decoding: data, as: UTF8.self))
    }
}
