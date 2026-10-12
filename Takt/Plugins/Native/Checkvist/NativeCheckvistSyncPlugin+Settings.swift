import TaktCore
import SwiftUI

@MainActor
extension NativeCheckvistSyncPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "checkmark.circle" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.checkvist.isEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(CheckvistSyncPluginSettingsView(manager: manager))
  }
}

private let checkvistAPIKeyURL = URL(string: "https://checkvist.com/auth/profile")!

private struct CheckvistSyncPluginSettingsView: View {
  @Environment(\.theme) private var theme
  var manager: AppCoordinator
  @State private var didAutoloadLists = false
  @State private var isImporting = false

  private var checkvist: CheckvistAccount { manager.checkvist }

  private var connectionState: CheckvistConnectionState {
    checkvist.connectionState
  }

  private var isBusy: Bool {
    checkvist.isLoading || isImporting
  }

  private var connectButtonLabel: String {
    switch connectionState {
    case .connecting: return "Connecting…"
    case .connected: return "Reconnect"
    case .disconnected, .awaitingConnect: return "Connect"
    }
  }

  var body: some View {
    Group {
      Section {
        SettingsToggleRow(
          "Import from Checkvist",
          detail:
            "Copies your Checkvist lists into the workspace, once each. The copies are yours to edit; nothing is written back to Checkvist.",
          isOn: Binding(
            get: { checkvist.isEnabled },
            set: { checkvist.isEnabled = $0 }
          )
        )
      } header: {
        Text("Checkvist")
      }

      if checkvist.isEnabled {
      // The banner and each numbered step are rows of the panel, so the
      // hairlines between them do the work the stack's spacing used to.
      Section {
        connectionStatusBanner

        VStack(alignment: .leading, spacing: theme.space.sm) {
          stepHeader(number: 1, title: "Enter your Checkvist credentials")
          VStack(alignment: .leading, spacing: theme.space.sm) {
            Text("Email")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
            TextField(
              "",
              text: Binding(
                get: { checkvist.username },
                set: { checkvist.username = $0 }
              ),
              prompt: Text("email@example.com")
            )
              .themedTextField()
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
                get: { checkvist.remoteKey },
                set: { checkvist.remoteKey = $0 }
              ),
              prompt: Text("Paste your key")
            )
              .themedTextField()
              .labelsHidden()
          }

          if checkvist.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Use saved Keychain key") {
              checkvist.loadCredentialsFromKeychain()
            }
            .help("Reads the saved Checkvist key only after you explicitly request it.")
          }
        }

        VStack(alignment: .leading, spacing: theme.space.sm) {
          stepHeader(number: 2, title: "Connect")
          HStack(spacing: theme.space.sm) {
            Button(connectButtonLabel) {
              Task { await checkvist.loadLists() }
            }
            .buttonStyle(FocusActionButtonStyle(prominent: true))
            .disabled(isBusy || !checkvist.hasCredentials)

            if isBusy {
              ProgressView().scaleEffect(0.7)
            }
            Spacer(minLength: 0)
          }
        }

        if case .connected = connectionState {
          VStack(alignment: .leading, spacing: theme.space.sm) {
            stepHeader(number: 3, title: "Choose the lists to import")
            ForEach(checkvist.availableLists) { list in
              SettingsToggleRow(
                list.name,
                detail: isImported(list) ? "In the workspace" : nil,
                isOn: Binding(
                  get: { checkvist.isImportEnabled(listId: list.id) },
                  set: { checkvist.setImportEnabled($0, listId: list.id) }
                )
              )
            }
            HStack(spacing: theme.space.sm) {
              Button("Import now") {
                Task {
                  isImporting = true
                  defer { isImporting = false }
                  await manager.importCheckvistNow?()
                }
              }
              .disabled(isBusy)
              Text("New lists are also copied whenever Takt comes to the front.")
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
              Spacer(minLength: 0)
            }
          }

          VStack(alignment: .leading, spacing: theme.space.sm) {
            Text("Default list for the takt command")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
            Picker("", selection: Binding(
              get: { checkvist.defaultListId },
              set: { checkvist.defaultListId = $0 }
            )) {
              Text("None").tag("")
              if !checkvist.defaultListId.isEmpty && !isDefaultListAvailable {
                Text("List \(checkvist.defaultListId)").tag(checkvist.defaultListId)
              }
              ForEach(checkvist.availableLists) { list in
                Text(list.name).tag(String(list.id))
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
          }
        }

        if let errorMessage = checkvist.errorMessage {
          errorBanner(message: errorMessage) {
            checkvist.errorMessage = nil
          }
        }
      } header: {
        Text("Connection")
      }
      }
    }
    .task {
      guard !didAutoloadLists else { return }
      didAutoloadLists = true
      if checkvist.hasCredentials && checkvist.availableLists.isEmpty {
        await checkvist.loadLists()
      }
    }
  }

  private var isDefaultListAvailable: Bool {
    checkvist.availableLists.contains { String($0.id) == checkvist.defaultListId }
  }

  /// Whether the workspace already holds a copy of `list`; such a list is not
  /// imported again unless its copy is deleted.
  private func isImported(_ list: CheckvistList) -> Bool {
    let mapping =
      UserDefaults.standard.dictionary(forKey: WorkspaceViewModel.checkvistWorkspaceListIDsKey)
      as? [String: String] ?? [:]
    return mapping[String(list.id)] != nil
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
      .accessibilityLabel("Dismiss")
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
        message: "Enter your Checkvist email and OpenAPI key below to import your lists."
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
      let email = checkvist.username
      let listWord = listCount == 1 ? "list" : "lists"
      return StatusStyle(
        iconName: "checkmark.circle.fill",
        tint: theme.success,
        title: "Connected as \(email)",
        message: "\(listCount) \(listWord) on Checkvist. Choose which to copy below."
      )
    }
  }
}
