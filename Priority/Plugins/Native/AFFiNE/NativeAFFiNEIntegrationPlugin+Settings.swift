import PriorityCore
import SwiftUI

@MainActor
extension NativeAFFiNEIntegrationPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "square.stack.3d.up" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.integrations.affineIntegrationEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(AFFiNEIntegrationPluginSettingsView(manager: manager, plugin: self))
  }
}

private struct AFFiNEIntegrationPluginSettingsView: View {
  @Environment(\.theme) private var theme
  var manager: AppCoordinator
  let plugin: NativeAFFiNEIntegrationPlugin

  @State private var serverCommandPath: String = ""
  @State private var parentDocId: String = ""
  @State private var workspaces: [AFFiNEWorkspace] = []
  @State private var selectedWorkspaceId: String = ""
  @State private var isLoadingWorkspaces = false
  @State private var statusMessage: String?
  @State private var statusIsError = false

  var body: some View {
    @Bindable var manager = manager
    Section(header: MicroLabel("AFFiNE Plugin")) {
      Toggle("Enable AFFiNE integration", isOn: $manager.integrations.affineIntegrationEnabled)
        .toggleStyle(.switch)

      if manager.integrations.affineIntegrationEnabled {
        VStack(alignment: .leading, spacing: theme.space.md) {
          helperSection
          workspaceSection
          filingSection

          if let statusMessage {
            Text(statusMessage)
              .font(theme.captionFont)
              .foregroundStyle(statusIsError ? theme.danger : theme.muted)
              .textSelection(.enabled)
          }
        }
        .padding(.top, theme.space.xs)
      } else {
        Text("AFFiNE integration is disabled.")
          .foregroundStyle(theme.muted)
          .font(theme.captionFont)
      }
    }
    .onAppear {
      serverCommandPath = plugin.serverCommandPath
      parentDocId = plugin.parentDocId
      selectedWorkspaceId = plugin.workspaceId
    }
  }

  // MARK: - Sections

  private var helperSection: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text("Server")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)

      if let resolved = plugin.resolvedServerCommandPath {
        Text(resolved)
          .font(theme.captionFont)
          .textSelection(.enabled)
      } else {
        Text("`affine-mcp` not found — install it with `npm install -g affine-mcp-server`.")
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
      }

      TextField("Path to affine-mcp (optional)", text: $serverCommandPath)
        .textFieldStyle(.roundedBorder)
        .onSubmit { plugin.serverCommandPath = serverCommandPath }

      // Priority never handles the AFFiNE password: the helper keeps its own
      // credentials, and saying so is the only way the user knows where to put
      // them.
      Text("Sign in once with `affine-mcp login`. Takt reuses that session.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
    }
  }

  private var workspaceSection: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text("Workspace")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)

      if workspaces.isEmpty {
        Text(
          plugin.workspaceId.isEmpty
            ? "Using the workspace affine-mcp is configured for."
            : plugin.workspaceId
        )
        .font(theme.captionFont)
        .textSelection(.enabled)
      } else {
        Picker("Workspace", selection: $selectedWorkspaceId) {
          ForEach(workspaces) { workspace in
            Text(workspace.displayName).tag(workspace.id)
          }
        }
        .labelsHidden()
        .onChange(of: selectedWorkspaceId) { _, newValue in
          guard let workspace = workspaces.first(where: { $0.id == newValue }) else { return }
          plugin.selectWorkspace(workspace)
        }
      }

      HStack {
        Button(isLoadingWorkspaces ? "Loading…" : "Load Workspaces") {
          loadWorkspaces()
        }
        .disabled(isLoadingWorkspaces)

        if !plugin.workspaceId.isEmpty {
          Button("Clear") {
            plugin.workspaceId = ""
            selectedWorkspaceId = ""
            workspaces = []
          }
        }
      }
    }
  }

  private var filingSection: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text("Parent Document")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)

      TextField("Document id (optional)", text: $parentDocId)
        .textFieldStyle(.roundedBorder)
        .onSubmit { plugin.parentDocId = parentDocId }

      Text("A new checklist document is linked under this one, so it shows in the sidebar.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
    }
  }

  // MARK: - Actions

  /// Doubles as the connection test: listing workspaces is the cheapest call
  /// that proves the helper starts, signs in, and answers.
  private func loadWorkspaces() {
    plugin.serverCommandPath = serverCommandPath
    isLoadingWorkspaces = true
    statusMessage = nil

    Task { @MainActor in
      defer { isLoadingWorkspaces = false }
      do {
        let loaded = try await plugin.availableWorkspaces()
        workspaces = loaded
        if selectedWorkspaceId.isEmpty, let first = loaded.first {
          selectedWorkspaceId = first.id
          plugin.selectWorkspace(first)
        }
        statusIsError = loaded.isEmpty
        statusMessage =
          loaded.isEmpty
          ? "Connected, but this account has no workspaces."
          : "Connected. \(loaded.count) workspace\(loaded.count == 1 ? "" : "s") found."
      } catch {
        statusIsError = true
        statusMessage = error.localizedDescription
      }
    }
  }
}
