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
    Section(header: Text("AFFiNE Plugin")) {
      Toggle("Enable AFFiNE integration", isOn: $manager.integrations.affineIntegrationEnabled)
        .toggleStyle(.switch)

      if manager.integrations.affineIntegrationEnabled {
        VStack(alignment: .leading, spacing: 12) {
          helperSection
          workspaceSection
          filingSection

          if let statusMessage {
            Text(statusMessage)
              .font(.caption)
              .foregroundColor(statusIsError ? .red : .secondary)
              .textSelection(.enabled)
          }
        }
        .padding(.top, 4)
      } else {
        Text("AFFiNE integration is disabled.")
          .foregroundColor(.secondary)
          .font(.caption)
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
    VStack(alignment: .leading, spacing: 6) {
      Text("Server")
        .font(.caption)
        .foregroundColor(.secondary)

      if let resolved = plugin.resolvedServerCommandPath {
        Text(resolved)
          .font(.caption)
          .textSelection(.enabled)
      } else {
        Text("`affine-mcp` not found — install it with `npm install -g affine-mcp-server`.")
          .font(.caption)
          .foregroundColor(.red)
      }

      TextField("Path to affine-mcp (optional)", text: $serverCommandPath)
        .textFieldStyle(.roundedBorder)
        .onSubmit { plugin.serverCommandPath = serverCommandPath }

      // Priority never handles the AFFiNE password: the helper keeps its own
      // credentials, and saying so is the only way the user knows where to put
      // them.
      Text("Sign in once with `affine-mcp login`. Priority reuses that session.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private var workspaceSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Workspace")
        .font(.caption)
        .foregroundColor(.secondary)

      if workspaces.isEmpty {
        Text(
          plugin.workspaceId.isEmpty
            ? "Using the workspace affine-mcp is configured for."
            : plugin.workspaceId
        )
        .font(.caption)
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
    VStack(alignment: .leading, spacing: 6) {
      Text("Parent Document")
        .font(.caption)
        .foregroundColor(.secondary)

      TextField("Document id (optional)", text: $parentDocId)
        .textFieldStyle(.roundedBorder)
        .onSubmit { plugin.parentDocId = parentDocId }

      Text("A new checklist document is linked under this one, so it shows in the sidebar.")
        .font(.caption)
        .foregroundColor(.secondary)
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
