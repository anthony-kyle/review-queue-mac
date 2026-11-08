import ReviewQueueCore
import SwiftUI

/// One of your PRs as a shared row: where, why it needs you, the shared detail rows, who is still requested, and its
/// new comments, each with No follow-up and Ignore buttons.
struct MyPrCardView: View {
    let model: AppModel
    let pr: MyPr
    let now: Date

    var body: some View {
        let settings = model.settings
        let context = model.myContext
        let block = myBlockOf(pr, context)
        PrRow(
            model: model,
            pr: pr,
            now: now,
            tint: block.style.cardTint,
            signal: mySignal(pr, context),
            isExpanded: model.myRowExpansion.isExpanded(pr.key, byDefault: block.areRowsExpandedByDefault),
            onToggle: { model.myRowExpansion.toggle(pr.key) },
            onDone: { model.markDone(pr) }
        ) {
            StandardDetailRows(
                model: model,
                pr: pr,
                settings: settings,
                now: now,
                reason: myReasonOf(pr, context).map { PrSignal($0, block == .needsYou ? .error : .warning) }
            )
            if settings.shows(.waiting), !pr.requestedReviewers.isEmpty {
                CardField("Requested") { Text(pr.requestedReviewers.joined(separator: ", ")) }
            }
            ForEach(newComments(pr, context)) { comment in
                commentRow(comment)
            }
        }
    }

    private func commentRow(_ comment: PrComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LinkButton(action: comment.url.isEmpty ? nil : { model.open(comment.url) }) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.author)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(comment.url.isEmpty ? .primary : Color.linkText)
                    Text(comment.body.isEmpty ? "(no text)" : comment.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .help(comment.url.isEmpty ? "" : "Open comment on GitHub")
            HStack(spacing: 4) {
                Button { model.acknowledge([comment.id]) } label: { Label("No follow-up", systemImage: "checkmark") }
                    .help("Stop counting this comment as new")
                Button { model.ignoreCommenter(comment.author) } label: {
                    Label("Ignore \(comment.author)", systemImage: "person.crop.circle.badge.xmark")
                }
                .help("Never count comments from \(comment.author); undo here or in Settings › My PRs")
            }
            .buttonStyle(.neutralGlass)
            .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }
}
