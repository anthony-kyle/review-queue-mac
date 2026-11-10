import AppKit
import Observation
import ReviewQueueCore
import ServiceManagement

enum SettingsTab: Hashable {
    case reviewQueue, myPrs, general
}

/// The review queue, your own open PRs, the person's settings and everything that refreshes them: the interval timer,
/// wake from sleep and stale data on menu open. Each refresh fetches both lists, failing independently, and works out
/// and posts both sets of notifications. A demo model (`init(demo:)`) holds fixtures in memory and never touches the
/// network, disk, Keychain, login items or notifications.
@MainActor
@Observable
final class AppModel {
    static let pageRows = 10

    private(set) var settings: QueueSettings
    private(set) var prs: [QueuePr] = []
    private(set) var dismissals: Dismissals
    private(set) var people: [String] = []
    private(set) var availableTeams: [String] = []
    private(set) var linearWorkspace: String?
    private(set) var fetchedAt: Date?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var linearError: String?
    private(set) var isLinearSignedIn: Bool
    private(set) var isSigningInToLinear = false
    private(set) var linearSignInError: String?
    private(set) var isLaunchAtLogin: Bool
    private(set) var launchAtLoginError: String?
    private(set) var myAllPrs: [MyPr] = []
    private(set) var me: String?
    private(set) var myDismissals: Dismissals
    private(set) var acknowledged: Set<String>
    private(set) var myFetchedAt: Date?
    private(set) var myError: String?
    var expanded = Set(Block.allCases.filter(\.isOpenByDefault))
    var shownRows: [Block: Int] = [:]
    var rowExpansion = RowExpansion()
    var myExpanded = Set(MyBlock.allCases.filter(\.isOpenByDefault))
    var myShownRows: [MyBlock: Int] = [:]
    var myRowExpansion = RowExpansion()
    var settingsTab = SettingsTab.reviewQueue

    @ObservationIgnored private let github = GitHubClient()
    @ObservationIgnored private let store: JSONStore?
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let sound = AlertSound()
    @ObservationIgnored private let linearTokens = LinearTokenProvider(oauth: LinearOAuth(), storage: Keychain.linearTokenStorage)
    @ObservationIgnored private var linear: LinearMCPClient?
    @ObservationIgnored private var linearSignIn: Task<Void, Never>?
    @ObservationIgnored private var alertState: AlertState?
    @ObservationIgnored private var myAlertState: MyAlertState?
    @ObservationIgnored private var isAcknowledgedBaselined: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init() {
        let store = JSONStore()
        self.store = store
        settings = store.load(QueueSettings.self, from: JSONStore.settings) ?? QueueSettings()
        alertState = store.load(AlertState.self, from: JSONStore.alertState)
        dismissals = store.load(Dismissals.self, from: JSONStore.dismissals) ?? [:]
        myAlertState = store.load(MyAlertState.self, from: JSONStore.myAlertState)
        myDismissals = store.load(Dismissals.self, from: JSONStore.myDismissals) ?? [:]
        let savedAcknowledged = store.load(Set<String>.self, from: JSONStore.myAcknowledged)
        acknowledged = savedAcknowledged ?? []
        isAcknowledgedBaselined = savedAcknowledged != nil
        Keychain.delete(Keychain.legacyLinearKeyAccount)
        isLinearSignedIn = Keychain.read(Keychain.linearOAuthAccount) != nil
        isLaunchAtLogin = SMAppService.mainApp.status == .enabled
        if Bundle.main.bundleIdentifier != nil { notifier.setUp() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        schedule()
        Task { await refresh() }
    }

    /// Screenshot mode's model: `demo`'s PRs and settings as if just fetched, with the second card of High priority and
    /// Needs you closed so both row styles show and each menu fits without scrolling. Nothing is loaded, saved or
    /// refreshed.
    init(demo: DemoData) {
        store = nil
        settings = demo.settings
        dismissals = [:]
        myDismissals = [:]
        acknowledged = []
        isAcknowledgedBaselined = true
        isLinearSignedIn = true
        isLaunchAtLogin = true
        prs = demo.prs
        people = demo.people
        availableTeams = demo.teams
        linearWorkspace = DemoData.linearWorkspace
        fetchedAt = demo.fetchedAt
        me = DemoData.me
        myAllPrs = demo.myPrs
        myFetchedAt = demo.fetchedAt
        notificationPermission = "Allowed"
        if let first = lists[.high]?.shown.first { rowExpansion.toggle(first.key, in: Block.high.rawValue) }
        if let second = myLists[.needsYou]?.shown.dropFirst().first { myRowExpansion.toggle(second.key, in: MyBlock.needsYou.rawValue) }
    }

    var lists: [Block: BlockList<QueuePr>] { blockLists(prs, settings, dismissals: dismissals) }

    /// Your open PRs minus excluded orgs and repos.
    var myPrs: [MyPr] { withoutExcluded(myAllPrs, settings.myPrs) }

    var myContext: MyPrsContext { MyPrsContext(me: me ?? "", settings: settings.myPrs, acknowledged: acknowledged) }

    var myLists: [MyBlock: BlockList<MyPr>] { myBlockLists(myPrs, myContext, dismissals: myDismissals) }

    /// Orgs and `owner/name` repos in the latest My PRs results, for the exclusion pickers.
    var mySeenOrgs: [String] { Set(myAllPrs.map(\.owner)).sorted() }
    var mySeenRepos: [String] { Set(myAllPrs.map { "\($0.owner)/\($0.repo)" }).sorted() }

    /// Hides a PR until it next changes and silences its notifications meanwhile.
    func markDone(_ pr: QueuePr) {
        saveDismissals(dismissals.merging([pr.key: pr.updatedAt]) { $1 })
        notifier.withdraw(pr.key)
    }

    func restore(_ prs: [QueuePr]) {
        saveDismissals(dismissals.filter { key, _ in !prs.contains { $0.key == key } })
    }

    /// Hides one of your PRs until it next changes and acknowledges every comment it has now.
    func markDone(_ pr: MyPr) {
        saveMyDismissals(myDismissals.merging([pr.key: pr.updatedAt]) { $1 })
        acknowledge(pr.comments.map(\.id))
    }

    func restore(_ prs: [MyPr]) {
        saveMyDismissals(myDismissals.filter { key, _ in !prs.contains { $0.key == key } })
    }

    func acknowledge(_ commentIds: [String]) {
        saveAcknowledged(acknowledged.union(commentIds))
    }

    /// The commenter most recently ignored from a card, offered back with Undo until the next refresh.
    private(set) var lastIgnored: String?

    func ignoreCommenter(_ login: String) {
        update { $0.myPrs.setIgnored(login, isOn: true) }
        lastIgnored = login
    }

    func undoIgnore() {
        guard let login = lastIgnored else { return }
        update { $0.myPrs.setIgnored(login, isOn: false) }
        lastIgnored = nil
    }

    private func saveDismissals(_ next: Dismissals) {
        dismissals = next
        store?.save(next, to: JSONStore.dismissals)
    }

    private func saveMyDismissals(_ next: Dismissals) {
        myDismissals = next
        store?.save(next, to: JSONStore.myDismissals)
    }

    private func saveAcknowledged(_ next: Set<String>) {
        acknowledged = next
        isAcknowledgedBaselined = true
        store?.save(next, to: JSONStore.myAcknowledged)
    }

    var storyWorkspace: String? {
        linearWorkspace ?? (settings.linearWorkspace.isEmpty ? nil : settings.linearWorkspace)
    }

    /// Applies a settings change, saves it, and reschedules the timer. `refreshAfter` is for changes that alter which
    /// PRs are fetched (teams, repo access, Linear workspace).
    func update(refreshAfter: Bool = false, _ change: (inout QueueSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let isIntervalChanged = next.intervalMinutes != settings.intervalMinutes
        settings = next
        store?.save(next, to: JSONStore.settings)
        if isIntervalChanged { schedule() }
        if refreshAfter { Task { await refresh() } }
    }

    /// Runs "Sign in with Linear" in the browser, then refreshes so review links appear straight away.
    func signInToLinear() {
        guard !isSigningInToLinear else { return }
        isSigningInToLinear = true
        linearSignInError = nil
        linearSignIn = Task {
            defer {
                isSigningInToLinear = false
                linearSignIn = nil
            }
            do {
                let tokens = try await LinearOAuth().signIn { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
                await linearTokens.replace(with: tokens)
                isLinearSignedIn = true
                linear = nil
                Task { await refresh() }
            } catch is CancellationError {
                return
            } catch {
                linearSignInError = error.localizedDescription
            }
        }
    }

    func cancelLinearSignIn() {
        linearSignIn?.cancel()
    }

    func signOutOfLinear() {
        isLinearSignedIn = false
        linear = nil
        linearError = nil
        Task {
            await linearTokens.signOut()
            await refresh()
        }
    }

    func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        isLaunchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private(set) var notificationPermission = "Checking…"

    func checkNotificationPermission() {
        guard store != nil else { return }
        Task { notificationPermission = await notifier.permission() }
    }

    /// Posts a sample High priority alert, with the loud sound, so the whole path can be checked by hand.
    func testNotification() {
        post([PrAlert.sample])
        checkNotificationPermission()
    }

    func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleId)")
    }

    func testSound() {
        sound.playLoud(settings.highSound)
    }

    func testNormalSound() {
        sound.playNormal(settings.normalSound)
    }

    func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshIfStale() {
        let oldest = [fetchedAt, myFetchedAt].map { $0 ?? .distantPast }.min() ?? .distantPast
        if Date().timeIntervalSince(oldest) > Double(settings.intervalMinutes * 60) { Task { await refresh() } }
    }

    func loadTeamsIfNeeded() {
        guard availableTeams.isEmpty else { return }
        Task { availableTeams = (try? await github.listMyTeams()) ?? [] }
    }

    /// Fetches the review queue and your own PRs, then resolves Linear review links for both in one pass so the shared
    /// cache isn't pruned by either list alone. A list that fails keeps its previous PRs and shows its own error.
    func refresh() async {
        guard let store, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let current = settings
        let queue: Result<(FetchResult, [String]), any Error>
        do {
            let teams = try await github.listMyTeams()
            let result = current.teams.isEmpty ? FetchResult.empty : try await github.fetchQueue(teams: current.teams, access: current.repoAccess)
            queue = .success((result, teams))
        } catch {
            queue = .failure(error)
        }
        let mine: Result<MyPrsResult, any Error>
        do {
            mine = .success(try await github.fetchMyPrs())
        } catch {
            mine = .failure(error)
        }

        var fetched = (try? queue.get())?.0.prs ?? prs
        var fetchedMine = (try? mine.get())?.prs ?? myAllPrs
        let isAnyFetched = (try? queue.get()) != nil || (try? mine.get()) != nil
        let refs = fetched.map(LinearPrRef.init) + fetchedMine.map(LinearPrRef.init)
        var workspace: String?
        var linearFailure: String?
        if isAnyFetched, !refs.isEmpty, let client = linearClient() {
            do {
                let (found, cache) = try await resolveLinearReviewUrls(
                    prs: refs,
                    cache: store.load(LinearCache.self, from: JSONStore.linearCache) ?? LinearCache(),
                    now: Date(),
                    listDiffs: { try await client.listDiffs($0) }
                )
                store.save(cache, to: JSONStore.linearCache)
                workspace = found.workspace
                fetched = withLinearReviewUrls(fetched, found.urls)
                fetchedMine = withLinearReviewUrls(fetchedMine, found.urls)
            } catch {
                linearFailure = error.localizedDescription
            }
        }
        var closures: [String: PrClosure] = [:]
        if case .success = mine {
            let vanished = vanishedPrs(previous: myAlertState, prs: withoutExcluded(fetchedMine, settings.myPrs))
            if !vanished.isEmpty { closures = (try? await github.fetchClosures(nodeIds: vanished.map(\.nodeId))) ?? [:] }
        }
        if isAnyFetched {
            isLinearSignedIn = await linearTokens.isSignedIn
            linearWorkspace = workspace
            linearError = linearFailure
        }

        switch queue {
        case let .success((result, teams)):
            prs = fetched
            saveDismissals(prunedDismissals(dismissals, prs: fetched))
            people = result.people
            availableTeams = teams
            error = nil
            fetchedAt = Date()
            lastIgnored = nil
            if !current.teams.isEmpty { announce(fetched.filter { !isDismissed($0, dismissals) }) }
        case let .failure(failure):
            error = failure.localizedDescription
        }
        switch mine {
        case let .success(result):
            me = result.me
            myAllPrs = fetchedMine
            saveMyDismissals(prunedDismissals(myDismissals, prs: fetchedMine))
            let commentIds = Set(fetchedMine.flatMap { $0.comments.map(\.id) })
            saveAcknowledged(isAcknowledgedBaselined ? acknowledged.intersection(commentIds) : commentIds)
            myError = nil
            myFetchedAt = Date()
            announceMine(closures: closures)
        case let .failure(failure):
            myError = failure.localizedDescription
        }
    }

    private func linearClient() -> LinearMCPClient? {
        guard isLinearSignedIn else { return nil }
        if let linear { return linear }
        let tokens = linearTokens
        let client = LinearMCPClient { try await tokens.accessToken(rejected: $0) }
        linear = client
        return client
    }

    private func announce(_ prs: [QueuePr]) {
        let evaluation = evaluateAlerts(previous: alertState, prs: prs, settings: settings)
        alertState = evaluation.state
        store?.save(evaluation.state, to: JSONStore.alertState)
        post(evaluation.alerts)
    }

    private func announceMine(closures: [String: PrClosure]) {
        let evaluation = evaluateMyAlerts(previous: myAlertState, prs: myPrs, closures: closures, context: myContext, dismissals: myDismissals)
        myAlertState = evaluation.state
        store?.save(evaluation.state, to: JSONStore.myAlertState)
        post(evaluation.alerts)
    }

    private func post(_ alerts: [PrAlert]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notifier.post(alerts)
        if alerts.contains(where: { $0.kind == .high }) {
            sound.playLoud(settings.highSound)
        } else if !alerts.isEmpty {
            sound.playNormal(settings.normalSound)
        }
    }

    private func schedule() {
        timer?.cancel()
        let interval = Duration.seconds(settings.intervalMinutes * 60)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}
