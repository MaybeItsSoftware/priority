import PriorityCore
import SwiftUI

@MainActor
extension NativeCheckvistSyncPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "checkmark.circle" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.repository.checkvistIntegrationEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(CheckvistSyncPluginSettingsView(manager: manager))
  }
}

private let checkvistAPIKeyURL = URL(string: "https://checkvist.com/auth/profile")!

private struct CheckvistSyncPluginSettingsView: View {
  @Environment(\.theme) private var theme
  var manager: AppCoordinator
  @State private var isLoadingLists = false
  @State private var didAutoloadLists = false
  @State private var uploadDestinationListId = ""
  @State private var showingOverwriteLocalAlert = false
  @State private var showingOverwriteRemoteAlert = false

  private var connectionState: CheckvistConnectionState {
    manager.repository.checkvistConnectionState
  }

  private var isBusy: Bool {
    manager.repository.isLoading || isLoadingLists
  }

  private var connectButtonLabel: String {
    switch connectionState {
    case .connecting: return "Connecting…"
    case .connected: return "Reconnect"
    case .disconnected, .awaitingConnect: return "Connect"
    }
  }

  var body: some View {
    @Bindable var manager = manager
    Group {
      Section(header: MicroLabel("Checkvist sync")) {
        Toggle(
          "Enable Checkvist sync",
          isOn: Binding(
            get: { manager.repository.checkvistIntegrationEnabled },
            set: { manager.repository.checkvistIntegrationEnabled = $0 }
          )
        )
          .toggleStyle(.switch)
        Text(
          "When disabled, Takt runs offline and your Checkvist credentials and list selection are preserved for when you re-enable it."
        )
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
      }

      if manager.repository.checkvistIntegrationEnabled {
      Section(header: MicroLabel("Connection")) {
        VStack(alignment: .leading, spacing: theme.space.md) {
          connectionStatusBanner

          stepHeader(number: 1, title: "Enter your Checkvist credentials")
          VStack(alignment: .leading, spacing: theme.space.sm) {
            Text("Email")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
            TextField(
              "",
              text: Binding(
                get: { manager.repository.username },
                set: { manager.repository.username = $0 }
              ),
              prompt: Text("email@example.com")
            )
              .textFieldStyle(.roundedBorder)
              .labelsHidden()
              .autocorrectionDisabled()

            HStack(spacing: theme.space.xs) {
              Text("OpenAPI key")
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
              Spacer(minLength: 0)
              Link("Where do I find this?", destination: checkvistAPIKeyURL)
                .font(theme.captionFont)
            }
            SecureField(
              "",
              text: Binding(
                get: { manager.repository.remoteKey },
                set: { manager.repository.remoteKey = $0 }
              ),
              prompt: Text("Paste your key")
            )
              .textFieldStyle(.roundedBorder)
              .labelsHidden()
          }

          if manager.repository.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Use saved Keychain key") {
              manager.loadCredentialsFromKeychain()
            }
            .help("Reads the saved Checkvist key only after you explicitly request it.")
          }

          stepHeader(number: 2, title: "Connect")
          HStack(spacing: theme.space.sm) {
            Button(connectButtonLabel) {
              Task { await loadLists(assignFirstIfMissing: false) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || !manager.repository.canAttemptLogin)

            if isBusy {
              ProgressView().scaleEffect(0.7)
            }
            Spacer(minLength: 0)
          }

          if case .connected(let listCount) = connectionState {
            stepHeader(number: 3, title: "Choose a workspace")
            VStack(alignment: .leading, spacing: theme.space.xs) {
              Picker("", selection: activeWorkspaceBinding) {
                Text("Offline workspace").tag("")
                if !manager.repository.listId.isEmpty && !isCurrentListInAvailableLists {
                  Text("Current list (\(manager.repository.listId))").tag(manager.repository.listId)
                }
                ForEach(manager.repository.availableLists) { list in
                  Text(list.name).tag(String(list.id))
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)

              Text(workspaceCaption(listCount: listCount))
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
            }
          }

          if let errorMessage = manager.repository.errorMessage {
            errorBanner(message: errorMessage) {
              manager.repository.errorMessage = nil
            }
          }
        }
        .padding(.top, theme.space.xs)
      }

      if case .connected = connectionState {
        offlineSyncAndConflictResolutionSection
      }
      }
    }
    .task {
      guard !didAutoloadLists else { return }
      didAutoloadLists = true
      if manager.repository.canAttemptLogin && manager.repository.availableLists.isEmpty {
        await loadLists(assignFirstIfMissing: false)
      }
      seedUploadDestinationIfNeeded()
    }
    .onChange(of: manager.repository.availableLists.map(\.id)) { _, _ in
      seedUploadDestinationIfNeeded()
    }
    .onChange(of: manager.repository.listId) { _, _ in
      if !manager.repository.listId.isEmpty {
        uploadDestinationListId = manager.repository.listId
      }
    }
  }

  @ViewBuilder
  private var connectionStatusBanner: some View {
    let style = statusStyle(for: connectionState)
    HStack(alignment: .top, spacing: theme.space.sm) {
      Image(systemName: style.iconName)
        .font(theme.titleFont)
        .foregroundStyle(style.tint)
        .frame(width: WorkspaceSidebarMetrics.iconWidth)
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(style.title)
          .font(theme.bodyFont(weight: .medium))
        Text(style.message)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .settingsStatusSurface(theme, tint: style.tint)
  }

  private func errorBanner(message: String, dismiss: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: theme.space.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(theme.danger)
        .frame(width: WorkspaceSidebarMetrics.iconWidth)
      Text(message)
        .font(theme.captionFont)
        .foregroundStyle(theme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(theme.microLabelFont)
          .frame(width: theme.space.lg, height: theme.space.lg)
      }
      .buttonStyle(.plain)
      .foregroundStyle(theme.muted)
    }
    .settingsStatusSurface(theme, tint: theme.danger)
  }

  private func stepHeader(number: Int, title: String) -> some View {
    HStack(spacing: theme.space.sm) {
      Text("\(number)")
        // A step number is a status-less label, so it takes the tinted
        // treatment in the primary hue rather than a solid accent disc.
        .font(theme.numeralFont(theme.type.microLabel.size, weight: .medium))
        .foregroundStyle(theme.primary)
        .frame(width: WorkspaceSidebarMetrics.iconWidth, height: WorkspaceSidebarMetrics.iconWidth)
        .themedSurface(
          theme, fill: theme.color(.primary, opacity: Theme.statusFillOpacity),
          radius: theme.controlRadius, stroke: theme.color(.primary, opacity: Theme.statusBorderOpacity))
      Text(title)
        .font(theme.bodyFont(weight: .medium))
    }
  }

  private struct StatusStyle {
    let iconName: String
    let tint: Color
    let title: String
    let message: String
  }

  private func statusStyle(for state: CheckvistConnectionState) -> StatusStyle {
    switch state {
    case .disconnected:
      return StatusStyle(
        iconName: "circle.dashed",
        tint: theme.muted,
        title: "Not connected",
        message: "Enter your Checkvist email and OpenAPI key below to sync. You can keep working offline without connecting."
      )
    case .connecting:
      return StatusStyle(
        iconName: "arrow.triangle.2.circlepath",
        tint: theme.primary,
        title: "Connecting…",
        message: "Signing in and loading your lists."
      )
    case .awaitingConnect:
      return StatusStyle(
        iconName: "bolt.horizontal.circle",
        tint: theme.warning,
        title: "Credentials entered",
        message: "Click Connect to sign in and load your lists."
      )
    case .connected(let listCount):
      let email = manager.repository.username
      let listWord = listCount == 1 ? "list" : "lists"
      return StatusStyle(
        iconName: "checkmark.circle.fill",
        tint: theme.success,
        title: "Connected as \(email)",
        message: "\(listCount) \(listWord) available. Pick one below."
      )
    }
  }

  private var activeWorkspaceBinding: Binding<String> {
    Binding(
      get: { manager.repository.listId },
      set: { newValue in
        Task { await manager.syncService.switchCheckvistList(to: newValue) }
      }
    )
  }

  private var isCurrentListInAvailableLists: Bool {
    manager.repository.availableLists.contains { String($0.id) == manager.repository.listId }
  }

  private func workspaceCaption(listCount: Int) -> String {
    if manager.repository.listId.isEmpty {
      return "Pick a Checkvist list above to start syncing."
    }
    if let active = manager.repository.availableLists.first(where: { String($0.id) == manager.repository.listId }) {
      return "Takt is syncing with “\(active.name)”."
    }
    return "Takt is syncing with list ID \(manager.repository.listId)."
  }

  private var offlineSyncAndConflictResolutionSection: some View {
    Section(header: MicroLabel("Offline sync and conflict resolution")) {
      VStack(alignment: .leading, spacing: theme.space.sm) {
        Text("Your offline workspace currently has \(manager.repository.offlineOpenTaskCount) tasks.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)

        Text("Select a strategy to synchronize your local offline tasks with the remote Checkvist list:")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .padding(.bottom, theme.space.xs)

        if !manager.repository.availableLists.isEmpty {
          Picker("Checkvist List", selection: $uploadDestinationListId) {
            ForEach(manager.repository.availableLists) { list in
              Text("\(list.name) (\(list.id))").tag(String(list.id))
            }
          }
          .pickerStyle(.menu)
        }

        VStack(alignment: .leading, spacing: theme.space.md) {
          // Option 1: Merge
          VStack(alignment: .leading, spacing: theme.space.xs) {
            Button("Merge Local Tasks with Remote") {
              Task {
                _ = await manager.syncService.uploadOfflineTasksToCheckvist(
                  destinationListId: uploadDestinationListId
                )
              }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || manager.repository.offlineOpenTaskCount == 0 || uploadDestinationListId.isEmpty)

            Text("Uploads all local offline tasks to the selected remote list without deleting anything.")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
          }

          // Option 2: Overwrite Local (Use Remote)
          VStack(alignment: .leading, spacing: theme.space.xs) {
            Button("Keep Remote (Overwrite Local)") {
              showingOverwriteLocalAlert = true
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || manager.repository.listId.isEmpty)

            Text("Replaces all local offline tasks with the tasks from the selected remote Checkvist list.")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
          }

          // Option 3: Overwrite Remote (Use Local)
          VStack(alignment: .leading, spacing: theme.space.xs) {
            Button("Keep Local (Overwrite Remote)", role: .destructive) {
              showingOverwriteRemoteAlert = true
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || uploadDestinationListId.isEmpty)

            Text("Deletes all tasks currently on the remote Checkvist list and uploads your local offline tasks.")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
          }
        }
      }
      .padding(.top, theme.space.xs)
      .alert("Overwrite Local Tasks?", isPresented: $showingOverwriteLocalAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Overwrite", role: .destructive) {
          Task {
            await manager.syncService.overwriteLocalWithRemoteTasks()
          }
        }
      } message: {
        Text("Are you sure you want to overwrite your local tasks? This will replace your local offline tasks with the remote list tasks.")
      }
      .alert("Overwrite Remote List?", isPresented: $showingOverwriteRemoteAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Overwrite", role: .destructive) {
          Task {
            _ = await manager.syncService.overwriteRemoteWithLocalTasks(
              destinationListId: uploadDestinationListId
            )
          }
        }
      } message: {
        Text("Are you sure you want to overwrite the remote list? This will delete all tasks currently on the remote Checkvist list and upload your local tasks.")
      }
    }
  }

  @MainActor
  private func loadLists(assignFirstIfMissing: Bool) async {
    isLoadingLists = true
    defer { isLoadingLists = false }
    _ = await manager.syncService.loadCheckvistLists(assignFirstIfMissing: assignFirstIfMissing)
    seedUploadDestinationIfNeeded()
  }

  private func seedUploadDestinationIfNeeded() {
    guard !manager.repository.availableLists.isEmpty else {
      uploadDestinationListId = ""
      return
    }

    let listIDs = Set(manager.repository.availableLists.map { String($0.id) })

    if !uploadDestinationListId.isEmpty, !listIDs.contains(uploadDestinationListId) {
      uploadDestinationListId = ""
    }

    if uploadDestinationListId.isEmpty {
      if listIDs.contains(manager.repository.listId) {
        uploadDestinationListId = manager.repository.listId
      } else if let first = manager.repository.availableLists.first {
        uploadDestinationListId = String(first.id)
      }
    }
  }
}
