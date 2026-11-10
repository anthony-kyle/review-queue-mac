import ReviewQueueCore
import SwiftUI

/// One review-queue PR as a shared row: author, where, why and the detail rows the person keeps on, with pin / mute
/// buttons beside Done. The author is teal, orange when pinned and grey when muted, and opens their GitHub profile.
struct CardView: View {
    let model: AppModel
    let pr: QueuePr
    let now: Date

    var body: some View {
        let settings = model.settings
        let block = blockOf(pr, settings)
        PrRow(
            model: model,
            pr: pr,
            now: now,
            tint: block.style.cardTint,
            signal: queueSignal(pr),
            isExpanded: model.rowExpansion.isExpanded(pr.key, byDefault: block.areRowsExpandedByDefault),
            onToggle: { model.rowExpansion.toggle(pr.key) },
            onDone: { model.markDone(pr) }
        ) {
            CardField("Author") {
                LinkText(pr.author, color: authorColor(settings)) { model.open("https://github.com/\(pr.author)") }
            }
            StandardDetailRows(model: model, pr: pr, settings: settings, now: now, reason: reason(settings))
        } accessory: {
            if let since = pr.sinceMyReviewUrl {
                Button("Since your review") { model.open(since) }
                    .buttonStyle(.ghost(.githubPurple))
                    .help("Files changed since the commit you last reviewed")
            }
            if settings.shows(.actions) {
                authorActions(settings)
            }
        }
    }

    private func authorColor(_ settings: QueueSettings) -> Color {
        settings.highUsers.contains(pr.author) ? .orange : settings.lowUsers.contains(pr.author) ? .secondary : .teal
    }

    private func reason(_ settings: QueueSettings) -> PrSignal? {
        if let reason = reasonOf(pr, settings) { return PrSignal(reason, .warning) }
        return pr.isReviewRequested ? PrSignal("Review requested", .info) : nil
    }

    private func authorActions(_ settings: QueueSettings) -> some View {
        let isPinned = settings.highUsers.contains(pr.author)
        let isMuted = settings.lowUsers.contains(pr.author)
        return HStack(spacing: 10) {
            iconButton(isPinned ? "star.fill" : "star", label: isPinned ? "Unpin author" : "Pin author") {
                model.update { $0.togglePin(pr.author) }
            }
            iconButton(isMuted ? "speaker.wave.2" : "speaker.slash", label: isMuted ? "Unmute author" : "Mute author") {
                model.update { $0.toggleMute(pr.author) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.caption)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help("\(label) \(pr.author)")
            .accessibilityLabel("\(label) \(pr.author)")
    }
}

/// One PR in a block, shared by both menus. Collapsed it is a one-line toggle: title, the most urgent `signal`, a CI
/// dot and age since the PR was opened, matching the blocks' sort. Expanded it is a glass card tinted by `tint`: a label grid of `details`, then
/// GitHub Review, Linear Review, `accessory` and Done. `details` holds `CardField`s; any other view in it spans the
/// grid's full width.
struct PrRow<Pr: TrackedPr, Details: View, Accessory: View>: View {
    private static var indent: CGFloat { 20 }

    let model: AppModel
    let pr: Pr
    let now: Date
    let tint: Color?
    let signal: PrSignal?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDone: () -> Void
    @ViewBuilder let details: () -> Details
    @ViewBuilder let accessory: () -> Accessory
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggle
            if isExpanded {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                    details()
                }
                .font(.callout)
                .padding(.leading, Self.indent)
                actions
                    .padding(.leading, Self.indent)
            }
        }
        .padding(.horizontal, isExpanded ? 12 : 8)
        .padding(.vertical, isExpanded ? 10 : 5)
        .background(.fill.quaternary.opacity(isHovered && !isExpanded ? 1 : 0), in: .rect(cornerRadius: 8))
        .glassCard(tint: tint, isShown: isExpanded)
        .padding(.vertical, isExpanded ? 3 : 0)
        .onHover { isHovered = $0 }
    }

    private var toggle: some View {
        let ci = ciMark(pr.ci)
        return Button {
            withAnimation(.snappy) { onToggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.indent - 8)
                Text("#\(pr.number) \(pr.title)")
                    .fontWeight(isExpanded ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(pr.title)
                if !isExpanded {
                    if let signal {
                        Text(signal.text)
                            .font(.caption)
                            .foregroundStyle(signal.tone.color)
                            .fixedSize()
                    }
                    Circle()
                        .fill(ci.tone.color)
                        .frame(width: 8, height: 8)
                        .help("CI \(ci.text)")
                }
                Text(compactAge(pr.createdAt, now: now))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                    .help("Opened \(timeAgo(pr.createdAt, now: now))")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") #\(pr.number) \(pr.title)")
        .accessibilityValue(isExpanded ? "" : [signal?.text, "CI \(ci.text)"].compactMap(\.self).joined(separator: ", "))
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("GitHub Review") { model.open(pr.url) }
                .buttonStyle(.glassProminent)
                .tint(.githubPurple)
            if let linear = pr.linearReviewUrl {
                Button("Linear Review") { model.open(linear) }
                    .buttonStyle(.glassProminent)
                    .tint(.linearIndigo)
            }
            Spacer(minLength: 8)
            accessory()
            Button(action: onDone) { Label("Done", systemImage: "checkmark") }
                .buttonStyle(.ghost(.green))
                .help("Hide until this PR next changes")
        }
        .controlSize(.small)
    }
}

extension PrRow where Accessory == EmptyView {
    init(
        model: AppModel,
        pr: Pr,
        now: Date,
        tint: Color?,
        signal: PrSignal?,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        onDone: @escaping () -> Void,
        @ViewBuilder details: @escaping () -> Details
    ) {
        self.init(
            model: model,
            pr: pr,
            now: now,
            tint: tint,
            signal: signal,
            isExpanded: isExpanded,
            onToggle: onToggle,
            onDone: onDone,
            details: details,
            accessory: { EmptyView() }
        )
    }
}

/// The grid lines both cards share, each behind its Card details toggle: where (repo and story), why it is listed,
/// waiting, approvals, changes-requests, activity (comments and threads) and CI with failing / neutral check names. The comments part
/// opens the newest comment and the threads part the first unresolved thread; each is plain text when there is nothing
/// to open.
struct StandardDetailRows<Pr: TrackedPr>: View {
    let model: AppModel
    let pr: Pr
    let settings: QueueSettings
    let now: Date
    let reason: PrSignal?

    var body: some View {
        CardField("Where") { whereValue }
        if settings.shows(.reason), let reason {
            CardField("Why") { Text(reason.text).foregroundStyle(reason.tone.color) }
        }
        if settings.shows(.waiting) {
            CardField("Waiting") { Text("opened \(timeAgo(pr.createdAt, now: now)) · updated \(timeAgo(pr.updatedAt, now: now))") }
        }
        if settings.shows(.approvals), !pr.approvals.isEmpty {
            CardField("Approved") { Text(pr.approvals.joined(separator: ", ")).foregroundStyle(.green) }
        }
        if settings.shows(.changes), !pr.changesRequests.isEmpty {
            CardField("Changes") { Text(pr.changesRequests.joined(separator: ", ")).foregroundStyle(.red) }
        }
        if settings.shows(.comments) || settings.shows(.threads) {
            CardField("Activity") { activityValue }
        }
        if settings.shows(.ci) || hasFailing || hasNeutral {
            CardField("CI") { ciValue }
        }
    }

    private var hasFailing: Bool { settings.shows(.failing) && !pr.failingChecks.isEmpty }
    private var hasNeutral: Bool { settings.shows(.neutral) && !pr.neutralChecks.isEmpty }

    private var whereValue: some View {
        HStack(spacing: 4) {
            LinkText(pr.repo, color: .primary) { model.open("https://github.com/\(pr.owner)/\(pr.repo)") }
            if let story = pr.storyId {
                Text("·").foregroundStyle(.secondary)
                LinkText(story, action: model.storyWorkspace.map { workspace in { model.open("https://linear.app/\(workspace)/issue/\(story)") } })
            }
        }
        .lineLimit(1)
    }

    private var activityValue: some View {
        HStack(spacing: 4) {
            if settings.shows(.comments) {
                let url = pr.commentCount > 0 ? pr.latestCommentUrl ?? pr.url : nil
                LinkText(pr.commentCount == 1 ? "1 comment" : "\(pr.commentCount) comments", action: url.map { url in { model.open(url) } })
            }
            if settings.shows(.comments), settings.shows(.threads) {
                Text("·").foregroundStyle(.secondary)
            }
            if settings.shows(.threads) {
                if pr.unresolvedThreads > 0 {
                    LinkText(
                        "\(pr.unresolvedThreads) of \(pr.totalThreads) threads unresolved",
                        color: .orange,
                        action: pr.firstUnresolvedThreadUrl.map { url in { model.open(url) } }
                    )
                } else {
                    Text("no open threads").foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }

    private var ciValue: some View {
        VStack(alignment: .leading, spacing: 2) {
            if settings.shows(.ci) {
                let ci = ciMark(pr.ci)
                Text(ci.text).foregroundStyle(ci.tone.color)
            }
            if hasFailing {
                Text(nameList(pr.failingChecks)).foregroundStyle(.red)
            }
            if hasNeutral {
                Text("\(nameList(pr.neutralChecks)) (neutral)").foregroundStyle(.blue)
            }
        }
    }
}
