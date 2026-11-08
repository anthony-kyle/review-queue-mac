import Foundation

/// What the last My PRs refresh saw, persisted so a restart doesn't re-announce: comment and review ids, `key@head`
/// pairs whose CI was failing, keys that conflicted, and every open PR so one that disappears can be looked up.
public struct MyAlertState: Codable, Equatable, Sendable {
    public var comments: Set<String> = []
    public var reviews: Set<String> = []
    public var failing: Set<String> = []
    public var conflicting: Set<String> = []
    public var open: [String: MyPrRef] = [:]

    public init(
        comments: Set<String> = [],
        reviews: Set<String> = [],
        failing: Set<String> = [],
        conflicting: Set<String> = [],
        open: [String: MyPrRef] = [:]
    ) {
        self.comments = comments
        self.reviews = reviews
        self.failing = failing
        self.conflicting = conflicting
        self.open = open
    }
}

private let summaryUrl = "https://github.com/pulls"

/// PRs open last refresh that are gone from `prs`, to look up as merged or closed before evaluating alerts.
public func vanishedPrs(previous: MyAlertState?, prs: [MyPr]) -> [MyPrRef] {
    guard let previous else { return [] }
    let keys = Set(prs.map(\.key))
    return previous.open.filter { !keys.contains($0.key) }.values.sorted { $0.url < $1.url }
}

/// Notifications owed after a My PRs refresh: new comments (one alert per PR), approvals, changes-requests (loud, sent as
/// `.high`), CI newly failing on the head, a new conflict, and a PR merged or closed by someone else (`closures`, keyed
/// by node id, says how each vanished PR ended). With no `previous` (fresh install) nothing is sent and the state is
/// just recorded. Marked-done PRs feed the state but stay silent until they change. More than three normal alerts
/// collapse into one summary.
public func evaluateMyAlerts(
    previous: MyAlertState?,
    prs: [MyPr],
    closures: [String: PrClosure],
    context: MyPrsContext,
    dismissals: Dismissals = [:]
) -> MyAlertEvaluation {
    let state = MyAlertState(
        comments: Set(prs.flatMap { $0.comments.map(\.id) }),
        reviews: Set(prs.flatMap { $0.reviews.map(\.id) }.filter { !$0.isEmpty }),
        failing: Set(prs.filter { isCiFailing($0.ci) }.map(failingToken)),
        conflicting: Set(prs.filter(\.isConflicting).map(\.key)),
        open: Dictionary(prs.map { ($0.key, $0.ref) }) { first, _ in first }
    )
    guard let previous else { return MyAlertEvaluation(alerts: [], state: state) }

    let settings = context.settings
    var loud: [PrAlert] = []
    var normal: [PrAlert] = []
    for pr in prs where !isDismissed(pr, dismissals) {
        let fresh = newComments(pr, context).filter { !previous.comments.contains($0.id) }
        if settings.notifyComments, let first = fresh.first {
            normal.append(alert(
                pr,
                id: "\(pr.key)#comments",
                subtitle: fresh.count == 1 ? "New comment" : "\(fresh.count) new comments",
                body: "\(first.author): \(first.body)",
                url: first.url.isEmpty ? pr.url : first.url
            ))
        }
        let reviews = pr.reviews.filter {
            !$0.id.isEmpty && !previous.reviews.contains($0.id) && isCounted(author: $0.author, isBot: $0.isBot, context)
        }
        for review in reviews {
            if review.state == "APPROVED", settings.notifyApproved {
                normal.append(alert(pr, id: "\(pr.key)#review-\(review.id)", subtitle: "Approved by \(review.author)"))
            } else if review.state == "CHANGES_REQUESTED", settings.notifyChangesRequested {
                loud.append(alert(pr, kind: .high, id: "\(pr.key)#review-\(review.id)", subtitle: "Changes requested by \(review.author)"))
            }
        }
        if settings.notifyCiFailing, isCiFailing(pr.ci), !previous.failing.contains(failingToken(pr)) {
            normal.append(alert(pr, id: "\(pr.key)#ci", subtitle: "CI failing", body: nameList(pr.failingChecks)))
        }
        if settings.notifyConflict, pr.isConflicting, !previous.conflicting.contains(pr.key) {
            normal.append(alert(pr, id: "\(pr.key)#conflict", subtitle: "Merge conflict"))
        }
    }
    if settings.notifyClosed {
        for ref in vanishedPrs(previous: previous, prs: prs) {
            let subtitle: String
            switch closures[ref.nodeId] {
            case let .merged(by) where by != context.me: subtitle = by.map { "Merged by \($0)" } ?? "Merged"
            case let .closed(by) where by != context.me: subtitle = by.map { "Closed by \($0)" } ?? "Closed"
            default: continue
            }
            normal.append(PrAlert(
                kind: .normal,
                id: "\(ref.owner)/\(ref.repo)#\(ref.number)#closed",
                title: "#\(ref.number) \(ref.title)",
                subtitle: subtitle,
                body: ref.repo,
                url: ref.url,
                linearUrl: nil
            ))
        }
    }
    let summary = summarised(normal, title: "\(normal.count) updates on your PRs", subtitle: "My PRs", url: summaryUrl)
    return MyAlertEvaluation(alerts: loud + summary, state: state)
}

public struct MyAlertEvaluation: Equatable, Sendable {
    public let alerts: [PrAlert]
    public let state: MyAlertState
}

private func failingToken(_ pr: MyPr) -> String {
    "\(pr.key)@\(pr.headRefOid)"
}

private func alert(_ pr: MyPr, kind: AlertKind = .normal, id: String, subtitle: String, body: String? = nil, url: String? = nil) -> PrAlert {
    PrAlert(
        kind: kind,
        id: id,
        title: "#\(pr.number) \(pr.title)",
        subtitle: subtitle,
        body: body ?? [pr.repo, pr.storyId].compactMap { $0 }.joined(separator: " · "),
        url: url ?? pr.url,
        linearUrl: pr.linearReviewUrl
    )
}
