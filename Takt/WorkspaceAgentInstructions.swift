import Foundation
import Observation
import SwiftUI
import TaktCore
import TaktWorkspace

/// The user's standing instructions for the agent: one for the whole account,
/// and one per folder and per list, keyed by id.
///
/// Kept in the workspace database (`agent_instructions`, the Rust core's
/// `v25_agent_instructions`), where the agent's own `agent_instructions_set`
/// tool can keep them too, rather than in this Mac's preferences, where they
/// lived before. The store copies the old preferences in once
/// (`migrateAgentInstructionPreferences`). Each edit is an "Edit Agent
/// Instructions" undo step, and an edit made elsewhere — the agent, the CLI,
/// another device — arrives through the view model's reload, which calls
/// `reload()`.
@MainActor
@Observable final class WorkspaceAgentInstructions {
  /// How long the account field waits after the last keystroke before it
  /// saves, so typing a sentence is one undo step rather than one per letter.
  static let accountSaveDelay: Duration = .milliseconds(700)

  @ObservationIgnored var store: WorkspaceStore?
  /// Runs a write through the view model, so its failure is shown and the
  /// Undo menu's label moves.
  @ObservationIgnored var perform: (_ work: () throws -> Void) -> Void = { work in try? work() }

  private(set) var texts = WorkspaceAgentInstructionTexts()
  /// The account's text while the field is ahead of the database.
  private var pendingAccount: String?
  @ObservationIgnored private var accountSave: Task<Void, Never>?

  /// The account's instructions, as the settings field edits them: saved
  /// after a pause, or when anything else reads the instructions to send.
  var account: String {
    get { pendingAccount ?? texts.account }
    set {
      guard newValue != account else { return }
      pendingAccount = newValue
      accountSave?.cancel()
      accountSave = Task { [weak self] in
        try? await Task.sleep(for: Self.accountSaveDelay)
        guard !Task.isCancelled else { return }
        self?.saveAccount()
      }
    }
  }

  var folders: [String: String] { texts.folders }
  var lists: [String: String] { texts.lists }

  func folder(_ id: String) -> String { texts.folders[id] ?? "" }
  func list(_ id: String) -> String { texts.lists[id] ?? "" }

  /// Saves the account's text now if the field is ahead of the database.
  func saveAccount() {
    accountSave?.cancel()
    accountSave = nil
    guard let text = pendingAccount else { return }
    write(text, kind: .account, id: nil)
    pendingAccount = nil
  }

  /// Blank text removes the entry, so clearing the field leaves nothing behind.
  func setFolder(_ text: String, for id: String) { write(text, kind: .folder, id: id) }
  func setList(_ text: String, for id: String) { write(text, kind: .list, id: id) }

  /// Reads them again from the workspace. A pending account edit is kept:
  /// it is newer than anything there.
  func reload() {
    guard let store, let loaded = try? store.agentInstructionTexts() else { return }
    if texts != loaded { texts = loaded }
  }

  private func write(_ text: String, kind: AgentInstructionScope.Kind, id: String?) {
    guard let store else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let current: String =
      switch kind {
      case .account: texts.account
      case .folder: folder(id ?? "")
      case .list: list(id ?? "")
      }
    guard trimmed != current else { return }
    perform { try store.setAgentInstructions(trimmed, kind: kind, id: id) }
    reload()
  }
}

/// The field the instructions are written in, wherever they are edited: the
/// list and folder settings sheets and the Agent settings page. A few lines
/// tall and growing; Return still does what Return does in the sheet around
/// it, and ⌥Return is a new line.
struct AgentInstructionsField: View {
  @Environment(\.theme) private var theme
  let prompt: String
  @Binding var text: String
  var onSubmit: () -> Void = {}

  var body: some View {
    TextField("Agent instructions", text: $text, prompt: Text(prompt), axis: .vertical)
      .lineLimit(3...8)
      .themedTextField()
      .onSubmit(onSubmit)
      .help("What the agent should know or do here · ⌥↩ new line")
  }
}
