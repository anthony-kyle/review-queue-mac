import Foundation

/// Everything the person chooses in Settings. Decoding fills defaults for any field an older version never wrote.
public struct QueueSettings: Codable, Equatable, Sendable {
    public static let intervals = [5, 10, 15, 30, 60]

    public var intervalMinutes = 15
    public var teams: [String] = []
    public var repoAccess: RepoAccess = .owned
    public var highUsers: [String] = []
    public var lowUsers: [String] = []
    public var hiddenDetails: [CardDetail] = []
    public var blockPrefs: [Block: BlockPrefs] = [:]
    public var linearWorkspace = ""
    public var notifyHigh = true
    public var repeatHighReminders = true
    public var notifyNeeds = true
    public var notifyReviewRequested = true
    public var highSound = "Sosumi"
    public var normalSound = "Glass"
    public var myPrs = MyPrsSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case intervalMinutes, teams, repoAccess, highUsers, lowUsers, hiddenDetails, blockPrefs, linearWorkspace
        case notifyHigh, repeatHighReminders, notifyNeeds, notifyReviewRequested, highSound, normalSound, myPrs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QueueSettings()
        intervalMinutes = try c.value(.intervalMinutes, or: d.intervalMinutes)
        teams = try c.value(.teams, or: d.teams)
        repoAccess = try c.value(.repoAccess, or: d.repoAccess)
        highUsers = try c.value(.highUsers, or: d.highUsers)
        lowUsers = try c.value(.lowUsers, or: d.lowUsers)
        hiddenDetails = try c.value(.hiddenDetails, or: d.hiddenDetails)
        blockPrefs = try c.value(.blockPrefs, or: d.blockPrefs)
        linearWorkspace = try c.value(.linearWorkspace, or: d.linearWorkspace)
        notifyHigh = try c.value(.notifyHigh, or: d.notifyHigh)
        repeatHighReminders = try c.value(.repeatHighReminders, or: d.repeatHighReminders)
        notifyNeeds = try c.value(.notifyNeeds, or: d.notifyNeeds)
        notifyReviewRequested = try c.value(.notifyReviewRequested, or: d.notifyReviewRequested)
        highSound = try c.value(.highSound, or: d.highSound)
        normalSound = try c.value(.normalSound, or: d.normalSound)
        myPrs = try c.value(.myPrs, or: d.myPrs)
    }

    public func people(_ list: PeopleList) -> [String] {
        switch list {
        case .highUsers: highUsers
        case .lowUsers: lowUsers
        }
    }

    public mutating func setPerson(_ login: String, in list: PeopleList, isOn: Bool) {
        switch list {
        case .highUsers: highUsers = toggled(highUsers, login, isOn: isOn)
        case .lowUsers: lowUsers = toggled(lowUsers, login, isOn: isOn)
        }
    }

    /// Pins or unpins an author to High priority; pinning also unmutes them.
    public mutating func togglePin(_ author: String) {
        let isPinned = highUsers.contains(author)
        setPerson(author, in: .highUsers, isOn: !isPinned)
        setPerson(author, in: .lowUsers, isOn: false)
    }

    /// Mutes or unmutes an author into Low priority; muting also unpins them.
    public mutating func toggleMute(_ author: String) {
        let isMuted = lowUsers.contains(author)
        setPerson(author, in: .lowUsers, isOn: !isMuted)
        setPerson(author, in: .highUsers, isOn: false)
    }

    public mutating func setTeam(_ team: String, isOn: Bool) {
        teams = toggled(teams, team, isOn: isOn)
    }

    public mutating func setDetail(_ detail: CardDetail, isShown: Bool) {
        hiddenDetails = toggled(hiddenDetails, detail, isOn: !isShown)
    }

    public func shows(_ detail: CardDetail) -> Bool {
        !hiddenDetails.contains(detail)
    }
}

/// The My PRs menu's own choices: what to leave out, whose comments count, which events notify, and block order.
public struct MyPrsSettings: Codable, Equatable, Sendable {
    public var excludedOrgs: [String] = []
    public var excludedRepos: [String] = []
    public var isBotCommentsShown = true
    public var ignoredCommenters: [String] = []
    public var notifyComments = true
    public var notifyApproved = true
    public var notifyChangesRequested = true
    public var notifyCiFailing = true
    public var notifyConflict = true
    public var notifyClosed = true
    public var blockSorts: [MyBlock: BlockSort] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case excludedOrgs, excludedRepos, isBotCommentsShown, ignoredCommenters
        case notifyComments, notifyApproved, notifyChangesRequested, notifyCiFailing, notifyConflict, notifyClosed, blockSorts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MyPrsSettings()
        excludedOrgs = try c.value(.excludedOrgs, or: d.excludedOrgs)
        excludedRepos = try c.value(.excludedRepos, or: d.excludedRepos)
        isBotCommentsShown = try c.value(.isBotCommentsShown, or: d.isBotCommentsShown)
        ignoredCommenters = try c.value(.ignoredCommenters, or: d.ignoredCommenters)
        notifyComments = try c.value(.notifyComments, or: d.notifyComments)
        notifyApproved = try c.value(.notifyApproved, or: d.notifyApproved)
        notifyChangesRequested = try c.value(.notifyChangesRequested, or: d.notifyChangesRequested)
        notifyCiFailing = try c.value(.notifyCiFailing, or: d.notifyCiFailing)
        notifyConflict = try c.value(.notifyConflict, or: d.notifyConflict)
        notifyClosed = try c.value(.notifyClosed, or: d.notifyClosed)
        blockSorts = try c.value(.blockSorts, or: d.blockSorts)
    }

    public func sort(_ block: MyBlock) -> BlockSort {
        blockSorts[block] ?? .oldest
    }

    /// Adds (trimmed, ignoring blanks) or removes an org whose PRs My PRs leaves out.
    public mutating func setExcludedOrg(_ org: String, isOn: Bool) {
        excludedOrgs = toggledName(excludedOrgs, org, isOn: isOn)
    }

    /// Adds or removes an `owner/name` repo whose PRs My PRs leaves out; a value without a slash is not added.
    public mutating func setExcludedRepo(_ repo: String, isOn: Bool) {
        guard !isOn || repo.contains("/") else { return }
        excludedRepos = toggledName(excludedRepos, repo, isOn: isOn)
    }

    public mutating func setIgnored(_ login: String, isOn: Bool) {
        ignoredCommenters = toggledName(ignoredCommenters, login, isOn: isOn)
    }

    private func toggledName(_ list: [String], _ name: String, isOn: Bool) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        return toggled(list, trimmed, isOn: isOn)
    }
}

/// Adds `item` at the end when absent (`isOn`) or removes it, keeping the existing order.
func toggled<T: Equatable>(_ list: [T], _ item: T, isOn: Bool) -> [T] {
    if isOn { return list.contains(item) ? list : list + [item] }
    return list.filter { $0 != item }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
