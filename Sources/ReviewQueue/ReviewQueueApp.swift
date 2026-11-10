import ReviewQueueCore
import SwiftUI

@main
struct ReviewQueueApp: App {
    @State private var model: AppModel

    init() {
        if ScreenshotStage.isEnabled {
            let demo = AppModel(demo: DemoData(now: Date()))
            _model = State(initialValue: demo)
            ScreenshotStage.start(demo)
        } else {
            _model = State(initialValue: AppModel())
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!ScreenshotStage.isEnabled)) {
            MenuView(model: model)
        } label: {
            QueueMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: .constant(!ScreenshotStage.isEnabled)) {
            MyPrsMenuView(model: model)
        } label: {
            MyPrsMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, maxHeight: ScreenshotStage.isEnabled ? .infinity : 700)
        }
    }
}

/// The review queue's pill, from the High priority and Needs review counts.
struct QueueMenuBarLabel: View {
    let model: AppModel

    var body: some View {
        MenuBarLabel.queue(high: model.lists[.high]?.shown.count ?? 0, needs: model.lists[.needs]?.shown.count ?? 0)
    }
}

/// The My PRs pill, from the Needs you, Ready to merge and Waiting counts.
struct MyPrsMenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let lists = model.myLists
        MenuBarLabel.myPrs(
            needsYou: lists[.needsYou]?.shown.count ?? 0,
            ready: lists[.ready]?.shown.count ?? 0,
            waiting: lists[.waiting]?.shown.count ?? 0
        )
    }
}

/// A menu bar label showing `pill` drawn to an image, since a MenuBarExtra label renders SwiftUI views as monochrome
/// templates and drops colour. Coloured tones opt out of templating; `idle` keeps it so the menu bar tints it like its
/// own items. `fallback` is used if rendering fails.
struct MenuBarLabel: View {
    let pill: MenuBarPill
    let fallback: String
    @Environment(\.displayScale) private var displayScale

    /// The review queue's pill: High priority and Needs review counts, coloured by `menuTone`.
    static func queue(high: Int, needs: Int) -> MenuBarLabel {
        let counts = high > 0 ? "\(high)! · \(needs)" : "\(needs)"
        return MenuBarLabel(
            pill: MenuBarPill(
                icon: high > 0 ? "exclamationmark.bubble.fill" : "checklist",
                text: high > 0 || needs > 0 ? counts : nil,
                tone: menuTone(high: high, needs: needs)
            ),
            fallback: counts
        )
    }

    /// The My PRs pill: a person icon and the Needs you count, coloured by `myMenuTone`.
    static func myPrs(needsYou: Int, ready: Int, waiting: Int) -> MenuBarLabel {
        MenuBarLabel(
            pill: MenuBarPill(
                icon: needsYou > 0 ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle",
                text: needsYou > 0 ? "\(needsYou)" : nil,
                tone: myMenuTone(needsYou: needsYou, ready: ready, waiting: waiting)
            ),
            fallback: "Mine \(needsYou)"
        )
    }

    var body: some View {
        if let image = image(scale: displayScale) {
            return AnyView(Image(nsImage: image))
        }
        return AnyView(Text(fallback))
    }

    @MainActor func image(scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: pill)
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = pill.tone == .idle
        return image
    }
}

/// The pill itself: an SF Symbol and optional counts in white on a softly graded green, amber or red capsule by `tone`,
/// with a faint inner highlight. Solid colours only, since glass does not render offscreen in `ImageRenderer`; `idle`
/// stands in for glass with a faint outlined capsule drawn for template tinting, where only alpha survives.
struct MenuBarPill: View {
    let icon: String
    let text: String?
    let tone: MenuTone

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            if let text {
                Text(text).monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(tone == .idle ? .black : .white)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Capsule().fill(background))
        .overlay(Capsule().strokeBorder(tone == .idle ? .black.opacity(0.35) : .white.opacity(0.25), lineWidth: 0.5))
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .clear, .ready: AnyShapeStyle(Color(nsColor: .systemGreen).gradient)
        case .waiting: AnyShapeStyle(Color(nsColor: .systemOrange).gradient)
        case .urgent: AnyShapeStyle(Color(nsColor: .systemRed).gradient)
        case .idle: AnyShapeStyle(.black.opacity(0.12))
        }
    }
}
