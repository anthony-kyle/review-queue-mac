import Foundation

/// The one thing a collapsed row says about a PR, coloured by how urgent it is.
public struct PrSignal: Equatable, Sendable {
    public let text: String
    public let tone: Tone

    public init(_ text: String, _ tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

/// A review-queue PR's most urgent signal: failing CI, then updated after your changes, open threads, a review request,
/// then comments. Nil when none applies.
public func queueSignal(_ pr: QueuePr) -> PrSignal? {
    if isCiFailing(pr.ci) { return PrSignal("CI failing", .error) }
    if pr.myReview == .changesAddressed { return PrSignal("Updated", .warning) }
    if pr.unresolvedThreads > 0 { return PrSignal(counted(pr.unresolvedThreads, "thread"), .warning) }
    if pr.isReviewRequested { return PrSignal("Requested", .info) }
    if pr.commentCount > 0 { return PrSignal(counted(pr.commentCount, "comment"), .info) }
    return nil
}

/// One of your PRs' most urgent signal: a conflict, failing CI, changes requested on the current head, new comments,
/// open threads, then approved. Nil when none applies.
public func mySignal(_ pr: MyPr, _ context: MyPrsContext) -> PrSignal? {
    if pr.isConflicting { return PrSignal("Conflict", .error) }
    if isCiFailing(pr.ci) { return PrSignal("CI failing", .error) }
    if !pr.changesRequestedOnHead.isEmpty { return PrSignal("Changes requested", .error) }
    let fresh = newComments(pr, context).count
    if fresh > 0 { return PrSignal("\(fresh) new", .warning) }
    if pr.unresolvedThreads > 0 { return PrSignal(counted(pr.unresolvedThreads, "thread"), .warning) }
    if pr.isApproved { return PrSignal("Approved", .success) }
    return nil
}

private func counted(_ count: Int, _ noun: String) -> String {
    count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
}

/// Which PR rows are open: each block's default, flipped for every PR toggled since launch, so a row open by default
/// can still be closed. Keys are `TrackedPr.key`.
public struct RowExpansion: Equatable, Sendable {
    private var toggled: Set<String> = []

    public init() {}

    public func isExpanded(_ key: String, byDefault: Bool) -> Bool {
        toggled.contains(key) != byDefault
    }

    public mutating func toggle(_ key: String) {
        toggled.formSymmetricDifference([key])
    }
}
