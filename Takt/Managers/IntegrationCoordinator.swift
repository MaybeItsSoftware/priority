import AppKit
import Foundation
import OSLog
import Observation
import TaktCore

/// What the MCP setup seeds the `takt` command with: the Checkvist account
/// and the list its Checkvist tools default to.
@MainActor
protocol IntegrationDataSource: AnyObject {
  var listId: String { get }
  var activeCredentials: CheckvistCredentials { get }
}

@MainActor
@Observable class IntegrationCoordinator {
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "integrations")
  @ObservationIgnored private let preferencesStore: PreferencesStore

  @ObservationIgnored weak var dataSource: IntegrationDataSource?

  /// Called when integration-enabled flags change so the coordinator can refresh onboarding.
  @ObservationIgnored var onIntegrationStateChanged: (() -> Void)?
  /// Called with an error message (or nil to clear) when integration actions produce errors.
  @ObservationIgnored var onError: ((String?) -> Void)?
  /// Called with a transient success line. An integration that writes somewhere
  /// the user cannot see needs to say what it did — clearing the error is not
  /// the same as reporting a result.
  @ObservationIgnored var onStatus: ((String) -> Void)?
  /// Adds the desktop workspace's selected task to Google Calendar and answers
  /// whether there was one to add. Set by `AppDelegate`, which owns the
  /// workspace; the coordinator is built before it.
  @ObservationIgnored var addSelectedWorkspaceTaskToGoogleCalendar: (() -> Bool)?

  // MARK: - Integration enable flags

  var googleCalendarIntegrationEnabled: Bool {
    didSet {
      preferencesStore.set(googleCalendarIntegrationEnabled, for: .googleCalendarIntegrationEnabled)
      onIntegrationStateChanged?()
    }
  }
  var googleTasksIntegrationEnabled: Bool {
    didSet {
      preferencesStore.set(googleTasksIntegrationEnabled, for: .googleTasksIntegrationEnabled)
      onIntegrationStateChanged?()
    }
  }
  var mcpIntegrationEnabled: Bool {
    didSet {
      preferencesStore.set(mcpIntegrationEnabled, for: .mcpIntegrationEnabled)
      onIntegrationStateChanged?()
    }
  }

  // MARK: - Integration state

  var mcpServerCommandPath: String

  /// MCP clients found on this machine, and the result of the last setup action.
  /// Populated by `refreshDetectedMCPClients()` when the MCP settings page opens.
  var detectedMCPClients: [MCPClientDescriptor] = []
  var mcpSetupStatusMessage: String = ""
  var mcpSetupStatusIsError: Bool = false

  @ObservationIgnored private let mcpClientInstaller = MCPClientInstaller()

  // MARK: - Plugin references

  let googleCalendarPlugin: any GoogleCalendarIntegrationPlugin
  let googleTasksPlugin: any GoogleTasksIntegrationPlugin
  let mcpIntegrationPlugin: any MCPIntegrationPlugin

  // MARK: - Computed

  var hasResolvedMCPServerCommand: Bool {
    !mcpServerCommandPath.isEmpty
  }

  // MARK: - Init

  init(
    preferencesStore: PreferencesStore,
    googleCalendarPlugin: any GoogleCalendarIntegrationPlugin,
    googleTasksPlugin: any GoogleTasksIntegrationPlugin,
    mcpIntegrationPlugin: any MCPIntegrationPlugin
  ) {
    self.preferencesStore = preferencesStore
    self.googleCalendarPlugin = googleCalendarPlugin
    self.googleTasksPlugin = googleTasksPlugin
    self.mcpIntegrationPlugin = mcpIntegrationPlugin

    let storedGoogleEnabled = preferencesStore.optionalBool(.googleCalendarIntegrationEnabled)
    let storedGoogleTasksEnabled = preferencesStore.optionalBool(.googleTasksIntegrationEnabled)
    let storedMCPEnabled = preferencesStore.optionalBool(.mcpIntegrationEnabled)

    self.googleCalendarIntegrationEnabled =
      storedGoogleEnabled
      ?? preferencesStore.bool(.googleCalendarIntegrationEnabled, default: false)
    self.googleTasksIntegrationEnabled =
      storedGoogleTasksEnabled
      ?? preferencesStore.bool(.googleTasksIntegrationEnabled, default: false)
    self.mcpIntegrationEnabled =
      storedMCPEnabled
      ?? preferencesStore.bool(.mcpIntegrationEnabled, default: false)
    self.mcpServerCommandPath = mcpIntegrationPlugin.serverCommandURL()?.path ?? ""
  }

  // MARK: - Google Calendar

  /// Creates an event for a task owned by the local workspace. The legacy
  /// coordinator used to accept only Checkvist integer IDs, which made the
  /// Calendar integration disappear as soon as the desktop workspace became
  /// the primary UI.
  func createGoogleCalendarEvent(
    title: String, taskID: String, listTitle: String, date: Date?, isAllDay: Bool
  ) async throws -> String? {
    guard googleCalendarIntegrationEnabled else {
      throw WorkspaceGoogleCalendarError.integrationDisabled
    }
    let details = """
      Created from Takt
      List: \(listTitle)
      Task ID: \(taskID)
      """
    let outcome = try await googleCalendarPlugin.createEvent(
      title: title, details: details, date: date, isAllDay: isAllDay, now: .now)
    if let url = outcome.urlToOpen, url.scheme?.lowercased() == "https" {
      NSWorkspace.shared.open(url)
    }
    return outcome.eventID
  }

  /// The settings page's "Create event from selected task".
  ///
  /// Acts on the desktop window's selected task, through the same path as the
  /// inspector's "Add to Google Calendar", so the event is the same whichever
  /// button made it. It used to act on the legacy Checkvist cursor, which
  /// nothing on screen shows or moves any more.
  func createEventFromSelectedTask() {
    guard googleCalendarIntegrationEnabled else {
      onError?("Enable Google Calendar integration in Preferences first.")
      return
    }
    guard let addSelectedWorkspaceTaskToGoogleCalendar else {
      onError?("Internal error: no workspace.")
      return
    }
    guard addSelectedWorkspaceTaskToGoogleCalendar() else {
      onError?("No task selected.")
      return
    }
    onError?(nil)
  }

  // MARK: - MCP

  func refreshMCPServerCommandPath() {
    mcpServerCommandPath = mcpIntegrationPlugin.serverCommandURL()?.path ?? ""
  }

  func copyMCPClientConfigurationToClipboard() {
    guard mcpIntegrationEnabled else {
      onError?("Enable MCP integration in Preferences first.")
      return
    }
    guard let ds = dataSource else { onError?("Internal error: no data source."); return }

    refreshMCPServerCommandPath()

    // The copied config carries no credentials; the server reads them from the
    // CLI's own store, which the explicit "Add to <client>" step seeds. Copying
    // a snippet is not that step — it used to write the remote key to
    // `~/.config/takt/config.json` as a side effect of putting text on the
    // clipboard, which nobody asked for and which is not undone by clearing
    // the clipboard.
    let config = mcpIntegrationPlugin.makeClientConfigurationJSON(listId: ds.listId)
    copyToPasteboard(config)

    if mcpServerCommandPath.isEmpty {
      onError?(
        "MCP config copied with placeholder app path. Set PRIORITY_MCP_EXECUTABLE_PATH if your app is outside /Applications."
      )
    } else {
      onError?(nil)
    }
  }

  func openMCPServerGuide() {
    guard mcpIntegrationEnabled else {
      onError?("Enable MCP integration in Preferences first.")
      return
    }
    guard let guideURL = mcpIntegrationPlugin.guideURL() else {
      onError?("MCP guide not found. See docs/mcp-server.md in the repo.")
      return
    }
    NSWorkspace.shared.open(guideURL)
    onError?(nil)
  }

  /// Exactly what gets copied and installed — there is nothing left to redact.
  func mcpClientConfigurationPreview(listId: String) -> String {
    mcpIntegrationPlugin.makeClientConfigurationJSON(listId: listId)
  }

  // MARK: - MCP client setup

  /// True once Checkvist credentials exist. Without them there is nothing to
  /// seed into the CLI's credential store, and every tool call fails on the
  /// client's side, which is a confusing way to discover a missing login.
  var hasMCPCredentials: Bool {
    guard let ds = dataSource else { return false }
    return !ds.activeCredentials.normalizedUsername.isEmpty
      && !ds.activeCredentials.normalizedRemoteKey.isEmpty
  }

  /// Refreshed explicitly rather than computed, so SwiftUI doesn't stat the
  /// filesystem on every body evaluation.
  func refreshDetectedMCPClients() {
    detectedMCPClients = mcpClientInstaller.detectedClients()
  }

  func mcpConfigPath(for client: MCPClientDescriptor) -> String {
    mcpClientInstaller.configURL(for: client).path
  }

  /// One button per client. Whichever route a client needs, this is the whole
  /// interaction: no locating config files, no merging JSON by hand.
  func setUpMCPClient(_ client: MCPClientDescriptor) {
    guard mcpIntegrationEnabled else {
      setMCPSetupStatus("Enable MCP integration first.", isError: true)
      return
    }
    // `+Settings.swift` disables the button without credentials, but a config
    // file is not the place to discover that a UI guard was the only one.
    guard hasMCPCredentials else {
      setMCPSetupStatus("Connect Checkvist first.", isError: true)
      return
    }
    guard let ds = dataSource,
      let entry = makeMCPServerEntry(requiresTransportType: client.requiresTransportType)
    else {
      setMCPSetupStatus("Internal error: no data source.", isError: true)
      return
    }

    // The entry carries no credentials, so the server reads them from the CLI's
    // own store. Seed it before writing anything a client will act on.
    do {
      try seedPriorityCLICredentials(credentials: ds.activeCredentials, listId: ds.listId)
    } catch {
      logger.error("Seeding the takt CLI's credentials failed: \(error)")
      setMCPSetupStatus(error.localizedDescription, isError: true)
      return
    }

    switch client.installStyle {
    case .mergeConfigFile:
      installMCPConfigFile(entry: entry, client: client)
    case .terminalCommand:
      copyToPasteboard(MCPClientConfigWriter.terminalCommand(entry: entry))
      setMCPSetupStatus(
        "Command copied. Paste it into Terminal. \(client.postInstallNote)", isError: false)
    case .pasteSnippet:
      copyToPasteboard(
        MCPClientConfigWriter.pasteSnippet(entry: entry, serversKey: client.serversKey))
      setMCPSetupStatus(
        "Snippet copied. Paste it inside the outer braces of \(client.configPath). "
          + client.postInstallNote,
        isError: false
      )
    }
  }

  private func installMCPConfigFile(entry: MCPServerEntry, client: MCPClientDescriptor) {
    do {
      switch try mcpClientInstaller.install(entry: entry, into: client) {
      case .cancelled:
        setMCPSetupStatus("Setup cancelled — \(client.displayName) wasn't changed.", isError: false)
      case .wrote(.added):
        setMCPSetupStatus("Added to \(client.displayName). \(client.postInstallNote)", isError: false)
      case .wrote(.updated):
        setMCPSetupStatus(
          "Updated the entry in \(client.displayName). \(client.postInstallNote)", isError: false)
      case .wrote(.unchanged):
        setMCPSetupStatus("\(client.displayName) is already set up.", isError: false)
      }
    } catch {
      logger.error("MCP setup for \(client.id, privacy: .public) failed: \(error)")
      setMCPSetupStatus(error.localizedDescription, isError: true)
    }
  }

  private func makeMCPServerEntry(requiresTransportType: Bool) -> MCPServerEntry? {
    guard let ds = dataSource else { return nil }
    refreshMCPServerCommandPath()
    let invocation = mcpIntegrationPlugin.serverInvocation()
    return MCPServerEntry(
      command: invocation.command,
      args: invocation.args,
      env: mcpIntegrationPlugin.serverEnvironment(listId: ds.listId),
      transportType: requiresTransportType ? "stdio" : nil
    )
  }

  /// Hands the app's Checkvist login down to the `takt` CLI, which is the
  /// MCP server and cannot read the app's keychain item — that would depend on
  /// the app's code signature. Nothing in a generated client config carries a
  /// secret any more, so this file is where the server gets its credentials.
  ///
  /// The read, merge and private write are the Rust core's, the same code
  /// `takt auth` saves the file through.
  private func seedPriorityCLICredentials(
    credentials: CheckvistCredentials,
    listId: String
  ) throws {
    let outcome = try TaktCLIConfigWriter.seed(
      credentials: TaktCLICredentials(
        username: credentials.username,
        remoteKey: credentials.remoteKey,
        listId: listId
      ),
      inHomeDirectory: MCPClientInstaller.realHomeDirectory.path
    )
    if outcome != .unchanged {
      logger.info(
        "Seeded the takt CLI's credentials: \(String(describing: outcome), privacy: .public)")
    }
  }

  /// Blanks the username and remote key the app seeded into the CLI's config,
  /// leaving every other key (`base_url`, `list_id`) alone. The counterpart of
  /// `seedPriorityCLICredentials`: signing out of Checkvist in the app used to
  /// leave the remote key sitting in `~/.config/takt/config.json`, where every
  /// MCP client the app had set up kept using it.
  ///
  /// Only the current path is touched — the legacy `priority` config is read
  /// by the seeding step but never written, and that stays true here.
  func clearSeededCLICredentials() {
    do {
      if try TaktCLIConfigWriter.clearSeededCredentials(
        inHomeDirectory: MCPClientInstaller.realHomeDirectory.path)
      {
        logger.info("Cleared the takt CLI's seeded credentials")
      }
    } catch {
      logger.error("Clearing the takt CLI's credentials failed: \(error)")
    }
  }

  private func setMCPSetupStatus(_ message: String, isError: Bool) {
    mcpSetupStatusMessage = message
    mcpSetupStatusIsError = isError
  }

  /// `org.nspasteboard.ConcealedType` is the convention clipboard-history
  /// managers honour to mean "don't archive this" — it is what password
  /// managers mark a copied password with. These payloads no longer carry a
  /// remote key, but they do carry a username and the shape of the user's
  /// setup, and a config snippet has no business outliving the paste.
  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(value, forType: .string)
    _ = NSPasteboard.general.setString(
      "", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
  }
}
