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
      Section(header: Text("Checkvist Sync")) {
        Toggle(
          "Enable Checkvist sync",
          isOn: Binding(
            get: { manager.repository.checkvistIntegrationEnabled },
            set: { manager.repository.checkvistIntegrationEnabled = $0 }
          )
        )
        Text(
          "When disabled, Priority runs offline and your Checkvist credentials and list selection are preserved for when you re-enable it."
        )
        .font(.caption)
        .foregroundColor(.secondary)
      }

      if manager.repository.checkvistIntegrationEnabled {
      Section(header: Text("Connection")) {
        VStack(alignment: .leading, spacing: 14) {
          connectionStatusBanner

          stepHeader(number: 1, title: "Enter your Checkvist credentials")
          VStack(alignment: .leading, spacing: 8) {
            Text("Email")
              .font(.caption)
              .foregroundColor(.secondary)
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

            HStack(spacing: 6) {
              Text("OpenAPI key")
                .font(.caption)
                .foregroundColor(.secondary)
              Spacer(minLength: 0)
              Link("Where do I find this?", destination: checkvistAPIKeyURL)
                .font(.caption)
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
          HStack(spacing: 8) {
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
            VStack(alignment: .leading, spacing: 6) {
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
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }

          if let errorMessage = manager.repository.errorMessage {
            errorBanner(message: errorMessage) {
              manager.repository.errorMessage = nil
            }
          }
        }
        .padding(.top, 4)
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
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: style.iconName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(style.tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(style.title)
          .font(.system(size: 12, weight: .semibold))
        Text(style.message)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(style.tint.opacity(0.08))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(style.tint.opacity(0.3), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func errorBanner(message: String, dismiss: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.red)
        .frame(width: 18)
      Text(message)
        .font(.caption)
        .foregroundColor(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)
      .foregroundColor(.secondary)
    }
    .padding(10)
    .background(Color.red.opacity(0.08))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.red.opacity(0.3), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func stepHeader(number: Int, title: String) -> some View {
    HStack(spacing: 8) {
      Text("\(number)")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundColor(.white)
        .frame(width: 18, height: 18)
        .background(Circle().fill(Color.accentColor))
      Text(title)
        .font(.system(size: 12, weight: .semibold))
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
        tint: .secondary,
        title: "Not connected",
        message: "Enter your Checkvist email and OpenAPI key below to sync. You can keep working offline without connecting."
      )
    case .connecting:
      return StatusStyle(
        iconName: "arrow.triangle.2.circlepath",
        tint: .accentColor,
        title: "Connecting…",
        message: "Signing in and loading your lists."
      )
    case .awaitingConnect:
      return StatusStyle(
        iconName: "bolt.horizontal.circle",
        tint: .orange,
        title: "Credentials entered",
        message: "Click Connect to sign in and load your lists."
      )
    case .connected(let listCount):
      let email = manager.repository.username
      let listWord = listCount == 1 ? "list" : "lists"
      return StatusStyle(
        iconName: "checkmark.circle.fill",
        tint: .green,
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
      return "Priority is syncing with “\(active.name)”."
    }
    return "Priority is syncing with list ID \(manager.repository.listId)."
  }

  private var offlineSyncAndConflictResolutionSection: some View {
    Section(header: Text("Offline Sync & Conflict Resolution")) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Your offline workspace currently has \(manager.repository.offlineOpenTaskCount) tasks.")
          .font(.caption)
          .foregroundColor(.secondary)

        Text("Select a strategy to synchronize your local offline tasks with the remote Checkvist list:")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.bottom, 4)

        if !manager.repository.availableLists.isEmpty {
          Picker("Checkvist List", selection: $uploadDestinationListId) {
            ForEach(manager.repository.availableLists) { list in
              Text("\(list.name) (\(list.id))").tag(String(list.id))
            }
          }
          .pickerStyle(.menu)
        }

        VStack(alignment: .leading, spacing: 12) {
          // Option 1: Merge
          VStack(alignment: .leading, spacing: 4) {
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
              .font(.caption2)
              .foregroundColor(.secondary)
          }

          // Option 2: Overwrite Local (Use Remote)
          VStack(alignment: .leading, spacing: 4) {
            Button("Keep Remote (Overwrite Local)") {
              showingOverwriteLocalAlert = true
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || manager.repository.listId.isEmpty)

            Text("Replaces all local offline tasks with the tasks from the selected remote Checkvist list.")
              .font(.caption2)
              .foregroundColor(.secondary)
          }

          // Option 3: Overwrite Remote (Use Local)
          VStack(alignment: .leading, spacing: 4) {
            Button("Keep Local (Overwrite Remote)", role: .destructive) {
              showingOverwriteRemoteAlert = true
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || uploadDestinationListId.isEmpty)

            Text("Deletes all tasks currently on the remote Checkvist list and uploads your local offline tasks.")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
      }
      .padding(.top, 4)
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
