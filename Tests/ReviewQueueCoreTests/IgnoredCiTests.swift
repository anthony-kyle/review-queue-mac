import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct IgnoredCiTests {
    private let vercel = FailedCheck(name: "Vercel – app-close", source: "vercel")
    private let test = FailedCheck(name: "test", source: "CI")

    @Test func ignoredSourceMovesOutAndFlipsRollupToPassing() {
        let pr = makeMyPr(1, ci: "FAILURE", failingChecks: [vercel]).ignoringCi(["Vercel"])
        #expect(pr.failingChecks.isEmpty)
        #expect(pr.ignoredChecks == [vercel])
        #expect(pr.ci == "SUCCESS")
        #expect(!isCiFailing(pr.ci))
    }

    @Test func rollupReadsRunningWhileChecksArePending() {
        let pr = makeMyPr(1, ci: "FAILURE", failingChecks: [vercel], pendingChecks: ["build"]).ignoringCi(["vercel"])
        #expect(pr.ci == "PENDING")
    }

    @Test func otherFailuresKeepTheRollupFailing() {
        let pr = makeMyPr(1, ci: "FAILURE", failingChecks: [vercel, test]).ignoringCi(["vercel"])
        #expect(pr.failingChecks == [test])
        #expect(pr.ignoredChecks == [vercel])
        #expect(pr.ci == "FAILURE")
    }

    @Test func noMatchLeavesThePrUntouched() {
        let pr = makeMyPr(1, ci: "FAILURE", failingChecks: [test])
        #expect(pr.ignoringCi(["vercel"]) == pr)
        #expect(pr.ignoringCi([]) == pr)
    }

    @Test func queuePrsAreIgnoredToo() {
        var pr = makePr(1)
        pr.ci = "FAILURE"
        pr.failingChecks = [vercel]
        let adjusted = pr.ignoringCi(["VERCEL"])
        #expect(queueSignal(adjusted) == nil)
        #expect(queueSignal(pr)?.text == "CI failing")
    }

    @Test func myPrSignalAndReasonStopFlaggingCi() {
        let pr = makeMyPr(1, ci: "FAILURE", failingChecks: [vercel])
        let adjusted = pr.ignoringCi(["vercel"])
        #expect(mySignal(pr, myContext())?.text == "CI failing")
        #expect(mySignal(adjusted, myContext()) == nil)
        #expect(myReasonOf(adjusted, myContext()) == nil)
    }

    @Test func alertsDoNotFireWhenOnlyIgnoredChecksFail() {
        let passing = makeMyPr(1, ci: "SUCCESS")
        let failing = makeMyPr(1, ci: "FAILURE", failingChecks: [vercel])
        let context = myContext()
        let baseline = evaluateMyAlerts(previous: nil, prs: [passing], closures: [:], context: context, dismissals: [:])
        let ignored = evaluateMyAlerts(previous: baseline.state, prs: [failing.ignoringCi(["vercel"])], closures: [:], context: context, dismissals: [:])
        #expect(ignored.alerts.isEmpty)
        let shown = evaluateMyAlerts(previous: baseline.state, prs: [failing], closures: [:], context: context, dismissals: [:])
        #expect(shown.alerts.map(\.subtitle) == ["CI failing"])
    }

    @Test func settingsIgnoreSourcesWithoutCaseDuplicatesOrBlanks() {
        var settings = QueueSettings()
        settings.setIgnoredCiSource("  vercel ", isOn: true)
        settings.setIgnoredCiSource("Vercel", isOn: true)
        settings.setIgnoredCiSource("   ", isOn: true)
        #expect(settings.ignoredCiSources == ["vercel"])
        settings.setIgnoredCiSource("VERCEL", isOn: false)
        #expect(settings.ignoredCiSources.isEmpty)
    }

    @Test func settingsDecodeWithoutIgnoredSources() throws {
        let old = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"teams":["acme/team-eng"]}"#.utf8))
        #expect(old.ignoredCiSources.isEmpty)
        let saved = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"ignoredCiSources":["vercel"]}"#.utf8))
        #expect(saved.ignoredCiSources == ["vercel"])
    }
}
