import ReviewQueueCore
import SwiftUI

/// The settings window in three tabs: the review queue's own choices, My PRs, and General for what both menus share
/// (Linear, refresh, card details, sound, launch at login). Each menu's Settings button opens its own tab.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ReviewQueueSettings(model: model)
                .tabItem { Label("Review queue", systemImage: "tray.full") }
                .tag(SettingsTab.reviewQueue)
            MyPrsSettingsView(model: model)
                .tabItem { Label("My PRs", systemImage: "person.crop.circle") }
                .tag(SettingsTab.myPrs)
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 540, height: 700)
        .onAppear { model.loadTeamsIfNeeded() }
    }
}

/// Teams, repo access, per-block prefs and the review queue's notification rules.
private struct ReviewQueueSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            teams
            ForEach(Block.allCases) { block in
                BlockSettings(model: model, block: block)
            }
            Section("Notifications") {
                Toggle("High priority alerts", isOn: settingsBinding(model, \.notifyHigh))
                Toggle("Repeat High priority reminders every refresh", isOn: settingsBinding(model, \.repeatHighReminders))
                    .disabled(!model.settings.notifyHigh)
                Toggle("New in Needs review", isOn: settingsBinding(model, \.notifyNeeds))
                Toggle("Review requested from you", isOn: settingsBinding(model, \.notifyReviewRequested))
            }
        }
        .formStyle(.grouped)
    }

    private var teams: some View {
        Section {
            if model.settings.teams.isEmpty {
                Text("No team chosen yet.").foregroundStyle(.secondary)
            }
            ForEach(model.settings.teams, id: \.self) { team in
                RemovableRow(name: team) { model.update(refreshAfter: true) { $0.setTeam(team, isOn: false) } }
            }
            AddPicker(title: "Add team", options: model.availableTeams.filter { !model.settings.teams.contains($0) }) { team in
                model.update(refreshAfter: true) { $0.setTeam(team, isOn: true) }
            }
            Picker("Which team repos", selection: settingsBinding(model, \.repoAccess, refreshAfter: true)) {
                ForEach(RepoAccess.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Teams")
        } footer: {
            Text("Open PRs in these GitHub teams' repos make up the queue.")
        }
    }
}

/// Linear sign-in and workspace, the shared refresh interval, card details, the loud sound and launch at login.
private struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            linear
            Section("Refresh") {
                Picker("Refresh every", selection: settingsBinding(model, \.intervalMinutes)) {
                    ForEach(QueueSettings.intervals, id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
            cardDetails
            Section {
                HStack {
                    Picker("Loud alert sound", selection: settingsBinding(model, \.highSound)) {
                        ForEach(AlertSound.available, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Test") { model.testSound() }
                }
                HStack {
                    Picker("Normal alert sound", selection: settingsBinding(model, \.normalSound)) {
                        ForEach(AlertSound.available, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Test") { model.testNormalSound() }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Loud plays three times for High priority alerts and changes requested on your PRs. Normal plays once for everything else.")
            }
            Section("Notifications") {
                LabeledContent("Permission", value: model.notificationPermission)
                HStack {
                    Button("Send test notification") { model.testNotification() }
                    Button("Open Notification Settings") { model.openNotificationSettings() }
                }
            }
            .onAppear { model.checkNotificationPermission() }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.isLaunchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let error = model.launchAtLoginError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var cardDetails: some View {
        Section {
            ForEach(CardDetail.allCases) { detail in
                Toggle(detail.label, isOn: Binding(
                    get: { model.settings.shows(detail) },
                    set: { isShown in model.update { $0.setDetail(detail, isShown: isShown) } }
                ))
            }
        } header: {
            Text("Card details")
        } footer: {
            Text("Choose which lines each card shows, in both menus. Pin / mute buttons only appear in the review queue.")
        }
    }

    private var linear: some View {
        Section {
            HStack {
                Text(model.isLinearSignedIn ? "Signed in to Linear" : "Not signed in")
                    .foregroundStyle(model.isLinearSignedIn ? .primary : .secondary)
                Spacer()
                if model.isSigningInToLinear {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelLinearSignIn() }
                } else if model.isLinearSignedIn {
                    Button("Sign out") { model.signOutOfLinear() }
                } else {
                    Button("Sign in with Linear") { model.signInToLinear() }
                }
            }
            if let error = model.linearSignInError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            TextField("Workspace slug", text: settingsBinding(model, \.linearWorkspace), prompt: Text("e.g. acme"))
        } header: {
            Text("Linear")
        } footer: {
            Text("Signing in lets the app find each PR's Linear review through Linear's MCP server; sign-in finishes in your browser. The workspace slug links story ids when no review URL has revealed it; leave blank to show stories as plain text.")
        }
    }
}

/// A block's sort order, approved-by-others and changes-requested-by-others inclusions and, for High and Low priority,
/// whose PRs always land there.
private struct BlockSettings: View {
    let model: AppModel
    let block: Block

    var body: some View {
        let prefs = blockPrefsOf(model.settings, block)
        Section(block.label) {
            Picker("Sort order", selection: Binding(get: { prefs.sort }, set: { sort in save { $0.sort = sort } })) {
                ForEach(BlockSort.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Include PRs approved by others", isOn: Binding(
                get: { prefs.isOthersApprovedShown },
                set: { isShown in save { $0.isOthersApprovedShown = isShown } }
            ))
            Toggle("Include PRs with changes requested by others", isOn: Binding(
                get: { prefs.isOthersChangesRequestedShown },
                set: { isShown in save { $0.isOthersChangesRequestedShown = isShown } }
            ))
            if let list = block.peopleList {
                people(list)
            }
        }
    }

    @ViewBuilder
    private func people(_ list: PeopleList) -> some View {
        let chosen = model.settings.people(list)
        if chosen.isEmpty {
            Text("Nobody yet.").foregroundStyle(.secondary)
        }
        ForEach(chosen, id: \.self) { login in
            RemovableRow(name: login) { model.update { $0.setPerson(login, in: list, isOn: false) } }
        }
        let addable = model.people.filter { !model.settings.highUsers.contains($0) && !model.settings.lowUsers.contains($0) }
        AddPicker(title: "Add person", options: addable) { login in
            model.update { $0.setPerson(login, in: list, isOn: true) }
        }
    }

    private func save(_ change: @escaping (inout BlockPrefs) -> Void) {
        model.update { settings in
            var prefs = blockPrefsOf(settings, block)
            change(&prefs)
            settings.blockPrefs[block] = prefs
        }
    }
}

/// A two-way binding to one setting that saves through `AppModel.update`.
@MainActor
func settingsBinding<T>(_ model: AppModel, _ keyPath: WritableKeyPath<QueueSettings, T>, refreshAfter: Bool = false) -> Binding<T> {
    Binding(
        get: { model.settings[keyPath: keyPath] },
        set: { value in model.update(refreshAfter: refreshAfter) { $0[keyPath: keyPath] = value } }
    )
}

struct RemovableRow: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Button("Remove", action: onRemove).buttonStyle(.link)
        }
    }
}

/// A picker that stays on "Choose…" and hands each pick to `onPick`; hidden when there is nothing to add.
struct AddPicker: View {
    let title: String
    let options: [String]
    let onPick: (String) -> Void

    var body: some View {
        if !options.isEmpty {
            Picker(title, selection: Binding(get: { "" }, set: { if !$0.isEmpty { onPick($0) } })) {
                Text("Choose…").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

/// A text field with an Add button that hands the typed value to `onAdd` and clears itself.
struct AddField: View {
    let title: String
    let prompt: String
    let onAdd: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(title, text: $text, prompt: Text(prompt))
                .onSubmit(add)
            Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        onAdd(text)
        text = ""
    }
}
