import AppKit

/// Alert sounds played by the app itself, so they don't depend on the notification sound setting or Focus: the loud
/// High priority sound three times at full volume, the normal one once and softer. Volume is relative to the system
/// output volume, which the app cannot raise.
@MainActor
final class AlertSound {
    private static let directory = URL(filePath: "/System/Library/Sounds")

    private var playback: Task<Void, Never>?

    static var available: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    func playLoud(_ name: String) {
        play(name, times: 3, volume: 1.0)
    }

    func playNormal(_ name: String) {
        play(name, times: 1, volume: 0.6)
    }

    private func play(_ name: String, times: Int, volume: Float) {
        playback?.cancel()
        let url = Self.directory.appending(path: "\(name).aiff")
        playback = Task {
            for _ in 0..<times {
                guard !Task.isCancelled, let sound = NSSound(contentsOf: url, byReference: true) else { return }
                sound.volume = volume
                sound.play()
                try? await Task.sleep(for: .seconds(sound.duration))
            }
        }
    }
}
