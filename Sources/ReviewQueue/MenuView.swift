import ReviewQueueCore
import SwiftUI

/// The review queue's menu bar window: header, error lines, then the collapsible blocks of PR rows.
struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        MenuPanel(model: model, tab: .reviewQueue, fetchedAt: model.fetchedAt) { showSettings in
            if model.settings.teams.isEmpty {
                Text("Choose the GitHub teams whose PRs you review.").foregroundStyle(.secondary)
                Button("Choose teams", action: showSettings).buttonStyle(.glassProminent)
            } else {
                if !model.isLoading, let error = model.error {
                    ErrorBanner(message: "GitHub: \(error)", color: .red)
                }
                LinearErrorLine(model: model)
                ScrollingBlocks { blocks }
            }
        }
    }

    private var blocks: some View {
        let lists = model.lists
        let now = Date()
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Block.allCases.filter { $0 == .high || $0 == .needs || !(lists[$0]?.shown.isEmpty ?? true) || !(lists[$0]?.dismissed.isEmpty ?? true) }) { block in
                let list = lists[block] ?? .empty
                BlockSection(
                    title: block.label,
                    style: block.style,
                    list: list,
                    isHighlighted: block == .high,
                    isOpen: Binding(
                        get: { model.expanded.contains(block) },
                        set: { isOpen in if isOpen { model.expanded.insert(block) } else { model.expanded.remove(block) } }
                    ),
                    limit: Binding(get: { model.shownRows[block] ?? AppModel.pageRows }, set: { model.shownRows[block] = $0 }),
                    grouping: PrGrouping(
                        mode: Binding(
                            get: { blockPrefsOf(model.settings, block).grouping },
                            set: { mode in model.update { $0.updateBlockPrefs(block) { $0.grouping = mode } } }
                        ),
                        author: \.author
                    ),
                    hiddenNote: list.hidden.note,
                    onUndo: { model.restore($0) }
                ) { pr in
                    CardView(model: model, pr: pr, now: now)
                }
            }
        }
    }
}

/// A menu bar window's frame: status line with Refresh, Statistics (review queue only), Settings (opening `tab`) and
/// Quit, then `content`, which gets
/// the Settings action for its own empty states. `fixedSize` pins the panel's minimum and maximum height to its ideal
/// height, so the MenuBarExtra window's hosting view is constrained to the content and shrinks with it instead of
/// keeping an earlier, taller size with the content centred. Don't wrap it in a flexible frame: that lifts the maximum.
struct MenuPanel<Content: View>: View {
    let model: AppModel
    let tab: SettingsTab
    let fetchedAt: Date?
    @ViewBuilder let content: (_ showSettings: @escaping () -> Void) -> Content
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content(showSettings)
        }
        .padding(14)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(status).foregroundStyle(.secondary).font(.callout).monospacedDigit()
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HeaderButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await model.refresh() } }
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.isLoading)
                        .disabled(model.isLoading)
                    if tab == .reviewQueue {
                        HeaderButton(symbol: "chart.bar.xaxis", help: "Statistics", action: showStatistics)
                    }
                    HeaderButton(symbol: "gearshape", help: "Settings", action: showSettings)
                    HeaderButton(symbol: "power", help: "Quit Review Queue") { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }

    private var status: String {
        if model.isLoading { return "Refreshing…" }
        guard let fetchedAt else { return "Not loaded yet" }
        return "Updated \(clockTime(fetchedAt)) · every \(model.settings.intervalMinutes)m"
    }

    private func showStatistics() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: StatsView.windowId)
    }

    private func showSettings() {
        model.settingsTab = tab
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }
}

/// A circular glass icon button for the menu header.
struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.neutralGlass)
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct LinearErrorLine: View {
    let model: AppModel

    var body: some View {
        if !model.isLoading, let error = model.linearError {
            ErrorBanner(message: "Linear: \(error)", color: .orange)
        }
    }
}

/// Blocks in a scroll view whose height is the content's measured height, capped at 600 points. The measurement
/// follows every collapse, expand, Done and refresh, and the fixed frame is what gives the menu panel its ideal height.
struct ScrollingBlocks<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .padding(.trailing, 4)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 40), 600))
    }
}

/// A block's grouping mode and how to read a PR's author, which `TrackedPr` doesn't carry.
struct PrGrouping<Pr: TrackedPr> {
    let mode: Binding<BlockGrouping>
    let author: (Pr) -> String

    /// The group a PR falls in under the current mode, nil when it has no story or the mode is `.age`.
    func key(_ pr: Pr) -> String? {
        switch mode.wrappedValue {
        case .age: nil
        case .author: author(pr)
        case .story: pr.storyId
        }
    }
}

/// One collapsible block with its hidden-count and marked-done lines and paged PR rows in a tight stack, grouped in one
/// glass container so expanded cards share a sampling region. The marked-done line shows only with an `onUndo`.
/// The title turns orange while a highlighted block has PRs. With a `grouping` the header gets a group-by menu; grouped
/// by author or story, each group is a collapsed row that opens to all of its cards, unpaged, and which groups are open
/// lasts only until the view goes or the mode changes.
struct BlockSection<Pr: TrackedPr, Card: View>: View {
    let title: String
    let style: BlockStyle
    let list: BlockList<Pr>
    let isHighlighted: Bool
    @Binding var isOpen: Bool
    @Binding var limit: Int
    let grouping: PrGrouping<Pr>?
    let hiddenNote: String?
    let onUndo: (([Pr]) -> Void)?
    @ViewBuilder let card: (Pr) -> Card
    @State private var openGroups: Set<String?> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isOpen {
                if let hiddenNote {
                    Text(hiddenNote).foregroundStyle(.secondary).font(.caption)
                }
                if let onUndo, !list.dismissed.isEmpty {
                    HStack(spacing: 4) {
                        Text("\(list.dismissed.count) marked done").foregroundStyle(.secondary)
                        Button("Undo") { onUndo(list.dismissed) }.buttonStyle(.link)
                    }
                    .font(.caption)
                }
                if list.shown.isEmpty {
                    Label("Nothing here", systemImage: "tray")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else if let grouping, grouping.mode.wrappedValue != .age {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(prGroups(list.shown, by: grouping.key, untitled: "No \(grouping.mode.wrappedValue.label.lowercased())")) { group in
                            groupRow(group)
                        }
                    }
                } else {
                    cardStack(Array(list.shown.prefix(limit)))
                    if list.shown.count > limit {
                        let remaining = list.shown.count - limit
                        Button("Show \(min(AppModel.pageRows, remaining)) more of \(remaining)") {
                            limit += AppModel.pageRows
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: style.symbol)
                        .foregroundStyle(style.color)
                        .frame(width: 18)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(isHighlighted && !list.shown.isEmpty ? Color.orange : Color.primary)
                    CountBadge(count: list.shown.count)
                    Spacer()
                    DisclosureChevron(isOpen: isOpen)
                        .animation(.snappy, value: isOpen)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(list.shown.count)")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if let grouping {
                groupMenu(grouping.mode)
            }
        }
    }

    private func groupMenu(_ mode: Binding<BlockGrouping>) -> some View {
        let current = mode.wrappedValue
        let selection = Binding(
            get: { mode.wrappedValue },
            set: { newMode in
                openGroups = []
                withAnimation(.snappy) { mode.wrappedValue = newMode }
            }
        )
        return Menu {
            Picker("Group by", selection: selection) {
                ForEach(BlockGrouping.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: current.symbol)
                .foregroundStyle(current == .age ? Color.secondary : Color.accentColor)
                .frame(width: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.callout)
        .help("Group by: \(current.label)")
        .accessibilityLabel("Group by: \(current.label)")
    }

    private func groupRow(_ group: PrGroup<Pr>) -> some View {
        let isGroupOpen = openGroups.contains(group.key)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) {
                    if isGroupOpen { openGroups.remove(group.key) } else { openGroups.insert(group.key) }
                }
            } label: {
                HStack(spacing: 8) {
                    DisclosureChevron(isOpen: isGroupOpen)
                        .frame(width: 18)
                    Text(group.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(group.key == nil ? Color.secondary : Color.primary)
                    CountBadge(count: group.prs.count)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.title), \(group.prs.count)")
            .accessibilityValue(isGroupOpen ? "Expanded" : "Collapsed")
            if isGroupOpen {
                cardStack(group.prs)
            }
        }
    }

    private func cardStack(_ prs: [Pr]) -> some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(prs) { pr in
                    card(pr)
                }
            }
        }
    }
}

extension BlockGrouping {
    /// The header menu's icon for this mode.
    var symbol: String {
        switch self {
        case .age: "clock"
        case .author: "person.2"
        case .story: "bookmark"
        }
    }
}
