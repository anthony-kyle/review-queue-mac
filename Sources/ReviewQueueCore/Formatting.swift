import Foundation

private let maxCheckNames = 3

/// Compact age of an ISO time relative to `now`, for tight columns: `now`, `12m`, `5h`, `3d`, `6w`. Empty when `iso`
/// doesn't parse.
public func compactAge(_ iso: String, now: Date) -> String {
    guard let date = try? Date(iso, strategy: .iso8601) else { return "" }
    let minutes = max(0, Int((now.timeIntervalSince(date) / 60).rounded(.down)))
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    return days < 14 ? "\(days)d" : "\(days / 7)w"
}

/// Coarse human age of an ISO time relative to `now`: `just now`, `12m ago`, `5h ago`, `3d ago`, `6w ago`.
public func timeAgo(_ iso: String, now: Date) -> String {
    switch compactAge(iso, now: now) {
    case "": ""
    case "now": "just now"
    case let age: "\(age) ago"
    }
}

public enum Tone: Equatable, Sendable {
    case success, error, warning, info, subtle
}

public func ciMark(_ state: String?) -> (text: String, tone: Tone) {
    switch state {
    case "SUCCESS": ("Passing ✓", .success)
    case "FAILURE", "ERROR": ("Failing ✗", .error)
    case "PENDING", "EXPECTED": ("Running …", .warning)
    default: ("None", .subtle)
    }
}

public func isCiFailing(_ state: String?) -> Bool {
    ciMark(state).tone == .error
}

/// The first three names, then `+N more`.
public func nameList(_ names: [String]) -> String {
    let shown = names.prefix(maxCheckNames).joined(separator: ", ")
    return names.count > maxCheckNames ? "\(shown) +\(names.count - maxCheckNames) more" : shown
}

public func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}

/// Text squeezed onto one line and cut to `limit` characters with an ellipsis.
public func snippet(_ text: String, limit: Int = 140) -> String {
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
}
