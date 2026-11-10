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

/// The review queue's pill: High priority and Needs review counts, coloured by `menuTone`.
struct QueueMenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let lists = model.lists
        let high = lists[.high]?.shown.count ?? 0
        let needs = lists[.needs]?.shown.count ?? 0
        let counts = high > 0 ? "\(high)! · \(needs)" : "\(needs)"
        MenuBarLabel(
            pill: MenuBarPill(
                icon: high > 0 ? "exclamationmark.bubble.fill" : "checklist",
                text: high > 0 || needs > 0 ? counts : nil,
                tone: menuTone(high: high, needs: needs)
            ),
            fallback: counts
        )
    }
}

/// The My PRs pill: a person icon and the Needs you count, coloured by `myMenuTone`.
struct MyPrsMenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let lists = model.myLists
        let needsYou = lists[.needsYou]?.shown.count ?? 0
        MenuBarLabel(
            pill: MenuBarPill(
                icon: needsYou > 0 ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle",
                text: needsYou > 0 ? "\(needsYou)" : nil,
                tone: myMenuTone(needsYou: needsYou, ready: lists[.ready]?.shown.count ?? 0, waiting: lists[.waiting]?.shown.count ?? 0)
            ),
            fallback: "Mine \(needsYou)"
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

    var body: some View {
        let renderer = ImageRenderer(content: pill)
        renderer.scale = displayScale
        if let image = renderer.nsImage {
            image.isTemplate = pill.tone == .idle
            return AnyView(Image(nsImage: image))
        }
        return AnyView(Text(fallback))
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
