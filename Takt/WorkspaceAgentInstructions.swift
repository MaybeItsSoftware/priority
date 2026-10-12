import Foundation
import Observation
import SwiftUI
import TaktCore

/// The user's standing instructions for the agent: one for the whole account,
/// and one per folder and per list, keyed by id.
///
/// Kept in this Mac's preferences rather than the workspace database. Only the
/// Mac has an agent panel, so syncing them to the phones would carry text
/// nothing there reads, and a schema migration in the Rust core for it would
/// be the expensive way to store three strings. An entry for a list or folder
/// that has since been deleted is never asked for, and costs nothing.
@MainActor
@Observable final class WorkspaceAgentInstructions {
  static let accountKey = "agentInstructionsAccountV1"
  static let foldersKey = "agentInstructionsByFolderV1"
  static let listsKey = "agentInstructionsByListV1"

  @ObservationIgnored private let defaults: UserDefaults

  var account: String {
    didSet { defaults.set(account, forKey: Self.accountKey) }
  }
  private(set) var folders: [String: String] {
    didSet { defaults.set(folders, forKey: Self.foldersKey) }
  }
  private(set) var lists: [String: String] {
    didSet { defaults.set(lists, forKey: Self.listsKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    account = defaults.string(forKey: Self.accountKey) ?? ""
    folders = defaults.dictionary(forKey: Self.foldersKey) as? [String: String] ?? [:]
    lists = defaults.dictionary(forKey: Self.listsKey) as? [String: String] ?? [:]
  }

  func folder(_ id: String) -> String { folders[id] ?? "" }
  func list(_ id: String) -> String { lists[id] ?? "" }

  /// Blank text removes the entry, so clearing the field leaves nothing behind.
  func setFolder(_ text: String, for id: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if folders[id] != (trimmed.isEmpty ? nil : trimmed) { folders[id] = trimmed.isEmpty ? nil : trimmed }
  }

  func setList(_ text: String, for id: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if lists[id] != (trimmed.isEmpty ? nil : trimmed) { lists[id] = trimmed.isEmpty ? nil : trimmed }
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
