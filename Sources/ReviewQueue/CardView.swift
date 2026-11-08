import ReviewQueueCore
import SwiftUI

/// One review-queue PR: the shared card with its reason, the detail rows the person keeps on, and pin / mute buttons.
struct CardView: View {
    let model: AppModel
    let pr: QueuePr
    let now: Date

    var body: some View {
        let settings = model.settings
        PrCard(model: model, pr: pr, author: pr.author, tint: blockOf(pr, settings).style.cardTint, onDone: { model.markDone(pr) }) {
            if settings.shows(.reason) {
                if let reason = reasonOf(pr, settings) {
                    Text(reason).foregroundStyle(.orange).font(.callout.weight(.medium))
                } else if pr.isReviewRequested {
                    Text("Review requested").foregroundStyle(.blue).font(.callout.weight(.medium))
                }
            }
            StandardDetailRows(model: model, pr: pr, settings: settings, now: now)
            if settings.shows(.actions) {
                authorActions(settings)
            }
        }
    }

    private func authorActions(_ settings: QueueSettings) -> some View {
        let isPinned = settings.highUsers.contains(pr.author)
        let isMuted = settings.lowUsers.contains(pr.author)
        return HStack(spacing: 14) {
            Button {
                model.update { $0.togglePin(pr.author) }
            } label: {
                Label(isPinned ? "Unpin author" : "Pin author", systemImage: isPinned ? "star.fill" : "star")
            }
            Button {
                model.update { $0.toggleMute(pr.author) }
            } label: {
                Label(isMuted ? "Unmute author" : "Mute author", systemImage: isMuted ? "speaker.wave.2" : "speaker.slash")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.caption)
        .padding(.top, 4)
    }
}

/// The card chrome both menus share: title, repo · story · author line, caller-supplied detail rows, and the Linear
/// Review, GitHub Review and Done buttons in a fixed-width right column, on glass tinted by `tint`. `author` is nil on
/// your own PRs, where it would always be you.
struct PrCard<Pr: TrackedPr, Details: View>: View {
    static var actionsWidth: CGFloat { 116 }

    let model: AppModel
    let pr: Pr
    let author: String?
    let tint: Color?
    let onDone: () -> Void
    @ViewBuilder let details: () -> Details

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("#\(pr.number) \(pr.title)")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(pr.title)
                sourceLine
                details()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .glassCard(tint: tint)
    }

    private var actions: some View {
        VStack(spacing: 6) {
            if let linear = pr.linearReviewUrl {
                Button { model.open(linear) } label: { Text("Linear Review").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .tint(.linearIndigo)
            }
            Button { model.open(pr.url) } label: { Text("GitHub Review").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent)
                .tint(.githubPurple)
            Button(action: onDone) { Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity) }
                .buttonStyle(.ghost(.green))
                .help("Hide until this PR next changes")
        }
        .controlSize(.small)
        .frame(width: Self.actionsWidth)
    }

    private var sourceLine: some View {
        HStack(spacing: 4) {
            Button(pr.repo) { model.open("https://github.com/\(pr.owner)/\(pr.repo)") }
                .buttonStyle(.link)
            if let story = pr.storyId {
                Text("·")
                if let workspace = model.storyWorkspace {
                    Button(story) { model.open("https://linear.app/\(workspace)/issue/\(story)") }.buttonStyle(.link)
                } else {
                    Text(story)
                }
            }
            if let author {
                Text("· \(author)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The detail rows both cards share, each behind its Card details toggle: waiting, approvals, comments, threads, CI and
/// failing / neutral check names. The comments row opens the newest comment and the threads row the first unresolved
/// thread; each is plain text when there is nothing to open.
struct StandardDetailRows<Pr: TrackedPr>: View {
    let model: AppModel
    let pr: Pr
    let settings: QueueSettings
    let now: Date

    var body: some View {
        if settings.shows(.waiting) {
            DetailRow(symbol: "clock", label: "Waiting", value: "opened \(timeAgo(pr.createdAt, now: now)) · updated \(timeAgo(pr.updatedAt, now: now))")
        }
        if settings.shows(.approvals), !pr.approvals.isEmpty {
            DetailRow(symbol: "checkmark.seal", label: "Approved by", value: pr.approvals.joined(separator: ", "), color: .green)
        }
        if settings.shows(.comments) {
            let commentUrl = pr.commentCount > 0 ? pr.latestCommentUrl ?? pr.url : nil
            DetailRow(
                symbol: "bubble.left",
                label: "Comments",
                value: pr.commentCount == 1 ? "1 comment" : "\(pr.commentCount) comments",
                color: commentUrl == nil ? .primary : .linkText,
                action: commentUrl.map { url in { model.open(url) } }
            )
        }
        if settings.shows(.threads) {
            let isOpen = pr.unresolvedThreads > 0
            DetailRow(
                symbol: isOpen ? "exclamationmark.bubble" : "text.bubble",
                label: "Unresolved threads",
                value: "\(pr.unresolvedThreads) of \(pr.totalThreads) threads unresolved",
                color: isOpen ? .orange : .secondary,
                symbolColor: isOpen ? .orange : .secondary,
                action: pr.firstUnresolvedThreadUrl.map { url in { model.open(url) } }
            )
        }
        if settings.shows(.ci) {
            let ci = ciMark(pr.ci)
            DetailRow(
                symbol: ci.tone == .subtle ? "circle.dashed" : "circle.fill",
                label: "CI",
                value: "CI \(ci.text)",
                color: ci.tone.color,
                symbolColor: ci.tone.color
            )
        }
        if settings.shows(.failing), !pr.failingChecks.isEmpty {
            DetailRow(symbol: "xmark.circle", label: "Failing checks", value: nameList(pr.failingChecks), color: .red, symbolColor: .red)
        }
        if settings.shows(.neutral), !pr.neutralChecks.isEmpty {
            DetailRow(symbol: "circle.dashed", label: "Neutral checks", value: "\(nameList(pr.neutralChecks)) (neutral)", color: .blue)
        }
    }
}
