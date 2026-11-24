import Foundation
import Testing
@testable import ReviewQueueCore

@Suite struct AllowedBotTests {
    private let karbi = Author(login: "karbi-github", typename: "Bot")
    private let renovate = Author(login: "renovate", typename: "Bot")
    private let human = Author(login: "alice")

    private func settings(_ bots: [String]) -> QueueSettings {
        var settings = QueueSettings()
        settings.allowedBotAuthors = bots
        return settings
    }

    @Test func matchesPlainLoginBotSuffixAndCase() {
        #expect(isAllowedBot(karbi, settings(["karbi-github"])))
        #expect(isAllowedBot(karbi, settings(["Karbi-GitHub[bot]"])))
        #expect(isAllowedBot(Author(login: "Karbi-GitHub[bot]", typename: "Bot"), settings(["karbi-github"])))
        #expect(isAllowedBot(karbi, settings([" karbi-github "])))
    }

    @Test func doesNotMatchOtherLoginsOrNilAuthor() {
        #expect(!isAllowedBot(renovate, settings(["karbi-github"])))
        #expect(!isAllowedBot(karbi, settings([])))
        #expect(!isAllowedBot(nil, settings(["karbi-github"])))
    }

    @Test func queueKeepsHumansAndAllowedBotsOnly() {
        let allowed = settings(["karbi-github"])
        #expect(isQueueAuthor(human, me: "me", allowed))
        #expect(isQueueAuthor(karbi, me: "me", allowed))
        #expect(!isQueueAuthor(renovate, me: "me", allowed))
        #expect(!isQueueAuthor(karbi, me: "me", settings([])))
        #expect(!isQueueAuthor(nil, me: "me", allowed))
    }

    @Test func queueDropsYourOwnPrsEvenWhenAllowed() {
        #expect(!isQueueAuthor(Author(login: "me"), me: "me", settings(["me"])))
        #expect(!isQueueAuthor(Author(login: "me", typename: "Bot"), me: "me", settings(["me"])))
    }

    @Test func settingTogglesWithoutDuplicatesAcrossSpellings() {
        var value = QueueSettings()
        value.setAllowedBotAuthor("  karbi-github ", isOn: true)
        value.setAllowedBotAuthor("Karbi-GitHub[bot]", isOn: true)
        value.setAllowedBotAuthor("   ", isOn: true)
        #expect(value.allowedBotAuthors == ["karbi-github"])
        value.setAllowedBotAuthor("KARBI-GITHUB[bot]", isOn: false)
        #expect(value.allowedBotAuthors.isEmpty)
    }

    @Test func settingsDecodeWithoutTheKeyDefaultsToEmpty() throws {
        let old = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"teams":["acme/team-eng"]}"#.utf8))
        #expect(old.allowedBotAuthors.isEmpty)
        let saved = try JSONDecoder().decode(QueueSettings.self, from: Data(#"{"allowedBotAuthors":["release-bot"]}"#.utf8))
        #expect(saved.allowedBotAuthors == ["release-bot"])
    }
}
