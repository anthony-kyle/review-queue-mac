import AppKit
import ReviewQueueCore
import SwiftUI

/// Screenshot mode (`--screenshots <shot>`): one screen on demo data in an ordinary on-screen window, since glass only
/// renders in live windows, captured by `scripts/screenshots.sh` with `screencapture -l`. The app is made a regular,
/// active app and the window key, because glass drops its tints in inactive windows; activation is retried since macOS
/// may refuse it while another app is frontmost. Once layout settles, prints the window number on its own line and waits
/// to be terminated. `--screenshots list` prints every shot name, one per line, so the script never keeps its own list.
@MainActor
enum ScreenshotStage {
    enum Shot: String, CaseIterable {
        case reviewQueue = "review-queue"
        case myPrs = "my-prs"
        case settingsReviewQueue = "settings-review-queue"
        case settingsMyPrs = "settings-my-prs"
        case settingsGeneral = "settings-general"

        var settingsTab: SettingsTab? {
            switch self {
            case .reviewQueue, .myPrs: nil
            case .settingsReviewQueue: .reviewQueue
            case .settingsMyPrs: .myPrs
            case .settingsGeneral: .general
            }
        }
    }

    static let shot: Shot? = {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--screenshots"), arguments.indices.contains(flag + 1) else { return nil }
        return Shot(rawValue: arguments[flag + 1])
    }()

    static let isEnabled = CommandLine.arguments.contains("--screenshots")

    private static var window: NSWindow?

    static func start(_ model: AppModel) {
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { present(model) }
        }
    }

    private static func present(_ model: AppModel) {
        let names = Shot.allCases.map(\.rawValue)
        if CommandLine.arguments.last == "list" {
            print(names.joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        guard let shot else {
            FileHandle.standardError.write(Data("usage: ReviewQueue --screenshots list|\(names.joined(separator: "|"))\n".utf8))
            NSApp.terminate(nil)
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        switch shot {
        case .reviewQueue: window = panel(MenuView(model: model))
        case .myPrs: window = panel(MyPrsMenuView(model: model))
        case .settingsReviewQueue, .settingsMyPrs, .settingsGeneral:
            model.settingsTab = shot.settingsTab ?? .reviewQueue
            window = invisibleWindow(SettingsOpener())
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if shot.settingsTab != nil {
                window = NSApp.windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(nil)
                if let window {
                    placeOnSharpestScreen(window)
                    growToFitScrolledContent(window)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let window else { return }
            var attempts = 0
            while !NSApp.isActive || !window.isKeyWindow, attempts < 20 {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                attempts += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard NSApp.isActive, window.isKeyWindow else {
                FileHandle.standardError.write(Data("could not become the active app; another app kept focus\n".utf8))
                exit(1)
            }
            FileHandle.standardOutput.write(Data("\(window.windowNumber)\n".utf8))
        }
    }

    /// Makes `window` tall enough that its tallest scroll view shows everything, keeping the top edge in place. The frame
    /// is set directly, so it may run past the bottom of the screen; `screencapture -l` still captures all of it.
    private static func growToFitScrolledContent(_ window: NSWindow) {
        guard let scroll = scrollViews(in: window.contentView).max(by: { overflow($0) < overflow($1) }) else { return }
        let extra = overflow(scroll)
        guard extra > 0 else { return }
        var frame = window.frame
        frame.origin.y -= extra
        frame.size.height += extra
        window.setFrame(frame, display: true)
    }

    private static func overflow(_ scroll: NSScrollView) -> CGFloat {
        let insets = scroll.contentInsets.top + scroll.contentInsets.bottom
        return (scroll.documentView?.frame.height ?? 0) + insets - scroll.contentSize.height
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
    }

    private static func panel(_ content: some View) -> NSWindow {
        let window = hostingWindow(ScreenshotBackdrop { content })
        placeOnSharpestScreen(window)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Moves `window` to the top-left of the screen with the highest backing scale. `screencapture -l` captures at the
    /// scale of the screen the window is on, and `NSScreen.main` is whichever screen holds the focused window, so
    /// without this a run started from a non-Retina display writes a 1x set.
    private static func placeOnSharpestScreen(_ window: NSWindow) {
        let screen = (NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main)?.visibleFrame ?? .zero
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX + 40, y: screen.maxY - 40))
    }

    private static func invisibleWindow(_ content: some View) -> NSWindow {
        let window = hostingWindow(content)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }

    private static func hostingWindow(_ content: some View) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let window = KeyableWindow(contentViewController: controller)
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        return window
    }
}

/// A borderless window that can still be key, so its controls draw active.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// A menu panel as the menu bar shows it, a glass sheet, over a dark gradient for the glass to pick up.
private struct ScreenshotBackdrop<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22)) }
            .padding(36)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.12, blue: 0.30), Color(red: 0.28, green: 0.12, blue: 0.36), Color(red: 0.05, green: 0.25, blue: 0.30)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

/// Opens the Settings scene once it appears, since only a SwiftUI view can reach `openSettings`.
private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.frame(width: 1, height: 1).onAppear { openSettings() }
    }
}
