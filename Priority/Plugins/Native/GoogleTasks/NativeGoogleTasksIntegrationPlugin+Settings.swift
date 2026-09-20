import SwiftUI

@MainActor
extension NativeGoogleTasksIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "checklist" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.integrations.googleTasksIntegrationEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(GoogleTasksIntegrationPluginSettingsView(manager: manager, plugin: self))
  }
}

private struct GoogleTasksIntegrationPluginSettingsView: View {
  var manager: AppCoordinator
  var plugin: NativeGoogleTasksIntegrationPlugin

  var body: some View {
    @Bindable var manager = manager
    Section(header: Text("Google Tasks Plugin")) {
      Toggle(
        "Mirror my lists to Google Tasks",
        isOn: $manager.integrations.googleTasksIntegrationEnabled
      )
      .toggleStyle(.switch)

      if manager.integrations.googleTasksIntegrationEnabled {
        VStack(alignment: .leading, spacing: 12) {
          GoogleAccountSettingsSection(
            account: plugin.account,
            serviceName: "Google Tasks",
            requiredScopes: GoogleAPIScope.taskLists)

          Divider()
          mirrorStatus
          if !mirror.recentConflicts.isEmpty {
            Divider()
            conflicts
          }

          Text(
            """
            Each of your lists becomes a Google Tasks list of the same name. \
            Priority is the source of authority: an edit made in Google Tasks \
            is replaced by the Priority version and written to the conflict \
            log below. Ticking a task off in Google Tasks completes it here, \
            notes added there are kept, and a task typed there is adopted \
            into the matching list.
            """
          )
          .font(.caption2)
          .foregroundColor(.secondary)
        }
        .padding(.top, 4)
      } else {
        Text("Google Tasks mirroring is off. Nothing leaves this machine.")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
  }

  private var mirror: GoogleTasksMirrorService { manager.googleTasksMirror }

  @ViewBuilder
  private var mirrorStatus: some View {
    HStack(spacing: 8) {
      Button("Sync now") { mirror.syncNow() }
        .disabled(!plugin.isAuthenticated || mirror.state == .syncing)
      if mirror.state == .syncing { ProgressView().scaleEffect(0.8) }
      Spacer()
      Text("\(mirror.mirroredTaskCount) mirrored")
        .font(.caption.monospacedDigit())
        .foregroundColor(.secondary)
    }

    switch mirror.state {
    case .failed(let message):
      Text(message)
        .font(.caption)
        .foregroundColor(.red)
    case .syncing:
      Text("Syncing…").font(.caption).foregroundColor(.secondary)
    case .idle:
      if let lastSyncedAt = mirror.lastSyncedAt {
        Text("Last synced \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
          .font(.caption)
          .foregroundColor(.secondary)
      } else {
        Text("Syncs a few seconds after a change, and every five minutes.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  @ViewBuilder
  private var conflicts: some View {
    // The authority rule occasionally discards something a person typed on
    // their phone. This is the page that admits it.
    Text("CONFLICTS RESOLVED IN PRIORITY'S FAVOUR")
      .font(.caption2.weight(.bold))
      .foregroundColor(.secondary)
    ForEach(mirror.recentConflicts.prefix(8)) { record in
      VStack(alignment: .leading, spacing: 1) {
        Text(record.summary).font(.caption)
        Text(record.resolvedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundColor(.secondary)
      }
    }
    Text("The full log is in google-tasks-conflicts.jsonl, in Priority's Application Support folder.")
      .font(.caption2)
      .foregroundColor(.secondary)
  }
}
