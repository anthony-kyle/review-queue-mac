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

/// A block's sort and approved-by-others filter. Only High priority shows PRs someone else already approved by default,
/// since those still need you there; elsewhere another approval usually means your review isn't the blocker.
public func blockPrefsOf(_ settings: QueueSettings, _ block: Block) -> BlockPrefs {
    settings.blockPrefs[block] ?? BlockPrefs(sort: .oldest, isOthersApprovedShown: block == .high)
}

public struct BlockList<Pr: TrackedPr>: Equatable, Sendable {
    public let shown: [Pr]
    public let hiddenCount: Int
    public var dismissed: [Pr] = []

    public static var empty: BlockList { BlockList(shown: [], hiddenCount: 0) }
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
        return (block, blockList(all, sort: prefs.sort, dismissals: dismissals) { prefs.isOthersApprovedShown || $0.approvedByOthers.isEmpty })
    })
}

/// One block's PRs: marked-done ones set apart, the rest kept when `isShown` and sorted by opening time. `hiddenCount`
/// is what `isShown` dropped.
func blockList<P: TrackedPr>(_ all: [P], sort: BlockSort, dismissals: Dismissals, isShown: (P) -> Bool = { _ in true }) -> BlockList<P> {
    let dismissed = all.filter { isDismissed($0, dismissals) }
    let shown = all
        .filter { !isDismissed($0, dismissals) && isShown($0) }
        .sorted { sort == .oldest ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
    return BlockList(shown: shown, hiddenCount: all.count - shown.count - dismissed.count, dismissed: dismissed)
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
