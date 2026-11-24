import Foundation

/// A Linear team, as the sprint team picker lists and Settings stores it.
public struct LinearTeam: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let key: String
    public let name: String

    public init(id: String, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
    }

    public var label: String { "\(name) (\(key))" }
}

/// One of a team's Linear cycles, from its start up to (not including) its end.
public struct LinearCycle: Codable, Equatable, Sendable {
    public let id: String
    public let number: Int
    public let name: String?
    public let startsAt: Date
    public let endsAt: Date

    public init(id: String, number: Int, name: String? = nil, startsAt: Date, endsAt: Date) {
        self.id = id
        self.number = number
        self.name = name
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    public var interval: DateInterval { DateInterval(start: startsAt, end: max(startsAt, endsAt)) }

    /// The cycle's name when it has one, otherwise `Cycle <number>`.
    public var title: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "Cycle \(number)" }
        return name
    }
}

/// One page of `list_teams`.
struct TeamPage: Decodable, Sendable {
    let teams: [LinearTeam]
    var hasNextPage: Bool?
    var cursor: String?
}

private struct CycleJSON: Decodable {
    let id: String
    let number: Int
    var name: String?
    let startsAt: String
    let endsAt: String
}

private struct CycleList: Decodable {
    let cycles: [CycleJSON]
}

/// The cycles in a `list_cycles` reply, which is a bare JSON array (or, tolerated, an object with `cycles`). Cycles whose
/// dates don't parse are dropped; Linear sends fractional seconds, which `isoDate` alone rejects.
func cyclesOf(_ text: String) throws -> [LinearCycle] {
    let data = Data(text.utf8)
    let decoded: [CycleJSON]
    if let list = try? JSONDecoder().decode([CycleJSON].self, from: data) {
        decoded = list
    } else {
        decoded = try JSONDecoder().decode(CycleList.self, from: data).cycles
    }
    return decoded.compactMap { cycle in
        guard let start = linearDate(cycle.startsAt), let end = linearDate(cycle.endsAt) else { return nil }
        return LinearCycle(id: cycle.id, number: cycle.number, name: cycle.name, startsAt: start, endsAt: end)
    }
}

func linearDate(_ text: String) -> Date? {
    isoDate(text) ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
}

/// The cycle running at `now`, if any.
public func currentCycle(_ cycles: [LinearCycle], now: Date) -> LinearCycle? {
    cycles.first { $0.interval.holds(now) }
}

/// The cycles Sprint can show, oldest first: started by `now` and not before `start`, the first day of kept history.
public func reachableCycles(_ cycles: [LinearCycle], now: Date, start: Date) -> [LinearCycle] {
    cycles.filter { $0.startsAt <= now && $0.startsAt >= start }.sorted { $0.startsAt < $1.startsAt }
}

/// The period the statistics window opens on: Sprint when it is offered and the team has a cycle running now, else
/// Month.
public func defaultPeriod(isSprintOffered: Bool, cycles: [LinearCycle], now: Date) -> StatsPeriod {
    isSprintOffered && currentCycle(cycles, now: now) != nil ? .sprint : .month
}
