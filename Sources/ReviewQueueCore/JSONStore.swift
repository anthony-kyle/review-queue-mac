import Foundation

/// Small JSON files under Application Support, one per value.
public struct JSONStore: Sendable {
    public static let settings = "settings.json"
    public static let alertState = "alert-state.json"
    public static let linearCache = "linear-cache.json"
    public static let linearOAuthClient = "linear-oauth-client.json"
    public static let dismissals = "dismissals.json"
    public static let myAlertState = "my-alert-state.json"
    public static let myDismissals = "my-dismissals.json"
    public static let myAcknowledged = "my-acknowledged.json"

    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? URL.applicationSupportDirectory.appending(path: AppIdentity.bundleId, directoryHint: .isDirectory)
    }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: name), options: .atomic)
    }
}
