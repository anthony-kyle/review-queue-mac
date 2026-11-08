import ReviewQueueCore
import SwiftUI

/// The My PRs menu bar window: header, error lines, then your open PRs in Needs you, Ready to merge, Waiting on
/// reviewers and Drafts.
struct MyPrsMenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        MenuPanel(model: model, tab: .myPrs, fetchedAt: model.myFetchedAt) { _ in
            if !model.isLoading, let error = model.myError {
                ErrorBanner(message: "GitHub: \(error)", color: .red)
            }
            LinearErrorLine(model: model)
            if let ignored = model.lastIgnored {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(.secondary)
                    Text("Ignoring \(ignored)'s comments")
                    Spacer()
                    LinkButton(action: model.undoIgnore) { Text("Undo").foregroundStyle(Color.linkText) }
                }
                .font(.callout)
            }
            ScrollingBlocks { blocks }
        }
    }

    private var blocks: some View {
        let lists = model.myLists
        let now = Date()
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(MyBlock.allCases.filter { $0 == .needsYou || !(lists[$0]?.shown.isEmpty ?? true) || !(lists[$0]?.dismissed.isEmpty ?? true) }) { block in
                BlockSection(
                    title: block.label,
                    style: block.style,
                    list: lists[block] ?? .empty,
                    isHighlighted: block == .needsYou,
                    isOpen: Binding(
                        get: { model.myExpanded.contains(block) },
                        set: { isOpen in if isOpen { model.myExpanded.insert(block) } else { model.myExpanded.remove(block) } }
                    ),
                    limit: Binding(get: { model.myShownRows[block] ?? AppModel.pageRows }, set: { model.myShownRows[block] = $0 }),
                    hiddenNote: nil,
                    onUndo: { model.restore($0) }
                ) { pr in
                    MyPrCardView(model: model, pr: pr, now: now)
                }
            }
        }
    }
}
