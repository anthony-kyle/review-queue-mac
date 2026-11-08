import Foundation

public enum MyReview: String, Codable, Sendable {
    case none
    case approved
    case changesPending = "changes-pending"
    case changesAddressed = "changes-addressed"
}

public enum Block: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case high, needs, waiting, approved, drafts, low

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .high: "High priority"
        case .needs: "Needs review"
        case .waiting: "Waiting on author"
        case .approved: "Approved by you"
        case .drafts: "Drafts"
        case .low: "Low priority"
        }
    }

    public var isOpenByDefault: Bool { self == .high || self == .needs }

    /// The author list whose PRs always land in this block, for the two blocks that have one.
    public var peopleList: PeopleList? {
        switch self {
        case .high: .highUsers
        case .low: .lowUsers
        default: nil
        }
    }
}

public enum PeopleList: Sendable {
    case highUsers, lowUsers
}

public enum RepoAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case owned, write

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .owned: "Owned (team is admin or maintainer)"
        case .write: "Any the team can write to"
        }
    }

    var roles: Set<String> {
        switch self {
        case .owned: ["admin", "maintain"]
        case .write: ["admin", "maintain", "write"]
        }
    }
}

public enum CardDetail: String, Codable, CaseIterable, Identifiable, Sendable {
    case reason, waiting, approvals, comments, threads, ci, failing, neutral, actions

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .reason: "Why it is listed (e.g. Updated after your changes)"
        case .waiting: "⏳ Waiting (opened / updated)"
        case .approvals: "✅ Approved by others"
        case .comments: "💬 Comments"
        case .threads: "🧵 Unresolved threads"
        case .ci: "🚦 CI status"
        case .failing: "✗ Failing check names"
        case .neutral: "◦ Neutral check names"
        case .actions: "Pin / mute author buttons"
        }
    }
}

public enum BlockSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case oldest, newest

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .oldest: "Oldest first"
        case .newest: "Newest first"
        }
    }
}

public struct BlockPrefs: Codable, Equatable, Sendable {
    public var sort: BlockSort
    public var isOthersApprovedShown: Bool

    public init(sort: BlockSort, isOthersApprovedShown: Bool) {
        self.sort = sort
        self.isOthersApprovedShown = isOthersApprovedShown
    }
}

public struct Commenter: Codable, Equatable, Sendable {
    public let login: String
    public let count: Int
}

public struct QueuePr: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let title: String
    public let url: String
    public let author: String
    public let isDraft: Bool
    public let storyId: String?
    public var linearReviewUrl: String?
    public let myReview: MyReview
    public let isReviewRequested: Bool
    public let approvedByOthers: [String]
    public let commentCount: Int
    public let unresolvedThreads: Int
    public let totalThreads: Int
    public let commenters: [Commenter]
    public let ci: String?
    public let failingChecks: [String]
    public let neutralChecks: [String]
    public let pendingChecks: [String]
    public let createdAt: String
    public let updatedAt: String
    public var latestCommentUrl: String? = nil
    public var firstUnresolvedThreadUrl: String? = nil

    public var id: String { key }
}

public struct ReviewQueueError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// What blocks, cards, dismissals and Linear lookups read from a PR, shared by the review queue and My PRs.
public protocol TrackedPr: Identifiable, Equatable, Sendable where ID == String {
    var key: String { get }
    var owner: String { get }
    var repo: String { get }
    var number: Int { get }
    var title: String { get }
    var url: String { get }
    var storyId: String? { get }
    var linearReviewUrl: String? { get set }
    var approvals: [String] { get }
    var commentCount: Int { get }
    var unresolvedThreads: Int { get }
    var totalThreads: Int { get }
    var latestCommentUrl: String? { get }
    var firstUnresolvedThreadUrl: String? { get }
    var ci: String? { get }
    var failingChecks: [String] { get }
    var neutralChecks: [String] { get }
    var createdAt: String { get }
    var updatedAt: String { get }
}

extension QueuePr: TrackedPr {
    public var approvals: [String] { approvedByOthers }
}
