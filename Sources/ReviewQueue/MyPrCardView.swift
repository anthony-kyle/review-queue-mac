import ReviewQueueCore
import SwiftUI

/// One of your PRs: the shared card with why it needs you, its new comments (each with No follow-up and Ignore
/// buttons), who is still requested, and the shared detail rows.
struct MyPrCardView: View {
    let model: AppModel
    let pr: MyPr
    let now: Date

    var body: some View {
        let settings = model.settings
        let context = model.myContext
        let block = myBlockOf(pr, context)
        PrCard(model: model, pr: pr, author: nil, tint: block.style.cardTint, onDone: { model.markDone(pr) }) {
            if settings.shows(.reason), let reason = myReasonOf(pr, context) {
                Text(reason).foregroundStyle(block == .needsYou ? .red : .orange).font(.callout.weight(.medium))
            }
            ForEach(newComments(pr, context)) { comment in
                commentRow(comment)
            }
            if settings.shows(.waiting), !pr.requestedReviewers.isEmpty {
                DetailRow(symbol: "person.crop.circle.badge.questionmark", label: "Requested", value: pr.requestedReviewers.joined(separator: ", "))
            }
            StandardDetailRows(model: model, pr: pr, settings: settings, now: now)
        }
    }

    private func commentRow(_ comment: PrComment) -> some View {
        HStack(alignment: .top, spacing: 6) {
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
                Button("No follow-up") { model.acknowledge([comment.id]) }
                    .help("Stop counting this comment as new")
                Button { model.update { $0.myPrs.setIgnored(comment.author, isOn: true) } } label: {
                    Image(systemName: "person.crop.circle.badge.xmark")
                }
                .help("Never count comments from \(comment.author); undo in Settings")
                .accessibilityLabel("Ignore \(comment.author)")
            }
            .buttonStyle(.neutralGlass)
            .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }
}
