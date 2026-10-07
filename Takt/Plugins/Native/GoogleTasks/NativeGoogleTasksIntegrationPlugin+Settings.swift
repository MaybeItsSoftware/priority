import TaktCore
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
  @Environment(\.theme) private var theme
  var manager: AppCoordinator
  var plugin: NativeGoogleTasksIntegrationPlugin

  var body: some View {
    @Bindable var manager = manager
    Section {
      SettingsToggleRow(
        "Mirror my lists to Google Tasks",
        isOn: $manager.integrations.googleTasksIntegrationEnabled)

      if manager.integrations.googleTasksIntegrationEnabled {
        GoogleAccountSettingsSection(
          account: plugin.account,
          serviceName: "Google Tasks",
          requiredScopes: GoogleAPIScope.taskLists)
        mirrorStatus
        if !mirror.recentConflicts.isEmpty {
          conflicts
        }
      } else {
        Text("Google Tasks mirroring is off. Nothing leaves this machine.")
          .foregroundStyle(theme.muted)
          .font(theme.captionFont)
      }
    } header: {
      Text("Google Tasks plugin")
    } footer: {
      if manager.integrations.googleTasksIntegrationEnabled {
        Text(
          """
          Each of your lists becomes a Google Tasks list of the same name. \
          Takt is the source of authority: an edit made in Google Tasks \
          is replaced by the Takt version and written to the conflict \
          log above. Ticking a task off in Google Tasks completes it here, \
          notes added there are kept, and a task typed there is adopted \
          into the matching list.
          """
        )
      }
    }
  }

  private var mirror: GoogleTasksMirrorService { manager.googleTasksMirror }

  private var mirrorStatus: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      HStack(spacing: theme.space.sm) {
        Button("Sync now") { mirror.syncNow() }
          .disabled(!plugin.isAuthenticated || mirror.state == .syncing)
        if mirror.state == .syncing { ProgressView().scaleEffect(0.8) }
        Spacer()
        Text("\(mirror.mirroredTaskCount) mirrored")
          .font(theme.monoFont(size: theme.scale.caption))
          .foregroundStyle(theme.muted)
      }

      switch mirror.state {
      case .failed(let message):
        Text(message)
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
      case .syncing:
        Text("Syncing…").font(theme.captionFont).foregroundStyle(theme.muted)
      case .idle:
        if let lastSyncedAt = mirror.lastSyncedAt {
          Text("Last synced \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        } else {
          Text("Syncs a few seconds after a change, and every five minutes.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
      }
    }
  }

  private var conflicts: some View {
    // The authority rule occasionally discards something a person typed on
    // their phone. This is the page that admits it.
    VStack(alignment: .leading, spacing: theme.space.sm) {
      MicroLabel("Conflicts resolved in Takt's favour")
      ForEach(mirror.recentConflicts.prefix(8)) { record in
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Text(record.summary).font(theme.captionFont)
          Text(record.resolvedAt.formatted(date: .abbreviated, time: .shortened))
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
      }
      Text("The full log is in google-tasks-conflicts.jsonl, in Takt's Application Support folder.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
    }
  }
}
