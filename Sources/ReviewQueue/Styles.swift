import ReviewQueueCore
import SwiftUI

/// The symbol, symbol colour and card tint a block shows, shared by both menus.
struct BlockStyle {
    let symbol: String
    let color: Color
    let cardTint: Color?
}

extension Block {
    var style: BlockStyle {
        switch self {
        case .high: BlockStyle(symbol: "exclamationmark.circle.fill", color: .red, cardTint: .orange)
        case .needs: BlockStyle(symbol: "tray.full", color: .accentColor, cardTint: nil)
        case .waiting: BlockStyle(symbol: "hourglass", color: .secondary, cardTint: nil)
        case .approved: BlockStyle(symbol: "checkmark.seal", color: .green, cardTint: .green)
        case .drafts: BlockStyle(symbol: "pencil.and.outline", color: .secondary, cardTint: nil)
        case .low: BlockStyle(symbol: "arrow.down.circle", color: .secondary, cardTint: nil)
        }
    }
}

extension MyBlock {
    var style: BlockStyle {
        switch self {
        case .needsYou: BlockStyle(symbol: "bell.badge.fill", color: .red, cardTint: .red)
        case .ready: BlockStyle(symbol: "checkmark.seal.fill", color: .green, cardTint: .green)
        case .waiting: BlockStyle(symbol: "person.2", color: .secondary, cardTint: nil)
        case .drafts: BlockStyle(symbol: "pencil.and.outline", color: .secondary, cardTint: nil)
        }
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .warning: .orange
        case .subtle: .secondary
        }
    }
}

extension Color {
    static let linearIndigo = Color(red: 0.37, green: 0.42, blue: 0.82)
    static let githubPurple = Color(red: 0.51, green: 0.31, blue: 0.87)
    static let linkText = Color(nsColor: .linkColor)
}

extension PrimitiveButtonStyle where Self == GlassButtonStyle {
    /// Glass with a neutral wash, so secondary buttons stand out from any card tint without a colour of their own.
    static var neutralGlass: GlassButtonStyle { .glass(.regular.tint(.primary.opacity(0.15))) }
}

/// An outline in `color` with no fill until pressed or hovered, for actions that should read as optional. Shape, height
/// and line weight match the glass buttons it sits beside.
struct GhostButtonStyle: ButtonStyle {
    private static let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    let color: Color
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background(Self.shape.fill(color.opacity(configuration.isPressed ? 0.25 : isHovered ? 0.12 : 0)))
            .overlay(Self.shape.strokeBorder(color.opacity(0.9), lineWidth: 1))
            .contentShape(Self.shape)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static func ghost(_ color: Color) -> GhostButtonStyle { GhostButtonStyle(color: color) }
}

extension View {
    /// Rounded clear Liquid Glass behind a card, tinted by its state; untinted when `tint` is nil.
    func glassCard(tint: Color?) -> some View {
        padding(12)
            .glassEffect(.clear.tint(tint?.opacity(0.2)), in: .rect(cornerRadius: 16))
    }
}

/// Text that opens a page: a plain button with a pointing-hand cursor, or just the label when `action` is nil.
struct LinkButton<Label: View>: View {
    let action: (() -> Void)?
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let action {
            Button(action: action, label: label)
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityAddTraits(.isLink)
        } else {
            label()
        }
    }
}

/// One card detail: a secondary SF Symbol, then the value, underlined as a link when `action` is set. `label` names the
/// row for tooltips and VoiceOver, since the symbol replaces it on screen.
struct DetailRow: View {
    let symbol: String
    let label: String
    let value: String
    var color: Color = .primary
    var symbolColor: Color = .secondary
    var action: (() -> Void)? = nil

    var body: some View {
        LinkButton(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
                    .frame(width: 16)
                Text(value).foregroundStyle(color).underline(action != nil)
            }
        }
        .font(.callout)
        .help(label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }
}

/// A GitHub or Linear failure as a tinted glass banner.
struct ErrorBanner: View {
    let message: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(message).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear.tint(color.opacity(0.25)), in: .rect(cornerRadius: 12))
    }
}

/// A count in a small capsule, for block headers.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(.fill.tertiary, in: Capsule())
    }
}
