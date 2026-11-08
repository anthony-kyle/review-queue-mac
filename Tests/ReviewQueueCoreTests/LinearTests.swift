import Foundation
import Testing
@testable import ReviewQueueCore

private actor CallLog {
    private(set) var calls: [ListDiffsArgs] = []

    func record(_ args: ListDiffsArgs) {
        calls.append(args)
    }
}

@Suite struct LinearTests {
    @Test func parsesPlainJSONResponse() throws {
        let body = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"diffs\":[]}"}]}}"#
        let response = try mcpResponse(body: Data(body.utf8), contentType: "application/json", id: 3)
        #expect(try toolText(response, tool: "list_diffs") == #"{"diffs":[]}"#)
    }

    @Test func parsesSSEResponseSkippingNotificationsAndJoiningLines() throws {
        let body = """
            event: message\r
            data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\r
            \r
            event: message
            data: {"jsonrpc":"2.0","id":"7",
            data: "result":{"content":[{"type":"image"},{"type":"text","text":"hello"}]}}

            """
        let response = try mcpResponse(body: Data(body.utf8), contentType: "text/event-stream; charset=utf-8", id: 7)
        #expect(try toolText(response, tool: "list_diffs") == "hello")
    }

    @Test func sseWithoutMatchingIdThrows() {
        let body = "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n"
        #expect(throws: ReviewQueueError.self) { try mcpResponse(body: Data(body.utf8), contentType: "text/event-stream", id: 2) }
    }

    @Test func rpcErrorsAndToolErrorsThrow() throws {
        let rpcError = try mcpResponse(body: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad args"}}"#.utf8), contentType: nil, id: 1)
        #expect(throws: ReviewQueueError("list_diffs: bad args")) { try toolText(rpcError, tool: "list_diffs") }
        let toolError = try mcpResponse(
            body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"nope"}]}}"#.utf8),
            contentType: "application/json",
            id: 1
        )
        #expect(throws: ReviewQueueError("list_diffs failed: nope")) { try toolText(toolError, tool: "list_diffs") }
    }

    @Test func ssePayloadsSplitOnBlankLines() {
        #expect(sseDataPayloads("data: a\ndata: b\n\n: comment\ndata:c\n") == ["a\nb", "c"])
    }

    @Test func workspaceComesFromReviewUrl() {
        #expect(workspaceOf("https://linear.app/acme/review/fresh-pr-abc123") == "acme")
        #expect(workspaceOf("https://linear.app/acme/issue/ENG-1") == nil)
    }

    @Test func resolverReadsReposThenFallsBackPerPrAndCachesHitsAndMisses() async throws {
        let prs = [makePr(1), makePr(2)].map(LinearPrRef.init)
        let log = CallLog()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (result, cache) = try await resolveLinearReviewUrls(prs: prs, cache: LinearCache(), now: now) { args in
            await log.record(args)
            if args.query == "1" {
                return DiffPage(diffs: [Diff(url: prs[0].url, appUrl: "https://linear.app/acme/review/one")], hasNextPage: false)
            }
            return DiffPage()
        }
        let calls = await log.calls
        #expect(calls.first == ListDiffsArgs(owner: "acme", repo: "widgets", orderBy: "updatedAt", limit: 20))
        #expect(calls.dropFirst().map(\.query) == ["1", "2"])
        #expect(result == LinearResult(urls: [prs[0].url: "https://linear.app/acme/review/one"], workspace: "acme"))
        #expect(cache.entries[prs[1].url]?.missedAt == now)

        let soon = now.addingTimeInterval(60)
        let quiet = CallLog()
        _ = try await resolveLinearReviewUrls(prs: prs, cache: cache, now: soon) { args in
            await quiet.record(args)
            return DiffPage()
        }
        #expect(await quiet.calls.isEmpty)

        let later = now.addingTimeInterval(6 * 60 * 60 + 1)
        let retry = CallLog()
        let (_, pruned) = try await resolveLinearReviewUrls(prs: [prs[1]], cache: cache, now: later) { args in
            await retry.record(args)
            return DiffPage()
        }
        #expect(await retry.calls.map(\.query) == [nil, "2"])
        #expect(Set(pruned.entries.keys) == [prs[1].url])
    }

    @Test func resolverFollowsCursorUpToFivePages() async throws {
        let log = CallLog()
        _ = try await resolveLinearReviewUrls(prs: [LinearPrRef(makePr(1))], cache: LinearCache(), now: Date()) { args in
            await log.record(args)
            return args.query == nil ? DiffPage(diffs: [], hasNextPage: true, cursor: "c") : DiffPage()
        }
        let calls = await log.calls
        #expect(calls.filter { $0.query == nil }.count == 5)
        #expect(calls[1].cursor == "c")
    }
}

@Test func diffToolIsFoundByNameEvenWhenRenamed() {
    #expect(diffToolName(in: ["get_issue", "list_diffs", "list_pull_request_diffs"]) == "list_diffs")
    #expect(diffToolName(in: ["get_issue", "list_pull_request_diffs"]) == "list_pull_request_diffs")
    #expect(diffToolName(in: ["get_issue", "list_issues"]) == nil)
}

@Test func reviewLinksOpenTheReviewTab() {
    let page = "https://linear.app/acme/review/choredeps-safe-minorpatch-updates-exact-pins-eng-2430-f43c311ef6fd"
    #expect(reviewTabURL(page) == page + "/review")
    #expect(reviewTabURL(page + "/") == page + "/review")
    #expect(reviewTabURL(page + "/review") == page + "/review")
}
