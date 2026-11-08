import Foundation
import Network
import os

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect. Requests for other paths (the browser's
/// favicon fetch) get a 404 and the listener keeps waiting; the first `/callback` is validated, answered with a short
/// page, and ends it.
final class LoopbackCallbackServer: Sendable {
    private struct State: Sendable {
        var ready: CheckedContinuation<UInt16, any Error>?
        var waiter: CheckedContinuation<String, any Error>?
        var outcome: Result<String, any Error>?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleId).oauth-callback")
    private let validate: @Sendable (OAuthCallbackParams) throws -> String
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(listener: NWListener, validate: @escaping @Sendable (OAuthCallbackParams) throws -> String) {
        self.listener = listener
        self.validate = validate
    }

    /// Binds 127.0.0.1 on `port`, or on a port the OS picks when nil, and returns once it is listening.
    static func start(
        port: UInt16?,
        validate: @escaping @Sendable (OAuthCallbackParams) throws -> String
    ) async throws -> (LoopbackCallbackServer, UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let server = LoopbackCallbackServer(listener: try NWListener(using: parameters), validate: validate)
        let bound = try await server.listen()
        return (server, bound)
    }

    /// The authorization code from the first valid `/callback`, or the reason it was refused.
    func awaitCallback(timeout: Duration) async throws -> String {
        queue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) { [self] in
            finish(.failure(ReviewQueueError("Linear sign-in timed out")))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome = state.withLock { state -> Result<String, any Error>? in
                    if state.outcome == nil { state.waiter = continuation }
                    return state.outcome
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
    }

    private func listen() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.ready = continuation }
            listener.stateUpdateHandler = { [self] listenerState in
                switch listenerState {
                case .ready:
                    takeReady()?.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    takeReady()?.resume(throwing: error)
                    finish(.failure(error))
                case .cancelled:
                    takeReady()?.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(on: connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func takeReady() -> CheckedContinuation<UInt16, any Error>? {
        state.withLock { state in
            defer { state.ready = nil }
            return state.ready
        }
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            let request = buffered + (data ?? Data())
            let headerEnd = request.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil, error == nil, !isComplete, request.count < 16_384 {
                receive(on: connection, buffered: request)
                return
            }
            respond(to: request, on: connection)
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let requestLine = String(decoding: request, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let params = OAuthCallbackParams(requestTarget: String(parts[1])) else {
            reply(on: connection, status: "404 Not Found", message: "Not found.")
            return
        }
        let outcome = Result { try validate(params) }
        switch outcome {
        case .success:
            reply(on: connection, status: "200 OK", message: "Signed in to Linear. You can close this tab and return to Review Queue.")
        case .failure(let error):
            reply(on: connection, status: "400 Bad Request", message: error.localizedDescription)
        }
        finish(outcome)
    }

    private func reply(on connection: NWConnection, status: String, message: String) {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let body = Data("""
            <!doctype html><html><head><meta charset="utf-8"><title>Review Queue</title></head>\
            <body style="font: 15px -apple-system, sans-serif; margin: 3em;"><p>\(escaped)</p></body></html>
            """.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ outcome: Result<String, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<String, any Error>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: outcome)
        listener.cancel()
    }
}
