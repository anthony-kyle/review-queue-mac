import Foundation

public extension TrackedPr {
    /// This PR with failing checks from `sources` moved to `ignoredChecks`, so they stop counting. When that leaves no
    /// failing check, a rollup GitHub marks failing reads as running while anything is pending and passing otherwise.
    /// Sources match without case.
    func ignoringCi(_ sources: [String]) -> Self {
        let ignored = Set(sources.map { $0.lowercased() })
        let (hidden, failing) = failingChecks.reduce(into: ([FailedCheck](), [FailedCheck]())) { split, check in
            if ignored.contains(check.source.lowercased()) { split.0.append(check) } else { split.1.append(check) }
        }
        guard !hidden.isEmpty else { return self }
        var copy = self
        copy.failingChecks = failing
        copy.ignoredChecks = hidden
        if failing.isEmpty, isCiFailing(ci) { copy.ci = pendingChecks.isEmpty ? "SUCCESS" : "PENDING" }
        return copy
    }
}
