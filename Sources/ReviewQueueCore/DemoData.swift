import Foundation

/// Made-up queue, My PRs and settings for screenshot mode, so README images never show real people, repos or stories.
/// Times are offsets from `now`, so rows read the same ages whenever the screenshots are taken.
public struct DemoData: Sendable {
    public static let me = "you"
    public static let owner = "acme"
    public static let linearWorkspace = "acme"

    public let settings: QueueSettings
    public let prs: [QueuePr]
    public let myPrs: [MyPr]
    public let people: [String]
    public let teams: [String]
    public let fetchedAt: Date
    public let reviewHistory: ReviewHistory

    /// High priority holds a daily-group PR with others' approval and changes-request and one updated after your
    /// changes, which links the diff since your review and fails only a muted Vercel check; Needs review shows three PRs and hides two approved by others and one with changes requested by others.
    /// My PRs has two that need you, one ready to merge (behind main, which an approval outranks), one with reviewers,
    /// one behind main and a draft, plus one in an excluded repo; the bot's comment is from an ignored commenter, so CI
    /// alone puts its PR in Needs you. One ready PR keeps the menu within its scroll height. Review history covers a year
/// for you and seven teammates, so the statistics window fills its heatmap, metrics and leaderboard.
    public init(now: Date) {
        let at = DemoClock(now: now)
        var settings = QueueSettings()
        settings.teams = ["acme/web-team", "acme/platform"]
        settings.highUsers = ["alex-morgan"]
        settings.linearWorkspace = Self.linearWorkspace
        settings.myPrs.excludedRepos = ["acme/acme-db-migrations"]
        settings.myPrs.ignoredCommenters = ["datadog-official"]
        settings.ignoredCiSources = ["vercel"]
        settings.allowedBotAuthors = ["release-bot"]
        self.settings = settings
        people = ["alex-morgan", "jdoe", "priya-n", "sam-rivera"]
        teams = settings.teams + ["acme/mobile"]
        fetchedAt = at.date(minutesAgo: 2)
        reviewHistory = demoReviewHistory(now: now)
        prs = [
            queuePr(
                812, "acme-web", "feat(web): add CSV export to the invoice list", author: "alex-morgan", story: 1042,
                approvedBy: ["sam-rivera"], changesRequestedBy: ["priya-n"], comments: 6, threads: (2, 5),
                neutral: ["Cursor Bugbot"], created: at.days(2), updated: at.minutes(25)
            ),
            queuePr(
                412, "acme-finance-lib", "fix(finance): round tax totals per line, not per invoice", author: "jdoe", story: 1043,
                myReview: .changesAddressed, sinceMyReview: true, comments: 3, threads: (0, 2),
                ci: "FAILURE", failing: checks("Vercel – acme-finance-lib", source: "vercel"), created: at.hours(20),
                updated: at.hours(1)
            ),
            queuePr(
                815, "acme-web", "feat(web): remember the last-used date range filter", author: "sam-rivera", story: 1045,
                isReviewRequested: true, created: at.hours(5), updated: at.hours(5)
            ),
            queuePr(
                88, "acme-db-migrations", "chore(db): add index on invoices.customer_id", author: "priya-n", story: 1046,
                comments: 2, created: at.hours(9), updated: at.hours(3)
            ),
            queuePr(
                305, "acme-tools", "build(tools): cache pnpm store in CI", author: "jdoe", story: 1047,
                ci: "FAILURE", failing: checks("lint", "test (unit)"), created: at.days(1), updated: at.hours(2)
            ),
            queuePr(
                803, "acme-web", "refactor(web): move table pagination into a hook", author: "sam-rivera", story: 1048,
                approvedBy: ["jdoe"], created: at.days(3), updated: at.days(1)
            ),
            queuePr(
                91, "acme-db-migrations", "feat(db): backfill invoice currency codes", author: "priya-n", story: 1049,
                approvedBy: ["alex-morgan"], created: at.days(4), updated: at.days(2)
            ),
            queuePr(
                309, "acme-tools", "feat(tools): add a release notes generator", author: "jdoe", story: 1050,
                changesRequestedBy: ["sam-rivera"], created: at.days(2), updated: at.hours(20)
            ),
            queuePr(
                418, "acme-finance-lib", "feat(finance): support credit notes in ledger export", author: "sam-rivera", story: 1051,
                myReview: .changesPending, comments: 4, threads: (1, 3), created: at.days(6), updated: at.days(1)
            ),
            queuePr(
                798, "acme-web", "fix(web): keep focus in the invoice search box", author: "priya-n", story: 1052,
                myReview: .approved, created: at.days(5), updated: at.days(3)
            ),
        ]
        myPrs = [
            myPr(
                820, "acme-web", "feat(web): show overdue badges on the invoice list", story: 1053,
                reviews: [PrReview(id: "r1", author: "priya-n", isBot: false, state: "CHANGES_REQUESTED", commitOid: "head")],
                comments: [
                    PrComment(
                        id: "c1", author: "priya-n", isBot: false, createdAt: at.hours(3),
                        body: "Can the badge reuse the existing status pill so the colours stay in one place?",
                        url: "https://github.com/acme/acme-web/pull/820#discussion_r1"
                    ),
                    PrComment(
                        id: "c2", author: "cursor", isBot: true, createdAt: at.hours(4),
                        body: "Bug: overdue is computed in local time, so invoices due today flip to overdue early for users east of UTC.",
                        url: "https://github.com/acme/acme-web/pull/820#discussion_r2"
                    ),
                ],
                threads: (2, 3), created: at.days(1), updated: at.hours(3)
            ),
            myPr(
                431, "acme-finance-lib", "fix(finance): make the currency backfill idempotent", story: 1054,
                comments: [
                    PrComment(
                        id: "c3", author: "datadog-official", isBot: true, createdAt: at.hours(6),
                        body: "Test optimization: 2 new flaky tests detected in this branch.",
                        url: "https://github.com/acme/acme-finance-lib/pull/431#issuecomment-3"
                    ),
                ],
                ci: "FAILURE", failing: checks("test (postgres 16)"), created: at.hours(20), updated: at.hours(6)
            ),
            myPr(
                102, "acme-db-migrations", "chore(db): drop the legacy invoice_totals view", story: 1059,
                created: at.days(1), updated: at.days(1)
            ),
            myPr(
                316, "acme-tools", "feat(tools): lint commit messages in pre-push", story: 1055,
                reviews: [PrReview(id: "r2", author: "jdoe", isBot: false, state: "APPROVED", commitOid: "head")],
                decision: "APPROVED", isBehind: true, created: at.days(2), updated: at.hours(8)
            ),
            myPr(
                824, "acme-web", "feat(web): add keyboard shortcuts to the invoice editor", story: 1057,
                requested: ["alex-morgan", "sam-rivera"], created: at.hours(7), updated: at.hours(7)
            ),
            myPr(
                819, "acme-web", "refactor(web): move invoice totals into a shared hook", story: 1060,
                isBehind: true, requested: ["priya-n"], created: at.days(4), updated: at.days(2)
            ),
            myPr(
                320, "acme-tools", "chore(tools): try the new bundler", story: 1058,
                isDraft: true, created: at.days(9), updated: at.days(4)
            ),
        ]
    }
}

/// A demo reviewer: how often they pick up a teammate's PR and their typical hours to first review.
private struct DemoReviewer {
    let login: String
    let pickUp: Double
    let hours: Double
}

private let demoReviewers = [
    DemoReviewer(login: DemoData.me, pickUp: 0.36, hours: 3),
    DemoReviewer(login: "alex-morgan", pickUp: 0.26, hours: 5),
    DemoReviewer(login: "jdoe", pickUp: 0.42, hours: 2),
    DemoReviewer(login: "priya-n", pickUp: 0.22, hours: 9),
    DemoReviewer(login: "sam-rivera", pickUp: 0.25, hours: 6),
    DemoReviewer(login: "kim-lee", pickUp: 0.14, hours: 14),
    DemoReviewer(login: "omar-haddad", pickUp: 0.11, hours: 22),
    DemoReviewer(login: "lena-fischer", pickUp: 0.2, hours: 4),
]

/// A year of made-up review history for the statistics window: a few PRs each weekday (rarely one at a weekend) in the
/// demo repos, each picked up by teammates at their own rate and speed, mostly approving, sometimes requesting changes
/// and approving the next day. A fixed seed keeps it the same on every run; times are offsets from `now`, and anything
/// that would land after `now` is left out.
private func demoReviewHistory(now: Date) -> ReviewHistory {
    var random = SplitMix(seed: 2026)
    var numbers: [String: Int] = [:]
    var prs: [HistoryPr] = []
    let today = Calendar.current.startOfDay(for: now)
    let hour: TimeInterval = 3600
    for daysAgo in stride(from: 370, through: 0, by: -1) {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        let count = Calendar.current.isDateInWeekend(day) ? (random.chance(0.15) ? 1 : 0) : 1 + random.below(4)
        for _ in 0..<count {
            let repo = ["acme-web", "acme-finance-lib", "acme-tools", "acme-db-migrations"][random.below(4)]
            let number = (numbers[repo] ?? 100) + 1
            numbers[repo] = number
            let author = demoReviewers[random.below(demoReviewers.count)].login
            let created = day.addingTimeInterval((9 + random.unit() * 8) * hour)
            let ready = random.chance(0.2) ? created.addingTimeInterval((1 + random.unit() * 20) * hour) : nil
            var requests: [HistoryRequest] = []
            var reviews: [HistoryReview] = []
            for reviewer in demoReviewers where reviewer.login != author && random.chance(reviewer.pickUp) {
                let asked = max(ready ?? created, random.chance(0.8) ? created : created.addingTimeInterval(hour))
                requests.append(HistoryRequest(reviewer: reviewer.login, at: asked))
                let first = asked.addingTimeInterval(reviewer.hours * (0.3 + random.unit() * 1.4) * hour)
                let roll = random.unit()
                let state = roll < 0.62 ? "APPROVED" : roll < 0.82 ? "CHANGES_REQUESTED" : "COMMENTED"
                reviews.append(HistoryReview(author: reviewer.login, state: state, submittedAt: first))
                if state == "CHANGES_REQUESTED" {
                    reviews.append(HistoryReview(author: reviewer.login, state: "APPROVED", submittedAt: first.addingTimeInterval((20 + random.unit() * 10) * hour)))
                }
            }
            reviews = reviews.filter { $0.submittedAt <= now }
            guard created <= now else { continue }
            prs.append(HistoryPr(
                repo: "\(DemoData.owner)/\(repo)",
                number: number,
                author: author,
                createdAt: created,
                updatedAt: reviews.map(\.submittedAt).max() ?? created,
                readyAt: ready.flatMap { $0 <= now ? $0 : nil },
                requests: requests.filter { $0.at <= now },
                reviews: reviews
            ))
        }
    }
    return ReviewHistory(
        me: DemoData.me,
        members: demoReviewers.map(\.login).filter { $0 != DemoData.me },
        prs: prs,
        completedAt: now.addingTimeInterval(-120)
    )
}

/// SplitMix64, a tiny seeded generator, so demo history is identical on every run.
private struct SplitMix {
    var seed: UInt64

    mutating func next() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}

/// Failing checks reported by `source`, or each by its own name when none is given.
private func checks(_ names: String..., source: String? = nil) -> [FailedCheck] {
    names.map { FailedCheck(name: $0, source: source ?? $0) }
}

/// ISO times a fixed distance before `now`.
private struct DemoClock {
    let now: Date

    func date(minutesAgo count: Int) -> Date { now.addingTimeInterval(-Double(count) * 60) }
    func minutes(_ count: Int) -> String { date(minutesAgo: count).formatted(.iso8601) }
    func hours(_ count: Int) -> String { minutes(count * 60) }
    func days(_ count: Int) -> String { hours(count * 24) }
}

private func queuePr(
    _ number: Int,
    _ repo: String,
    _ title: String,
    author: String,
    story: Int,
    myReview: MyReview = .none,
    sinceMyReview: Bool = false,
    isReviewRequested: Bool = false,
    approvedBy: [String] = [],
    changesRequestedBy: [String] = [],
    comments: Int = 0,
    threads: (unresolved: Int, total: Int) = (0, 0),
    ci: String = "SUCCESS",
    failing: [FailedCheck] = [],
    neutral: [String] = [],
    created: String,
    updated: String
) -> QueuePr {
    let url = "https://github.com/\(DemoData.owner)/\(repo)/pull/\(number)"
    return QueuePr(
        key: "\(DemoData.owner)/\(repo)#\(number)",
        owner: DemoData.owner,
        repo: repo,
        number: number,
        title: title,
        url: url,
        author: author,
        isDraft: false,
        storyId: "ACME-\(story)",
        linearReviewUrl: "https://linear.app/\(DemoData.linearWorkspace)/review/acme-\(story)",
        myReview: myReview,
        isReviewRequested: isReviewRequested,
        approvedByOthers: approvedBy,
        changesRequestedByOthers: changesRequestedBy,
        commentCount: comments,
        unresolvedThreads: threads.unresolved,
        totalThreads: threads.total,
        commenters: [],
        ci: ci,
        failingChecks: failing,
        neutralChecks: neutral,
        pendingChecks: [],
        createdAt: created,
        updatedAt: updated,
        latestCommentUrl: comments > 0 ? "\(url)#issuecomment-1" : nil,
        firstUnresolvedThreadUrl: threads.unresolved > 0 ? "\(url)#discussion_r1" : nil,
        sinceMyReviewUrl: sinceMyReview ? "\(url)/files/3f9c2a1..8b7e4d0" : nil
    )
}

private func myPr(
    _ number: Int,
    _ repo: String,
    _ title: String,
    story: Int,
    isDraft: Bool = false,
    reviews: [PrReview] = [],
    decision: String? = nil,
    isBehind: Bool = false,
    comments: [PrComment] = [],
    requested: [String] = [],
    threads: (unresolved: Int, total: Int) = (0, 0),
    ci: String = "SUCCESS",
    failing: [FailedCheck] = [],
    created: String,
    updated: String
) -> MyPr {
    let url = "https://github.com/\(DemoData.owner)/\(repo)/pull/\(number)"
    return MyPr(
        key: "\(DemoData.owner)/\(repo)#\(number)",
        nodeId: "PR_demo_\(number)",
        owner: DemoData.owner,
        repo: repo,
        number: number,
        title: title,
        url: url,
        isDraft: isDraft,
        storyId: "ACME-\(story)",
        linearReviewUrl: "https://linear.app/\(DemoData.linearWorkspace)/review/acme-\(story)",
        headRefOid: "head",
        reviewDecision: decision,
        mergeable: "MERGEABLE",
        mergeStateStatus: isBehind ? "BEHIND" : "CLEAN",
        reviews: reviews,
        comments: comments,
        requestedReviewers: requested,
        commentCount: comments.count,
        unresolvedThreads: threads.unresolved,
        totalThreads: threads.total,
        ci: ci,
        failingChecks: failing,
        neutralChecks: [],
        pendingChecks: [],
        createdAt: created,
        updatedAt: updated,
        latestCommentUrl: comments.last?.url,
        firstUnresolvedThreadUrl: threads.unresolved > 0 ? "\(url)#discussion_r1" : nil
    )
}
