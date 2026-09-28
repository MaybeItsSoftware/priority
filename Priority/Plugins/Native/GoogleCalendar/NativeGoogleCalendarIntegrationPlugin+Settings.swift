import PriorityCore
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
    Section(header: MicroLabel("Google Calendar plugin")) {
      Toggle(
        "Enable Google Calendar integration",
        isOn: $manager.integrations.googleCalendarIntegrationEnabled
      )
        .toggleStyle(.switch)

      if manager.integrations.googleCalendarIntegrationEnabled {
        VStack(alignment: .leading, spacing: theme.space.sm) {
          GoogleAccountSettingsSection(
            account: plugin.account,
            serviceName: "Google Calendar",
            requiredScopes: GoogleAPIScope.calendar)

          Divider()

          Text("Calendar ID")
          TextField("", text: $plugin.targetCalendarID, prompt: Text("primary"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .autocorrectionDisabled()

          Toggle("Open created event in browser", isOn: $plugin.openCreatedEventInBrowser)
            .toggleStyle(.switch)

          Button("Create event from selected task") {
            manager.integrations.openTaskInGoogleCalendar()
          }
          .disabled(!plugin.isAuthenticated)

          Text(
            "This integration creates Google Calendar events from tasks. OAuth setup and sign-in are required."
          )
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
        }
        .padding(.top, theme.space.xs)
      } else {
        Text("Google Calendar integration is disabled.")
          .foregroundStyle(theme.muted)
          .font(theme.captionFont)
      }
    }
  }
}
