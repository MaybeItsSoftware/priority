import TaktCore
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
  @Environment(\.theme) private var theme
  var manager: AppCoordinator

  var body: some View {
    @Bindable var manager = manager
    Section(header: MicroLabel("Obsidian plugin")) {
      Toggle("Enable Obsidian integration", isOn: $manager.integrations.obsidianIntegrationEnabled)
        .toggleStyle(.themedSwitch)

      if manager.integrations.obsidianIntegrationEnabled {
        VStack(alignment: .leading, spacing: theme.space.sm) {
          Text("Obsidian Inbox")
          if manager.integrations.obsidianInboxPath.isEmpty {
            Text("No folder selected")
              .foregroundStyle(theme.muted)
              .font(theme.captionFont)
          } else {
            Text(manager.integrations.obsidianInboxPath)
              .font(theme.captionFont)
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
                .font(theme.captionFont)
                .foregroundStyle(theme.warning)
            }
          }
        }
        .padding(.top, theme.space.xs)
      } else {
        Text("Obsidian integration is disabled.")
          .foregroundStyle(theme.muted)
          .font(theme.captionFont)
      }
    }
  }
}
