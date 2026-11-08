import CryptoKit
import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct LinearOAuthTests {
    private let urlSafe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    @Test func pkceChallengeIsUnpaddedBase64URLOfSHA256() {
        let verifier = "dBjftJeZ4CVP-mJ92K-1SyQsSNlUdoCowsJnGmBwX8V0bmE"
        let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let pkce = PKCE(verifier: verifier)
        #expect(pkce.challenge == expected)
        #expect(pkce.challenge.count == 43)
        #expect(Set(pkce.challenge).isSubset(of: urlSafe))
    }

    @Test func generatedVerifiersAreLongURLSafeAndDistinct() {
        let a = PKCE()
        let b = PKCE()
        #expect(a.verifier != b.verifier)
        #expect((43...128).contains(a.verifier.count))
        #expect(Set(a.verifier).isSubset(of: urlSafe))
        #expect(a.challenge == PKCE(verifier: a.verifier).challenge)
    }

    @Test func authorizeURLCarriesEveryParameter() throws {
        let url = LinearOAuth.authorizeURL(clientId: "cid", redirectURI: "http://127.0.0.1:5123/callback", state: "st", challenge: "ch")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "mcp.linear.app")
        #expect(components.path == "/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == [
            "response_type": "code",
            "client_id": "cid",
            "redirect_uri": "http://127.0.0.1:5123/callback",
            "scope": "read write",
            "state": "st",
            "code_challenge": "ch",
            "code_challenge_method": "S256",
            "resource": "https://mcp.linear.app/mcp",
        ])
    }

    @Test func callbackParsesCodeStateAndIssuer() throws {
        let params = try #require(OAuthCallbackParams(requestTarget: "/callback?code=abc%2B1&state=xyz&iss=https%3A%2F%2Fmcp.linear.app"))
        #expect(params.code == "abc+1")
        #expect(params.state == "xyz")
        #expect(params.issuer == "https://mcp.linear.app")
        #expect(params.error == nil)
        #expect(try params.authorizationCode(expectedState: "xyz") == "abc+1")
        #expect(OAuthCallbackParams(requestTarget: "/favicon.ico") == nil)
    }

    @Test func callbackRefusesBadStateIssuerErrorsAndMissingCode() throws {
        let wrongState = try #require(OAuthCallbackParams(requestTarget: "/callback?code=c&state=other"))
        #expect(throws: ReviewQueueError("Linear sign-in failed: state mismatch")) { try wrongState.authorizationCode(expectedState: "s") }

        let wrongIssuer = try #require(OAuthCallbackParams(requestTarget: "/callback?code=c&state=s&iss=https%3A%2F%2Fevil.example"))
        #expect(throws: ReviewQueueError("Linear sign-in failed: unexpected issuer https://evil.example")) {
            try wrongIssuer.authorizationCode(expectedState: "s")
        }

        let denied = try #require(OAuthCallbackParams(requestTarget: "/callback?error=access_denied&error_description=User+said+no&state=s"))
        #expect(throws: ReviewQueueError("Linear sign-in failed: User said no")) { try denied.authorizationCode(expectedState: "s") }

        let noCode = try #require(OAuthCallbackParams(requestTarget: "/callback?state=s"))
        #expect(throws: ReviewQueueError("Linear sign-in failed: no authorization code")) { try noCode.authorizationCode(expectedState: "s") }

        let noIssuer = try #require(OAuthCallbackParams(requestTarget: "/callback?code=c&state=s"))
        #expect(try noIssuer.authorizationCode(expectedState: "s") == "c")
    }

    @Test func tokenResponseDecodesAndComputesExpiry() throws {
        let json = #"{"access_token":"at","token_type":"Bearer","expires_in":3600,"refresh_token":"rt","scope":"read write"}"#
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
        let issued = Date(timeIntervalSince1970: 1_000)
        #expect(response.tokens(clientId: "cid", issuedAt: issued) == OAuthTokens(
            accessToken: "at",
            refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 4_600),
            clientId: "cid"
        ))
    }

    @Test func refreshResponseWithoutRefreshTokenKeepsThePreviousOne() throws {
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"at2"}"#.utf8))
        let tokens = response.tokens(clientId: "cid", issuedAt: Date(), previousRefreshToken: "rt")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.expiresAt == nil)
    }

    @Test func refreshIsNeededWithinSixtySecondsOfExpiry() {
        let now = Date(timeIntervalSince1970: 10_000)
        func tokens(expiringIn seconds: TimeInterval?) -> OAuthTokens {
            OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: seconds.map { now.addingTimeInterval($0) }, clientId: "c")
        }
        #expect(!tokens(expiringIn: 61).needsRefresh(at: now))
        #expect(tokens(expiringIn: 59).needsRefresh(at: now))
        #expect(tokens(expiringIn: -5).needsRefresh(at: now))
        #expect(!tokens(expiringIn: nil).needsRefresh(at: now))
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(formEncoded([("a b", "x+y/z=&"), ("k", "v-._~")]) == "a%20b=x%2By%2Fz%3D%26&k=v-._~")
    }

    @Test func tokenProviderReturnsStoredTokenAndSignsOutWhenEmpty() async throws {
        let stored = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600), clientId: "c")
        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        let provider = LinearTokenProvider(oauth: LinearOAuth(), storage: .init(read: { json }, write: { _ in }, delete: {}))
        #expect(await provider.isSignedIn)
        #expect(try await provider.accessToken() == "at")
        #expect(try await provider.accessToken(rejected: "stale") == "at")

        let empty = LinearTokenProvider(oauth: LinearOAuth(), storage: .init(read: { nil }, write: { _ in }, delete: {}))
        #expect(await !empty.isSignedIn)
        await #expect(throws: ReviewQueueError("sign in again")) { try await empty.accessToken() }
    }

    @Test func loopbackServerIgnoresOtherPathsThenReturnsTheValidatedCode() async throws {
        let (server, port) = try await LoopbackCallbackServer.start(port: nil) { try $0.authorizationCode(expectedState: "s") }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let (_, favicon) = try await URLSession.shared.data(from: URL(string: "\(base)/favicon.ico")!)
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)
        async let code = server.awaitCallback(timeout: .seconds(10))
        let (body, callback) = try await URLSession.shared.data(from: URL(string: "\(base)/callback?code=abc&state=s")!)
        #expect((callback as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Signed in to Linear"))
        #expect(try await code == "abc")
    }
}
