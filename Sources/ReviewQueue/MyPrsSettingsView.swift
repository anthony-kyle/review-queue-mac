import ReviewQueueCore
import SwiftUI

/// My PRs settings: excluded orgs and repos, whose comments count, notification rules and per-block sort order.
struct MyPrsSettingsView: View {
    let model: AppModel

    var body: some View {
        let settings = model.settings.myPrs
        Form {
            Section {
                ForEach(settings.excludedOrgs, id: \.self) { org in
                    RemovableRow(name: org) { model.update { $0.myPrs.setExcludedOrg(org, isOn: false) } }
                }
                AddPicker(title: "Exclude org", options: model.mySeenOrgs.filter { !settings.excludedOrgs.contains($0) }) { org in
                    model.update { $0.myPrs.setExcludedOrg(org, isOn: true) }
                }
                AddField(title: "Other org", prompt: "e.g. my-old-org") { org in
                    model.update { $0.myPrs.setExcludedOrg(org, isOn: true) }
                }
                ForEach(settings.excludedRepos, id: \.self) { repo in
                    RemovableRow(name: repo) { model.update { $0.myPrs.setExcludedRepo(repo, isOn: false) } }
                }
                AddPicker(title: "Exclude repo", options: model.mySeenRepos.filter { !settings.excludedRepos.contains($0) }) { repo in
                    model.update { $0.myPrs.setExcludedRepo(repo, isOn: true) }
                }
                AddField(title: "Other repo", prompt: "owner/name") { repo in
                    model.update { $0.myPrs.setExcludedRepo(repo, isOn: true) }
                }
            } header: {
                Text("Exclusions")
            } footer: {
                Text("PRs in excluded orgs or repos are left out of the menu and never notify.")
            }
            Section {
                Toggle("Count bot comments", isOn: myBinding(\.isBotCommentsShown))
                if settings.ignoredCommenters.isEmpty {
                    Text("No ignored commenters.").foregroundStyle(.secondary)
                }
                ForEach(settings.ignoredCommenters, id: \.self) { login in
                    RemovableRow(name: login) { model.update { $0.myPrs.setIgnored(login, isOn: false) } }
                }
            } header: {
                Text("Comments")
            } footer: {
                Text("New comments put a PR in Needs you until you mark them No follow-up or the PR Done. Ignore a commenter from any of their comments.")
            }
            Section("Notifications") {
                Toggle("New comments", isOn: myBinding(\.notifyComments))
                Toggle("Approved", isOn: myBinding(\.notifyApproved))
                Toggle("Changes requested (loud)", isOn: myBinding(\.notifyChangesRequested))
                Toggle("CI turned failing", isOn: myBinding(\.notifyCiFailing))
                Toggle("Merge conflict", isOn: myBinding(\.notifyConflict))
                Toggle("Merged or closed by someone else", isOn: myBinding(\.notifyClosed))
            }
            Section("Sort order") {
                ForEach(MyBlock.allCases) { block in
                    Picker(block.label, selection: Binding(
                        get: { model.settings.myPrs.sort(block) },
                        set: { sort in model.update { $0.myPrs.blockSorts[block] = sort } }
                    )) {
                        ForEach(BlockSort.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func myBinding<T>(_ keyPath: WritableKeyPath<MyPrsSettings, T>) -> Binding<T> {
        let myPrs: WritableKeyPath<QueueSettings, MyPrsSettings> = \.myPrs
        return settingsBinding(model, myPrs.appending(path: keyPath))
    }
}
