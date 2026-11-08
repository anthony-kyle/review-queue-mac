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
                    hiddenNote: list.hiddenCount > 0 ? "\(list.hiddenCount) approved by others hidden" : nil,
                    onUndo: { model.restore($0) }
                ) { pr in
                    CardView(model: model, pr: pr, now: now)
                }
            }
        }
    }
}

/// A menu bar window's frame: status line with Refresh, Settings (opening `tab`) and Quit, then `content`, which gets
/// the Settings action for its own empty states. `fixedSize` pins the panel's minimum and maximum height to its ideal
/// height, so the MenuBarExtra window's hosting view is constrained to the content and shrinks with it instead of
/// keeping an earlier, taller size with the content centred. Don't wrap it in a flexible frame: that lifts the maximum.
struct MenuPanel<Content: View>: View {
    let model: AppModel
    let tab: SettingsTab
    let fetchedAt: Date?
    @ViewBuilder let content: (_ showSettings: @escaping () -> Void) -> Content
    @Environment(\.openSettings) private var openSettings

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

/// One collapsible block with its hidden-count and marked-done lines and paged PR rows in a tight stack, grouped in one
/// glass container so expanded cards share a sampling region.
/// The title turns orange while a highlighted block has PRs.
struct BlockSection<Pr: TrackedPr, Card: View>: View {
    let title: String
    let style: BlockStyle
    let list: BlockList<Pr>
    let isHighlighted: Bool
    @Binding var isOpen: Bool
    @Binding var limit: Int
    let hiddenNote: String?
    let onUndo: ([Pr]) -> Void
    @ViewBuilder let card: (Pr) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isOpen {
                if let hiddenNote {
                    Text(hiddenNote).foregroundStyle(.secondary).font(.caption)
                }
                if !list.dismissed.isEmpty {
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
                } else {
                    GlassEffectContainer(spacing: 0) {
                        VStack(spacing: 2) {
                            ForEach(list.shown.prefix(limit)) { pr in
                                card(pr)
                            }
                        }
                    }
                }
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

    private var header: some View {
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .animation(.snappy, value: isOpen)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(list.shown.count)")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }
}
