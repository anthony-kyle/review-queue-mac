import Foundation

enum RPCID: Decodable, Equatable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Int.self) { self = .int(value) } else { self = .string(try c.decode(String.self)) }
    }

    func matches(_ id: Int) -> Bool {
        self == .int(id) || self == .string(String(id))
    }
}

struct RPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    var jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: Params?
}

struct ContentBlock: Decodable, Sendable {
    let type: String
    var text: String?
}

struct ToolInfo: Decodable, Sendable {
    let name: String
}

struct RPCResult: Decodable, Sendable {
    var content: [ContentBlock]?
    var isError: Bool?
    var tools: [ToolInfo]?
}

struct RPCErrorBody: Decodable, Sendable {
    let message: String
}

struct RPCResponse: Decodable, Sendable {
    var id: RPCID?
    var method: String?
    var result: RPCResult?
    var error: RPCErrorBody?
}

/// The `data:` payloads of a `text/event-stream` body, one per event; multi-line data is joined with newlines.
func sseDataPayloads(_ body: String) -> [String] {
    var payloads: [String] = []
    var lines: [String] = []
    let flush = {
        if !lines.isEmpty { payloads.append(lines.joined(separator: "\n")) }
        lines = []
    }
    for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
        if raw.isEmpty {
            flush()
        } else if raw.hasPrefix("data:") {
            let value = raw.dropFirst(5)
            lines.append(String(value.hasPrefix(" ") ? value.dropFirst() : value))
        }
    }
    flush()
    return payloads
}

/// The JSON-RPC response with `id` from a streamable-HTTP MCP reply, which is either a plain JSON body or an SSE stream
/// that may carry server notifications ahead of the response.
func mcpResponse(body: Data, contentType: String?, id: Int) throws -> RPCResponse {
    let payloads: [Data] = (contentType ?? "").contains("text/event-stream")
        ? sseDataPayloads(String(decoding: body, as: UTF8.self)).map { Data($0.utf8) }
        : [body]
    for payload in payloads {
        guard let message = try? JSONDecoder().decode(RPCResponse.self, from: payload) else { continue }
        if message.method == nil, message.id?.matches(id) == true { return message }
    }
    throw ReviewQueueError("no JSON-RPC response with id \(id)")
}

/// The tool that lists Linear diffs: `list_diffs` when offered, else the first name holding both `list` and `diff`.
/// Linear has renamed and gated its tools before, so the name is looked up rather than assumed.
func diffToolName(in names: [String]) -> String? {
    if names.contains("list_diffs") { return "list_diffs" }
    return names.first { $0.localizedCaseInsensitiveContains("diff") && $0.localizedCaseInsensitiveContains("list") }
}

/// The first text block of a `tools/call` result; JSON-RPC errors and `isError` results throw.
func toolText(_ response: RPCResponse, tool: String) throws -> String {
    if let error = response.error { throw ReviewQueueError("\(tool): \(error.message)") }
    guard let result = response.result else { throw ReviewQueueError("\(tool): empty result") }
    let text = result.content?.first { $0.type == "text" }?.text ?? ""
    if result.isError == true { throw ReviewQueueError("\(tool) failed: \(text.prefix(200))") }
    return text
}
