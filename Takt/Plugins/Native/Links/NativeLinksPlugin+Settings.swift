import AppKit
import SwiftUI
import TaktCore

@MainActor
extension NativeLinksPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "link" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    let vaults = obsidianVaults.count
    let vaultLabel = vaults == 1 ? "1 vault" : "\(vaults) vaults"
    return canSearchDrive ? "\(vaultLabel), Drive" : vaultLabel
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(LinksPluginSettingsView(plugin: self))
  }
}

private struct LinksPluginSettingsView: View {
  @Environment(\.theme) private var theme
  var plugin: NativeLinksPlugin

  var body: some View {
    @Bindable var plugin = plugin
    Section {
      VStack(alignment: .leading, spacing: theme.space.xs) {
        Text("Obsidian vaults")
          .font(theme.bodyFont(size: theme.scale.caption, weight: .medium))
        if plugin.obsidianVaults.isEmpty {
          Text(plugin.isIndexing ? "Looking for vaults…" : "No vaults found.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
        ForEach(plugin.obsidianVaults, id: \.self) { vault in
          HStack(spacing: theme.space.sm) {
            Image(systemName: "books.vertical").foregroundStyle(theme.muted)
            Text(vault.name)
            Text(vault.url.path)
              .font(theme.monoFont(size: theme.scale.caption))
              .foregroundStyle(theme.muted)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            if plugin.extraVaultPaths.contains(vault.url.path) {
              Button("Remove") {
                plugin.extraVaultPaths.removeAll { $0 == vault.url.path }
                Task { await plugin.reloadObsidianIndex() }
              }
            }
          }
        }
        HStack(spacing: theme.space.sm) {
          Button("Add a vault…") { chooseVault() }
          Button("Look again") { Task { await plugin.reloadObsidianIndex() } }
          Spacer()
          Text("\(plugin.obsidianEntries.count) notes and folders")
            .font(theme.monoFont(size: theme.scale.caption))
            .foregroundStyle(theme.muted)
        }
      }

      SettingsToggleRow("Search Google Drive by name", isOn: $plugin.isDriveSearchEnabled)
      Text(plugin.driveStatusDescription)
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
      if plugin.isDriveSearchEnabled {
        GoogleAccountSettingsSection(
          account: plugin.account, serviceName: "Google Drive", requiredScopes: GoogleAPIScope.driveSearch)
      }
    } header: {
      Text("Links plugin")
    } footer: {
      Text(
        """
        Typing pl, or ⌘⌃L, on a task opens the link picker: type to find a note or \
        folder in your vaults or, with Drive search on, a file in Drive; or \
        paste any address. Vaults are the ones Obsidian lists, the one your \
        daily notes are in, and any added here. Drive search needs the Drive \
        API and the drive.metadata.readonly scope in your Google Cloud project \
        (docs/links.md).
        """
      )
    }
    .task { await plugin.reloadObsidianIndex() }
  }

  private func chooseVault() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add vault"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let path = url.standardizedFileURL.path
    if !plugin.extraVaultPaths.contains(path) { plugin.extraVaultPaths.append(path) }
    Task { await plugin.reloadObsidianIndex() }
  }
}
