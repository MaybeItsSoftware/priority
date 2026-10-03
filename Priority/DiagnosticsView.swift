import AppKit
import PriorityCore
import SwiftUI
import UniformTypeIdentifiers

/// The support screen: what state the app is in, what is unhealthy, what has
/// gone wrong this session, and where its files are.
///
/// Built in the Settings pane shape — `Group { Section { … } }` inside a grouped
/// `Form` — rather than as a bespoke layout, so it can also be dropped into
/// `SettingsView` later for one `Pane` case and one line of dispatch. It is
/// deliberately outside `#if DEBUG`: the existing debug pane is compiled out of
/// Release, which is exactly when someone needs to be asked what they are seeing.
struct DiagnosticsView: View {
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme

  @State private var copyConfirmation: String?

  private var repository: TaskRepository { manager.repository }

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      Form {
        statusSection
        healthSection
        recentProblemsSection
        dataSection
      }
      .formStyle(.grouped)
      Divider()
      footer
    }
    .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 620)
    // The Google rows report a sign-in that is read from the keychain on
    // first use. Asking for it here means the health pane shows the real
    // state rather than "sign in required" until something else looks.
    .task {
      manager.integrations.googleCalendarPlugin.prepareAuthentication()
      manager.integrations.googleTasksPlugin.prepareAuthentication()
    }
  }

  // MARK: - Header / footer

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Diagnostics").font(theme.titleFont)
        Text("\(Self.appVersion) (\(Self.buildNumber)) · \(Self.bundleIdentifier)")
          .font(theme.captionFont)
          .foregroundColor(themeColor(.textSecondary))
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
      Button("Done") { manager.popoverChrome.showsDiagnostics = false }
        .keyboardShortcut(.defaultAction)
    }
    .padding(12)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button("Copy Report") { copyReport() }
      Button("Export Report…") { exportReport() }
      if let copyConfirmation {
        Text(copyConfirmation)
          .font(theme.captionFont)
          .foregroundColor(themeColor(.textSecondary))
      }
      Spacer(minLength: 0)
      Button("Retry Sync") {
        Task { await manager.syncService.fetchTopTask() }
      }
      .disabled(repository.isLoading)
    }
    .padding(12)
  }

  // MARK: - Sections

  private var statusSection: some View {
    Section(header: Text("Status")) {
      let summary = syncSummary
      labelledRow("Connection", connectionDescription)
      labelledRow("List", listDescription)
      labelledRow("Network", repository.isNetworkReachable ? "Reachable" : "Unreachable")
      labelledRow("Sync", summary.text, tint: severityColor(summary.severity))
      labelledRow("Open tasks", "\(repository.tasks.count)")
      labelledRow(
        "Queued offline",
        repository.hasPendingOfflineWork ? "Yes" : "None")
    }
  }

  private var healthSection: some View {
    Section(header: Text("Health")) {
      ForEach(Array(healthItems.enumerated()), id: \.offset) { _, item in
        stepRow(ok: item.isHealthy, title: item.title, detail: item.detail)
      }
    }
  }

  private var recentProblemsSection: some View {
    Section(header: Text("Recent problems")) {
      let entries = manager.diagnosticsLog.entries.reversed()
      if entries.isEmpty {
        // Distinct from "no data": nothing has failed, which is worth saying
        // plainly rather than showing an empty box that reads as broken.
        Text("Nothing has failed since the app started.")
          .font(theme.captionFont)
          .foregroundColor(themeColor(.textSecondary))
      } else {
        ForEach(Array(entries), id: \.id) { entry in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(
              systemName: entry.isFailure
                ? "exclamationmark.triangle.fill" : "info.circle.fill"
            )
            .foregroundStyle(entry.isFailure ? Color.orange : Color.secondary)
            .font(theme.captionFont)
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              Text("\(entry.category) · \(Self.timeFormatter.string(from: entry.date))")
                .font(theme.captionFont)
                .foregroundColor(themeColor(.textSecondary))
            }
            Spacer(minLength: 0)
          }
        }
        Button("Clear") { manager.diagnosticsLog.clear() }
      }
    }
  }

  private var dataSection: some View {
    Section(header: Text("Data")) {
      ForEach(Array(dataPaths.enumerated()), id: \.offset) { _, entry in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          VStack(alignment: .leading, spacing: 1) {
            Text(entry.label)
            Text(entry.url.path)
              .font(theme.captionFont)
              .foregroundColor(themeColor(.textSecondary))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          Button("Reveal") { reveal(entry.url) }
            .buttonStyle(.borderless)
            .disabled(!FileManager.default.fileExists(atPath: entry.url.path))
        }
      }
    }
  }

  // MARK: - Rows

  /// The same green-tick / orange-triangle row the MCP settings pane uses, so a
  /// health list reads the same wherever it appears.
  private func stepRow(ok: Bool, title: String, detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(ok ? Color.green : Color.orange)
        .font(theme.captionFont)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        if !detail.isEmpty {
          Text(detail)
            .font(theme.captionFont)
            .foregroundColor(themeColor(.textSecondary))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
  }

  private func labelledRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundColor(themeColor(.textSecondary))
      Spacer(minLength: 12)
      Text(value)
        .foregroundColor(tint)
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func severityColor(_ severity: SyncStatusSeverity) -> Color? {
    switch severity {
    case .ok: return nil
    case .warning: return themeColor(.warning)
    case .problem: return themeColor(.danger)
    }
  }

  // MARK: - Derived state

  private var syncSummary: SyncStatusSummary {
    SyncStatusFormatter.summary(
      isLoading: repository.isLoading,
      isNetworkReachable: repository.isNetworkReachable,
      canSyncRemotely: repository.canSyncRemotely,
      hasPendingOfflineWork: repository.hasPendingOfflineWork,
      errorMessage: repository.errorMessage,
      lastSuccessfulSyncAt: repository.lastSuccessfulSyncAt
    )
  }

  private var connectionDescription: String {
    switch repository.checkvistConnectionState {
    case .disconnected: return "No credentials"
    case .connecting: return "Connecting…"
    case .awaitingConnect: return "Credentials set, not connected"
    case .connected(let listCount): return "Connected · \(listCount) lists"
    }
  }

  private var listDescription: String {
    if repository.listId.isEmpty { return "Offline workspace" }
    let name = repository.currentListName
    return name.isEmpty
      ? "id \(repository.listId) (name unknown)"
      : "\(name) (id \(repository.listId))"
  }

  private var healthItems: [DiagnosticsSnapshot.HealthItem] {
    var items: [DiagnosticsSnapshot.HealthItem] = []
    let integrations = manager.integrations

    items.append(
      .init(
        title: "Checkvist credentials",
        isHealthy: repository.canAttemptLogin,
        detail: repository.canAttemptLogin
          ? "Username and remote key are set."
          : "Add a username and remote key in Preferences → Preferences."))

    items.append(
      .init(
        title: "Remote sync",
        isHealthy: repository.canSyncRemotely,
        detail: repository.canSyncRemotely
          ? "Mutations go to Checkvist."
          : "Working offline — mutations are stored locally."))

    if integrations.obsidianIntegrationEnabled {
      let path = integrations.obsidianInboxPath
      items.append(
        .init(
          title: "Obsidian",
          isHealthy: !path.isEmpty,
          detail: path.isEmpty ? "No inbox folder chosen." : path))
    }

    if integrations.affineIntegrationEnabled {
      // `helperDiagnostic()` already returns every path it searched — the plugin
      // was written to be asked this question.
      items.append(
        .init(
          title: "AFFiNE helper",
          isHealthy: integrations.affinePlugin.isConfigured,
          detail: integrations.affinePlugin.helperDiagnostic()))
    }

    if integrations.googleCalendarIntegrationEnabled {
      let plugin = integrations.googleCalendarPlugin
      items.append(
        .init(
          title: "Google Calendar",
          isHealthy: !plugin.requiresAuthentication || plugin.isAuthenticated,
          detail: plugin.authenticationStatusDescription))
    }

    if integrations.googleTasksIntegrationEnabled {
      let plugin = integrations.googleTasksPlugin
      items.append(
        .init(
          title: "Google Tasks",
          isHealthy: !plugin.requiresAuthentication || plugin.isAuthenticated,
          detail: plugin.authenticationStatusDescription))
    }

    if integrations.mcpIntegrationEnabled {
      items.append(
        .init(
          title: "MCP server",
          isHealthy: integrations.hasResolvedMCPServerCommand,
          detail: integrations.hasResolvedMCPServerCommand
            ? integrations.mcpServerCommandPath
            : "Could not resolve the bundled CLI helper."))
    }

    let userPlugins = manager.userPluginManager
    if !userPlugins.installedPlugins.isEmpty || !userPlugins.validationIssues.isEmpty {
      let issues = userPlugins.validationIssues
      items.append(
        .init(
          title: "User plugins",
          isHealthy: issues.isEmpty && userPlugins.lastErrorMessage == nil,
          detail: issues.isEmpty
            ? (userPlugins.lastErrorMessage
              ?? "\(userPlugins.installedPlugins.count) installed, no issues.")
            : issues.map(\.message).joined(separator: "\n")))
    }

    return items
  }

  private var dataPaths: [(label: String, url: URL)] {
    let directory = DailyLogService.defaultStoreDirectoryURL()
    var entries: [(label: String, url: URL)] = [
      ("Application Support", directory),
      ("Day log", directory.appendingPathComponent("daylog.jsonl")),
      ("Dailies", directory.appendingPathComponent("dailies.json")),
      ("User plugins", directory.appendingPathComponent("Plugins", isDirectory: true)),
    ]
    if !repository.listId.isEmpty {
      entries.append(
        (
          "Task cache",
          directory.appendingPathComponent("tasks-cache-\(repository.listId).json")
        ))
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    entries.append(
      (
        "Preferences",
        home.appendingPathComponent(
          "Library/Preferences/\(Self.bundleIdentifier).plist")
      ))
    // Named because it is a recurring confusion: the CLI keeps its own
    // credentials rather than reaching into the app's keychain item, which is
    // only readable by something carrying the app's signature.
    entries.append(("CLI config", home.appendingPathComponent(".config/takt/config.json")))
    return entries
  }

  // MARK: - Actions

  private func reveal(_ url: URL) {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard exists else { return }
    if isDirectory.boolValue {
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  private func makeSnapshot() -> DiagnosticsSnapshot {
    DiagnosticsSnapshot(
      appVersion: Self.appVersion,
      buildNumber: Self.buildNumber,
      generatedAt: Date(),
      connectionDescription: connectionDescription,
      listName: repository.currentListName,
      listID: repository.listId,
      isNetworkReachable: repository.isNetworkReachable,
      syncStatus: syncSummary.text,
      lastSuccessfulSyncAt: repository.lastSuccessfulSyncAt,
      openTaskCount: repository.tasks.count,
      pendingOfflineWorkCount: repository.hasPendingOfflineWork ? 1 : 0,
      health: healthItems,
      recentProblems: manager.diagnosticsLog.entries.map {
        .init(date: $0.date, category: $0.category, message: $0.message, isFailure: $0.isFailure)
      },
      paths: dataPaths.map { (label: $0.label, path: $0.url.path) }
    )
  }

  private func copyReport() {
    let text = DiagnosticsReport.text(from: makeSnapshot())
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copyConfirmation = "Copied."
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      copyConfirmation = nil
    }
  }

  private func exportReport() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "priority-diagnostics.txt"
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let text = DiagnosticsReport.text(from: makeSnapshot())
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      manager.diagnosticsLog.record(
        category: "Diagnostics",
        message: "Failed to export report: \(error.localizedDescription)",
        isFailure: true)
    }
  }

  // MARK: - Bundle facts

  private static let appVersion =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  private static let buildNumber =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
  private static let bundleIdentifier =
    Bundle.main.bundleIdentifier ?? "uk.co.maybeitssoftware.takt"

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}
