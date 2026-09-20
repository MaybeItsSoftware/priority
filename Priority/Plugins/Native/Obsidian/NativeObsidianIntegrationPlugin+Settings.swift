import SwiftUI

@MainActor
extension NativeObsidianIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "book.closed" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.integrations.obsidianIntegrationEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(ObsidianIntegrationPluginSettingsView(manager: manager))
  }
}

private struct ObsidianIntegrationPluginSettingsView: View {
  var manager: AppCoordinator

  var body: some View {
    @Bindable var manager = manager
    Section(header: Text("Obsidian Plugin")) {
      Toggle("Enable Obsidian integration", isOn: $manager.integrations.obsidianIntegrationEnabled)
        .toggleStyle(.switch)

      if manager.integrations.obsidianIntegrationEnabled {
        VStack(alignment: .leading, spacing: 8) {
          Text("Obsidian Inbox")
          if manager.integrations.obsidianInboxPath.isEmpty {
            Text("No folder selected")
              .foregroundColor(.secondary)
              .font(.caption)
          } else {
            Text(manager.integrations.obsidianInboxPath)
              .font(.caption)
              .textSelection(.enabled)
          }

          HStack {
            Button("Choose Folder") {
              manager.integrations.chooseObsidianInboxFolder()
            }
            if !manager.integrations.obsidianInboxPath.isEmpty {
              Button("Clear") {
                manager.integrations.clearObsidianInboxFolder()
              }
            }
            Spacer()
            if manager.integrations.hasPendingObsidianSync {
              Text(manager.integrations.pendingSyncMenuBarPrefix)
                .font(.caption)
                .foregroundColor(.orange)
            }
          }
        }
        .padding(.top, 4)
      } else {
        Text("Obsidian integration is disabled.")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
  }
}
