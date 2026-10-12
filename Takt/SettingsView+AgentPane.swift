import SwiftUI
import TaktCore
import TaktWorkspace

/// The Agent page: the standing instructions for the whole account, and where
/// the narrower ones are written.
extension SettingsView {
  @ViewBuilder
  var agentPane: some View {
    let instructions = workspace.agentInstructions
    Section {
      AgentInstructionsField(
        prompt: "e.g. Write task titles as verbs. I work Monday to Thursday.",
        text: Binding(get: { instructions.account }, set: { instructions.account = $0 }))
    } header: {
      Text("Instructions for every thread")
    } footer: {
      Text(
        "Sent ahead of your first message in a thread, and again whenever they change. "
          + "A folder's and a list's own instructions are written in its settings (oo on the list) "
          + "and follow these, the narrowest last, so they win where they disagree.")
    }

    let written = agentWrittenScopes
    if !written.isEmpty {
      Section {
        ForEach(written, id: \.id) { scope in
          SettingsRow(scope.label, detail: scope.text) {
            Button("Edit…") {
              workspace.editAgentInstructions(scope)
              AppDelegate.shared.showMainWindow()
            }
          }
        }
      } header: {
        Text("Written for folders and lists")
      }
    }
  }

  /// Every folder and list with instructions, folders first, by name.
  private var agentWrittenScopes: [AgentInstructionScope] {
    let instructions = workspace.agentInstructions
    let folders = workspace.folders
      .compactMap { folder -> AgentInstructionScope? in
        let text = instructions.folder(folder.id)
        return text.isEmpty ? nil : AgentInstructionScope(kind: .folder, id: folder.id, name: folder.name, text: text)
      }
    let lists = workspace.lists
      .compactMap { list -> AgentInstructionScope? in
        let text = instructions.list(list.id)
        return text.isEmpty ? nil : AgentInstructionScope(kind: .list, id: list.id, name: list.name, text: text)
      }
    return (folders + lists).sorted { ($0.kind == .folder ? 0 : 1, $0.name) < ($1.kind == .folder ? 0 : 1, $1.name) }
  }
}
