import TaktCore
import SwiftUI

@MainActor
extension NativeGoogleCalendarIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "calendar" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.integrations.googleCalendarIntegrationEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(
      GoogleCalendarIntegrationPluginSettingsView(
        manager: manager,
        plugin: self
      )
    )
  }
}

private struct GoogleCalendarIntegrationPluginSettingsView: View {
  @Environment(\.theme) private var theme
  var manager: AppCoordinator
  var plugin: NativeGoogleCalendarIntegrationPlugin

  var body: some View {
    @Bindable var manager = manager
    @Bindable var plugin = plugin
    Section {
      SettingsToggleRow(
        "Enable Google Calendar integration",
        isOn: $manager.integrations.googleCalendarIntegrationEnabled)

      if manager.integrations.googleCalendarIntegrationEnabled {
        GoogleAccountSettingsSection(
          account: plugin.account,
          serviceName: "Google Calendar",
          requiredScopes: GoogleAPIScope.calendar)

        SettingsRow("Calendar ID") {
          TextField("", text: $plugin.targetCalendarID, prompt: Text("primary"))
            .themedTextField()
            .labelsHidden()
            .autocorrectionDisabled()
            .frame(maxWidth: 260)
        }

        SettingsToggleRow("Open created event in browser", isOn: $plugin.openCreatedEventInBrowser)

        Button("Create event from selected task") {
          manager.integrations.createEventFromSelectedTask()
        }
        .disabled(!plugin.isAuthenticated)
      } else {
        Text("Google Calendar integration is disabled.")
          .foregroundStyle(theme.muted)
          .font(theme.captionFont)
      }
    } header: {
      Text("Google Calendar plugin")
    } footer: {
      if manager.integrations.googleCalendarIntegrationEnabled {
        Text(
          "This integration creates Google Calendar events from tasks. OAuth setup and sign-in are required."
        )
      }
    }
  }
}
