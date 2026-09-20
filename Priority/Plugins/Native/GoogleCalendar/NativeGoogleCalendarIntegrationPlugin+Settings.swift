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
  var manager: AppCoordinator
  var plugin: NativeGoogleCalendarIntegrationPlugin

  var body: some View {
    @Bindable var manager = manager
    @Bindable var plugin = plugin
    Section(header: Text("Google Calendar Plugin")) {
      Toggle(
        "Enable Google Calendar integration",
        isOn: $manager.integrations.googleCalendarIntegrationEnabled
      )
        .toggleStyle(.switch)

      if manager.integrations.googleCalendarIntegrationEnabled {
        VStack(alignment: .leading, spacing: 10) {
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
          .font(.caption2)
          .foregroundColor(.secondary)
        }
        .padding(.top, 4)
      } else {
        Text("Google Calendar integration is disabled.")
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
  }
}
