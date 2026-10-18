import TaktCore
import TaktWorkspace
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

        GoogleCalendarTwoWaySettings(service: manager.googleCalendarTwoWay)

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
          "Creates events from tasks, and keeps timed tasks in step with the calendar chosen above. OAuth setup and sign-in are required."
        )
      }
    }
  }
}

/// Two-way sync's choices (docs/google-calendar.md). They live in the
/// workspace's synced preferences, so choosing here chooses for the phones.
private struct GoogleCalendarTwoWaySettings: View {
  @Environment(\.theme) private var theme
  var service: GoogleCalendarTwoWayService

  private var writable: [GoogleCalendarChoice] { service.calendars.filter(\.canWrite) }

  var body: some View {
    SettingsRow(
      "Two-way calendar",
      detail: "Timed tasks become events here, and moving or renaming one moves or renames the task."
    ) {
      Picker(
        "",
        selection: Binding(
          get: { service.preferences.twoWayCalendarID ?? "" },
          set: { id in service.update { $0.twoWayCalendarID = id.isEmpty ? nil : id } })
      ) {
        Text("Off").tag("")
        ForEach(writable) { calendar in
          Text(calendar.summary).tag(calendar.id)
        }
        if let current = service.preferences.twoWayCalendarID,
          !writable.contains(where: { $0.id == current })
        {
          Text(current).tag(current)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 260)
    }
    .task {
      service.reloadPreferences()
      await service.loadCalendars()
    }

    if service.preferences.twoWayCalendarID != nil {
      SettingsToggleRow(
        "Turn new events into tasks",
        detail: "Events created in Google on this calendar become tasks in the inbox.",
        isOn: Binding(
          get: { service.preferences.importEvents },
          set: { value in service.update { $0.importEvents = value } }))

      HStack(spacing: theme.space.sm) {
        Button("Sync calendar now") { service.syncNow() }
          .disabled(service.state == .syncing)
        Spacer()
        Text(statusLine)
          .font(theme.captionFont)
          .foregroundStyle(isFailure ? theme.danger : theme.muted)
      }
    }
  }

  private var isFailure: Bool {
    if case .failed = service.state { return true }
    return false
  }

  private var statusLine: String {
    switch service.state {
    case .syncing: return "Syncing…"
    case .failed(let message): return message
    case .idle:
      guard let at = service.lastSyncedAt else { return "Syncs after a change, and every five minutes." }
      if service.lastSummary == nil { return "Another device is syncing this calendar." }
      return "Last synced \(at.formatted(date: .omitted, time: .shortened))"
    }
  }
}
