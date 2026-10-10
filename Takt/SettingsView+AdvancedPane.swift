import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace
import UniformTypeIdentifiers

/// The Advanced page: the workspace written out to a file, diagnostics, and
/// where the app keeps its files.
extension SettingsView {
  @ViewBuilder
  var advancedPane: some View {
    Section {
      SettingsRow(
        "Export workspace",
        detail: "Every list, archived ones included, with its whole task tree and notes."
      ) {
        HStack(spacing: theme.space.xs) {
          ForEach(WorkspaceExportFormat.allCases) { format in
            Button("\(format.title)…") { exportWorkspace(format) }
          }
        }
      }
      if let exportStatus {
        Label(
          exportStatus.message,
          systemImage: exportStatus.isError ? "exclamationmark.triangle" : "checkmark"
        )
        .font(theme.captionFont)
        .foregroundStyle(exportStatus.isError ? theme.danger : theme.success)
      }
    } header: {
      Text("Your data")
    } footer: {
      Text("Markdown reads anywhere; JSON keeps every field, for a backup or a script.")
    }

    Section {
      SettingsRow(
        "Diagnostics",
        detail: "What state the app is in, what is unhealthy, and what went wrong this session."
      ) {
        Button("Open diagnostics") {
          checkvistManager.popoverChrome.showsDiagnostics = true
          AppDelegate.shared.showMainWindow()
        }
        .commandHelp(.windowShowDiagnostics)
      }
      SettingsRow(
        "App data",
        detail: AppIdentity.applicationSupportDirectory().path(percentEncoded: false)
      ) {
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([AppIdentity.applicationSupportDirectory()])
        }
      }
    } header: {
      Text("Support")
    }

    #if DEBUG
      Section {
        Text("⌘⇧K toggles keychain mode for development.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
        HStack {
          Spacer(minLength: 0)
          Button("Reset onboarding state", role: .destructive) {
            checkvistManager.resetOnboardingForDebug()
          }
        }
      } header: {
        Text("Debug")
      }
    #endif
  }

  private func exportWorkspace(_ format: WorkspaceExportFormat) {
    let document: String
    do {
      document = try workspace.exportDocument(format)
    } catch {
      exportStatus = (error.localizedDescription, true)
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Takt workspace.\(format.fileExtension)"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try document.write(to: url, atomically: true, encoding: .utf8)
        exportStatus = ("Saved \(url.lastPathComponent).", false)
      } catch {
        exportStatus = ("Could not save: \(error.localizedDescription)", true)
      }
    }
  }
}
