import Foundation

/// Places a PR in a block. Your own review standing wins over author lists, so an addressed changes-request still
/// surfaces from a low-priority author and an approval still collapses a daily-group author's PR.
public func blockOf(_ pr: QueuePr, _ settings: QueueSettings) -> Block {
    if pr.isDraft { return .drafts }
    switch pr.myReview {
    case .changesAddressed: return .high
    case .changesPending: return .waiting
    case .approved: return .approved
    case .none: break
    }
    if settings.lowUsers.contains(pr.author) { return .low }
    if settings.highUsers.contains(pr.author) { return .high }
    return .needs
}

/// A block's sort and others'-review filters. Only High priority shows PRs someone else already approved or requested
/// changes on by default, since those still need you there; elsewhere another decisive review usually means your
/// review isn't the blocker.
public func blockPrefsOf(_ settings: QueueSettings, _ block: Block) -> BlockPrefs {
    settings.blockPrefs[block] ?? BlockPrefs(sort: .oldest, isOthersApprovedShown: block == .high, isOthersChangesRequestedShown: block == .high)
}

/// PRs a block's filters dropped, by reason. A PR both filters drop counts under each.
public struct HiddenCounts: Equatable, Sendable {
    public var approved: Int
    public var changesRequested: Int

    public init(approved: Int = 0, changesRequested: Int = 0) {
        self.approved = approved
        self.changesRequested = changesRequested
    }

    public var isEmpty: Bool { approved == 0 && changesRequested == 0 }

    /// The block's hidden line, e.g. `2 approved by others, 1 changes requested by others hidden`; nil when none.
    public var note: String? {
        let parts = [
            approved > 0 ? "\(approved) approved by others" : nil,
            changesRequested > 0 ? "\(changesRequested) changes requested by others" : nil,
        ].compactMap(\.self)
        return parts.isEmpty ? nil : "\(parts.joined(separator: ", ")) hidden"
    }

    static func + (a: HiddenCounts, b: HiddenCounts) -> HiddenCounts {
        HiddenCounts(approved: a.approved + b.approved, changesRequested: a.changesRequested + b.changesRequested)
    }
}

public struct BlockList<Pr: TrackedPr>: Equatable, Sendable {
    public let shown: [Pr]
    public var hidden = HiddenCounts()
    public var dismissed: [Pr] = []

    public static var empty: BlockList { BlockList(shown: []) }
}

/// PRs marked done by hand, keyed by PR with the `updatedAt` they were marked at. A mark holds only while the PR is
/// unchanged, so a push, comment or your own review brings it back in whatever block it then belongs to.
public typealias Dismissals = [String: String]

public func isDismissed(_ pr: some TrackedPr, _ dismissals: Dismissals) -> Bool {
    dismissals[pr.key] == pr.updatedAt
}

/// The marks still in force: PRs that are gone or have changed since they were marked drop out.
public func prunedDismissals(_ dismissals: Dismissals, prs: [some TrackedPr]) -> Dismissals {
    dismissals.filter { key, updatedAt in prs.contains { $0.key == key && $0.updatedAt == updatedAt } }
}

/// PRs grouped by block, each filtered and sorted by its own prefs. Age is by opening time, so oldest first is the PR
/// that has waited longest.
public func blockLists(_ prs: [QueuePr], _ settings: QueueSettings, dismissals: Dismissals = [:]) -> [Block: BlockList<QueuePr>] {
    Dictionary(uniqueKeysWithValues: Block.allCases.map { block in
        let prefs = blockPrefsOf(settings, block)
        let all = prs.filter { blockOf($0, settings) == block }
        return (block, blockList(all, sort: prefs.sort, dismissals: dismissals) { pr in
            HiddenCounts(
                approved: !prefs.isOthersApprovedShown && !pr.approvedByOthers.isEmpty ? 1 : 0,
                changesRequested: !prefs.isOthersChangesRequestedShown && !pr.changesRequestedByOthers.isEmpty ? 1 : 0
            )
        })
    })
}

/// One block's PRs: marked-done ones set apart, the rest kept when `hiding` names no reason to drop them and sorted by
/// opening time. `hidden` tallies those reasons over the PRs not marked done.
func blockList<P: TrackedPr>(_ all: [P], sort: BlockSort, dismissals: Dismissals, hiding: (P) -> HiddenCounts = { _ in HiddenCounts() }) -> BlockList<P> {
    let dismissed = all.filter { isDismissed($0, dismissals) }
    let active = all.filter { !isDismissed($0, dismissals) }.map { ($0, hiding($0)) }
    let shown = active
        .filter { $0.1.isEmpty }
        .map(\.0)
        .sorted { sort == .oldest ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
    return BlockList(shown: shown, hidden: active.map(\.1).reduce(HiddenCounts(), +), dismissed: dismissed)
}

public enum MenuTone: Equatable, Sendable {
    case clear, waiting, urgent
}

/// The menu bar's colour state: urgent while anything is High priority, waiting while only Needs review has PRs, clear
/// when neither does.
public func menuTone(high: Int, needs: Int) -> MenuTone {
    if high > 0 { return .urgent }
    return needs > 0 ? .waiting : .clear
}

/// Why a PR is listed where it is, when that isn't obvious from the block alone.
public func reasonOf(_ pr: QueuePr, _ settings: QueueSettings) -> String? {
    switch pr.myReview {
    case .changesAddressed: return "Updated after your changes"
    case .changesPending: return "Changes requested"
    case .none where settings.highUsers.contains(pr.author): return "Daily group"
    default: return nil
    }
}
