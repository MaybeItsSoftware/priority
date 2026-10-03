import PriorityCore
import SwiftUI

@MainActor
extension NativeMCPIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "link" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.integrations.mcpIntegrationEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(MCPIntegrationPluginSettingsView(manager: manager))
  }
}

private struct MCPIntegrationPluginSettingsView: View {
  @Environment(\.theme) private var theme
  var manager: AppCoordinator
  @State private var showsRawConfiguration = false

  private var integrations: IntegrationCoordinator { manager.integrations }

  var body: some View {
    @Bindable var manager = manager
    Section(header: MicroLabel("MCP Plugin")) {
      Toggle("Enable MCP integration", isOn: $manager.integrations.mcpIntegrationEnabled)
        .toggleStyle(.switch)

      if manager.integrations.mcpIntegrationEnabled {
        VStack(alignment: .leading, spacing: theme.space.md) {
          credentialsStep
          serverCommandStep
          clientStep
          statusMessage
          rawConfiguration
        }
        .padding(.top, theme.space.xs)
        .onAppear { integrations.refreshDetectedMCPClients() }
      } else {
        Text("MCP integration is disabled.")
          .foregroundStyle(theme.muted)
          .font(theme.captionFont)
      }
    }
  }

  // MARK: - Step 1: credentials

  @ViewBuilder
  private var credentialsStep: some View {
    // The server talks to the Checkvist API directly, so without a login every
    // tool call fails inside the AI client — a long way from here, with an error
    // that doesn't mention Priority.
    if integrations.hasMCPCredentials {
      stepRow(
        ok: true,
        title: "Checkvist connected",
        detail: manager.repository.activeCredentials.normalizedUsername
          + " — setting up a client copies this login into ~/.config/takt/config.json, "
          + "where the server reads it. Nothing below carries your key."
      )
    } else {
      stepRow(
        ok: false,
        title: "Connect Checkvist first",
        detail: "The MCP server signs in with your Checkvist credentials. "
          + "Open the Checkvist page in the sidebar, then come back."
      )
    }
  }

  // MARK: - Step 2: server command

  @ViewBuilder
  private var serverCommandStep: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      if integrations.hasResolvedMCPServerCommand {
        stepRow(
          ok: true,
          title: "Server command found",
          detail: integrations.mcpServerCommandPath,
          detailIsSelectable: true
        )
      } else {
        stepRow(
          ok: false,
          title: "Server command not found",
          detail: "Move Takt to /Applications, or set PRIORITY_MCP_EXECUTABLE_PATH."
        )
      }

      Button("Refresh") { integrations.refreshMCPServerCommandPath() }
        .controlSize(.small)
        .padding(.leading, theme.space.lg)
    }
  }

  // MARK: - Step 3: clients

  @ViewBuilder
  private var clientStep: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      Text("Add to an AI client")
        .font(theme.bodyFont(weight: .medium))

      if integrations.detectedMCPClients.isEmpty {
        Text(
          "No MCP clients detected. Copy the config below and paste it into your client's settings."
        )
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
      } else {
        // Re-running this on a client that is already set up rewrites its
        // entry, which is how a configuration written before the MCP server
        // moved into `Contents/Helpers/takt` gets updated, along with one written
        // under the old `priority` name. Those keep working either way — the
        // app's `--mcp-server` hands over to the same binary — so this is an
        // offer rather than a repair.
        Text("Already set up? Adding again updates the entry to the current command.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)

        ForEach(integrations.detectedMCPClients) { client in
          HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
            VStack(alignment: .leading, spacing: theme.space.xxs) {
              Text(client.displayName)
              Text(hint(for: client))
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 8)
            Button(actionTitle(for: client)) { integrations.setUpMCPClient(client) }
              .controlSize(.small)
              .disabled(!integrations.hasMCPCredentials)
          }
        }
      }
    }
  }

  private func actionTitle(for client: MCPClientDescriptor) -> String {
    switch client.installStyle {
    case .mergeConfigFile: "Add"
    case .terminalCommand: "Copy Command"
    case .pasteSnippet: "Copy Snippet"
    }
  }

  private func hint(for client: MCPClientDescriptor) -> String {
    switch client.installStyle {
    case .mergeConfigFile:
      "Merges into \(client.configPath), leaving your other servers alone"
    case .terminalCommand:
      "\(client.displayName) rewrites its own config — run the copied command instead"
    case .pasteSnippet:
      "\(client.configPath) has comments, so paste rather than overwrite"
    }
  }

  // MARK: - Status and fallback

  @ViewBuilder
  private var statusMessage: some View {
    if !integrations.mcpSetupStatusMessage.isEmpty {
      Text(integrations.mcpSetupStatusMessage)
        .font(theme.captionFont)
        .foregroundStyle(integrations.mcpSetupStatusIsError ? theme.danger : theme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var rawConfiguration: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      HStack {
        Button("Copy Client Config") { integrations.copyMCPClientConfigurationToClipboard() }
        Button("Open Guide") { integrations.openMCPServerGuide() }
        Spacer()
      }
      .controlSize(.small)

      DisclosureGroup("Show config JSON", isExpanded: $showsRawConfiguration) {
        ScrollView {
          Text(integrations.mcpClientConfigurationPreview(listId: manager.repository.listId))
            .font(theme.monoFont(size: theme.scale.caption))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120, maxHeight: 180)

        // Nothing is redacted any more because there is nothing to redact —
        // which is worth saying, since the old copy promised the opposite.
        Text(
          "This is exactly what gets copied and installed. No credentials in it: "
            + "the server reads those from the takt CLI's own config, which Takt writes "
            + "when you set up a client. Rotate your remote key in Takt and set up again."
        )
        .foregroundStyle(theme.muted)
        .font(theme.captionFont)
      }
      .font(theme.captionFont)
    }
  }

  // MARK: - Shared row

  private func stepRow(
    ok: Bool,
    title: String,
    detail: String,
    detailIsSelectable: Bool = false
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.xs) {
      Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(ok ? theme.success : theme.warning)
        .font(theme.captionFont)
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(title)
        Group {
          if detailIsSelectable {
            Text(detail).textSelection(.enabled)
          } else {
            Text(detail)
          }
        }
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }
}
