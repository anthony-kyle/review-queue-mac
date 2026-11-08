import Foundation

/// What the last refresh saw, persisted so a restart doesn't re-announce PRs: keys shown in High priority and Needs
/// review, and keys whose review requests include you.
public struct AlertState: Codable, Equatable, Sendable {
    public var high: Set<String> = []
    public var needs: Set<String> = []
    public var requested: Set<String> = []

    public init(high: Set<String> = [], needs: Set<String> = [], requested: Set<String> = []) {
        self.high = high
        self.needs = needs
        self.requested = requested
    }
}

public enum AlertKind: Sendable {
    case high, normal, summary
}

public struct PrAlert: Equatable, Sendable {
    public let kind: AlertKind
    public let id: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let url: String
    public let linearUrl: String?
}

extension PrAlert {
    /// A High priority alert for the Settings "Send test notification" button.
    public static let sample = PrAlert(
        kind: .high,
        id: "test",
        title: "Review Queue test",
        subtitle: "High priority",
        body: "Notifications and the loud alert sound are working.",
        url: "https://github.com/pulls/review-requested",
        linearUrl: nil
    )
}

public struct AlertEvaluation: Equatable, Sendable {
    public let alerts: [PrAlert]
    public let state: AlertState
}

private let summaryThreshold = 3
private let summaryNames = 3
private let summaryUrl = "https://github.com/pulls/review-requested"

/// Notifications owed after a refresh. High priority PRs alert when they arrive and, with repeat reminders on, on every
/// refresh they stay; PRs newly in Needs review and PRs that newly request you alert once, one alert per PR per refresh.
/// More than three normal alerts collapse into one summary. With no `previous` (fresh install) only High alerts fire, so
/// the first refresh records the queue instead of announcing all of it. Only PRs a block actually shows count.
public func evaluateAlerts(previous: AlertState?, prs: [QueuePr], settings: QueueSettings) -> AlertEvaluation {
    let lists = blockLists(prs, settings)
    let high = lists[.high]?.shown ?? []
    let needs = lists[.needs]?.shown ?? []
    let state = AlertState(
        high: Set(high.map(\.key)),
        needs: Set(needs.map(\.key)),
        requested: Set(prs.filter(\.isReviewRequested).map(\.key))
    )

    var alerts: [PrAlert] = []
    if settings.notifyHigh {
        for pr in high {
            let isNew = previous?.high.contains(pr.key) != true
            if isNew || settings.repeatHighReminders {
                alerts.append(alert(pr, kind: .high, subtitle: isNew ? "High priority" : "Still in High priority", settings: settings))
            }
        }
    }
    guard let previous else { return AlertEvaluation(alerts: alerts, state: state) }

    var alerted = Set(alerts.map { $0.id })
    var normal: [PrAlert] = []
    func add(_ pr: QueuePr, subtitle: String) {
        guard alerted.insert(pr.key).inserted else { return }
        normal.append(alert(pr, kind: .normal, subtitle: subtitle, settings: settings))
    }
    if settings.notifyNeeds {
        for pr in needs where !previous.needs.contains(pr.key) { add(pr, subtitle: "Needs review") }
    }
    if settings.notifyReviewRequested {
        for pr in prs where pr.isReviewRequested && !previous.requested.contains(pr.key) { add(pr, subtitle: "Review requested") }
    }

    alerts += summarised(normal, title: "\(normal.count) PRs need your review", subtitle: "Review queue", url: summaryUrl)
    return AlertEvaluation(alerts: alerts, state: state)
}

/// More than three normal alerts collapse into one summary listing the first three titles; fewer pass through.
func summarised(_ normal: [PrAlert], title: String, subtitle: String, url: String) -> [PrAlert] {
    guard normal.count > summaryThreshold else { return normal }
    let names = normal.prefix(summaryNames).map(\.title).joined(separator: "\n")
    let more = normal.count > summaryNames ? "\n+\(normal.count - summaryNames) more" : ""
    return [PrAlert(kind: .summary, id: "summary", title: title, subtitle: subtitle, body: names + more, url: url, linearUrl: nil)]
}

private func alert(_ pr: QueuePr, kind: AlertKind, subtitle: String, settings: QueueSettings) -> PrAlert {
    let details = [pr.repo, pr.storyId, pr.author, reasonOf(pr, settings)].compactMap { $0 }
    return PrAlert(
        kind: kind,
        id: pr.key,
        title: "#\(pr.number) \(pr.title)",
        subtitle: subtitle,
        body: details.joined(separator: " · "),
        url: pr.url,
        linearUrl: pr.linearReviewUrl
    )
}
