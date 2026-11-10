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

    /// High priority holds a daily-group PR with others' approval and changes-request and one updated after your
    /// changes, which links the diff since your review; Needs review shows three PRs and hides two approved by others and one with changes requested by others.
    /// My PRs has two that need you, two ready to merge, one with reviewers and a draft, plus one in an excluded repo; the
/// bot's comment is from an ignored commenter, so CI alone puts its PR in Needs you.
    public init(now: Date) {
        let at = DemoClock(now: now)
        var settings = QueueSettings()
        settings.teams = ["acme/web-team", "acme/platform"]
        settings.highUsers = ["alex-morgan"]
        settings.linearWorkspace = Self.linearWorkspace
        settings.myPrs.excludedRepos = ["acme/acme-db-migrations"]
        settings.myPrs.ignoredCommenters = ["datadog-official"]
        self.settings = settings
        people = ["alex-morgan", "jdoe", "priya-n", "sam-rivera"]
        teams = settings.teams + ["acme/mobile"]
        fetchedAt = at.date(minutesAgo: 2)
        prs = [
            queuePr(
                812, "acme-web", "feat(web): add CSV export to the invoice list", author: "alex-morgan", story: 1042,
                approvedBy: ["sam-rivera"], changesRequestedBy: ["priya-n"], comments: 6, threads: (2, 5),
                neutral: ["Cursor Bugbot"], created: at.days(2), updated: at.minutes(25)
            ),
            queuePr(
                412, "acme-finance-lib", "fix(finance): round tax totals per line, not per invoice", author: "jdoe", story: 1043,
                myReview: .changesAddressed, sinceMyReview: true, comments: 3, threads: (0, 2), created: at.hours(20),
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
                ci: "FAILURE", failing: ["lint", "test (unit)"], created: at.days(1), updated: at.hours(2)
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
                ci: "FAILURE", failing: ["test (postgres 16)"], created: at.hours(20), updated: at.hours(6)
            ),
            myPr(
                102, "acme-db-migrations", "chore(db): drop the legacy invoice_totals view", story: 1059,
                created: at.days(1), updated: at.days(1)
            ),
            myPr(
                316, "acme-tools", "feat(tools): lint commit messages in pre-push", story: 1055,
                reviews: [PrReview(id: "r2", author: "jdoe", isBot: false, state: "APPROVED", commitOid: "head")],
                decision: "APPROVED", created: at.days(2), updated: at.hours(8)
            ),
            myPr(
                425, "acme-finance-lib", "perf(finance): memoise exchange rate lookups", story: 1056,
                reviews: [
                    PrReview(id: "r3", author: "alex-morgan", isBot: false, state: "APPROVED", commitOid: "head"),
                    PrReview(id: "r4", author: "sam-rivera", isBot: false, state: "APPROVED", commitOid: "head"),
                ],
                decision: "APPROVED", created: at.days(3), updated: at.days(1)
            ),
            myPr(
                824, "acme-web", "feat(web): add keyboard shortcuts to the invoice editor", story: 1057,
                requested: ["alex-morgan", "sam-rivera"], created: at.hours(7), updated: at.hours(7)
            ),
            myPr(
                320, "acme-tools", "chore(tools): try the new bundler", story: 1058,
                isDraft: true, created: at.days(9), updated: at.days(4)
            ),
        ]
    }
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
    failing: [String] = [],
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
    comments: [PrComment] = [],
    requested: [String] = [],
    threads: (unresolved: Int, total: Int) = (0, 0),
    ci: String = "SUCCESS",
    failing: [String] = [],
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
        reviews: reviews,
        comments: comments,
        requestedReviewers: requested,
        commentCount: comments.count,
        unresolvedThreads: threads.unresolved,
        totalThreads: threads.total,
        ci: ci,
        failingChecks: failing,
        neutralChecks: [],
        createdAt: created,
        updatedAt: updated,
        latestCommentUrl: comments.last?.url,
        firstUnresolvedThreadUrl: threads.unresolved > 0 ? "\(url)#discussion_r1" : nil
    )
}
