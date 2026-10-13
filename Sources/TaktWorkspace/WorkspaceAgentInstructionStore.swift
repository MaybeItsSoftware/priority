import Foundation
import TaktCore
import TaktRustCore

/// The agent panel's standing instructions as the workspace keeps them: the
/// account's, and each folder's and list's by id. Blank scopes are absent.
///
/// The table (`agent_instructions`, `v25_agent_instructions`) and every read
/// and write are the Rust core's (`core/src/agent_instructions.rs`), the same
/// functions the CLI's `agent_instructions_get` and `agent_instructions_set`
/// call, so the agent can keep them too. See `docs/agent-panel.md`.
public struct WorkspaceAgentInstructionTexts: Equatable, Sendable {
  public var account: String
  public var folders: [String: String]
  public var lists: [String: String]

  public init(account: String = "", folders: [String: String] = [:], lists: [String: String] = [:]) {
    self.account = account
    self.folders = folders
    self.lists = lists
  }

  public var isEmpty: Bool { account.isEmpty && folders.isEmpty && lists.isEmpty }
}

extension WorkspaceStore {

  /// Every scope's instructions. A row whose folder or list has been deleted
  /// is left out.
  public func agentInstructionTexts() throws -> WorkspaceAgentInstructionTexts {
    let rows = try Self.mappingCoreErrors { try core.agentInstructions() }
    var texts = WorkspaceAgentInstructionTexts()
    for row in rows {
      switch row.kind {
      case .account: texts.account = row.text
      case .folder: if let id = row.id { texts.folders[id] = row.text }
      case .list: if let id = row.id { texts.lists[id] = row.text }
      }
    }
    return texts
  }

  /// Replaces one scope's instructions as one "Edit Agent Instructions" undo
  /// step, or none when the text is what it holds already. Blank text clears
  /// the scope. Returns the text it holds now, trimmed.
  @discardableResult
  public func setAgentInstructions(_ text: String, kind: AgentInstructionScope.Kind, id: String?) throws -> String {
    try coreWrite {
      try core.setAgentInstructions(
        kind: kind.coreKind, id: id, text: text, append: false, nowMs: Self.nowMs())
    }
  }

  /// Copies instructions kept somewhere older into the scopes that have none,
  /// outside the undo journal. Returns how many it wrote.
  @discardableResult
  public func importAgentInstructions(_ texts: WorkspaceAgentInstructionTexts) throws -> Int {
    var seeds = [AgentInstructionSeed(kind: .account, id: nil, text: texts.account)]
    seeds += texts.folders.sorted { $0.key < $1.key }.map { AgentInstructionSeed(kind: .folder, id: $0.key, text: $0.value) }
    seeds += texts.lists.sorted { $0.key < $1.key }.map { AgentInstructionSeed(kind: .list, id: $0.key, text: $0.value) }
    let written = try coreWrite { try core.importAgentInstructions(seeds: seeds, nowMs: Self.nowMs()) }
    return Int(written)
  }

  /// The preference keys the Mac kept the instructions under before
  /// `v25_agent_instructions`, and the one that says they have been copied.
  public enum LegacyAgentInstructionKeys {
    public static let account = "agentInstructionsAccountV1"
    public static let folders = "agentInstructionsByFolderV1"
    public static let lists = "agentInstructionsByListV1"
    public static let migrated = "agentInstructionsInWorkspaceV1"
  }

  /// Copies the instructions this Mac kept in its preferences into the
  /// workspace, once: where a scope already has text (written by another
  /// device, or the agent) it is kept. The preferences are left as they were,
  /// like `LegacyNameMigration`, so an older build still finds them. Returns
  /// how many scopes it filled; zero when it had already run.
  @discardableResult
  public func migrateAgentInstructionPreferences(from defaults: UserDefaults) throws -> Int {
    guard !defaults.bool(forKey: LegacyAgentInstructionKeys.migrated) else { return 0 }
    let legacy = WorkspaceAgentInstructionTexts(
      account: defaults.string(forKey: LegacyAgentInstructionKeys.account) ?? "",
      folders: defaults.dictionary(forKey: LegacyAgentInstructionKeys.folders) as? [String: String] ?? [:],
      lists: defaults.dictionary(forKey: LegacyAgentInstructionKeys.lists) as? [String: String] ?? [:])
    let written = legacy.isEmpty ? 0 : try importAgentInstructions(legacy)
    defaults.set(true, forKey: LegacyAgentInstructionKeys.migrated)
    return written
  }

  private static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

extension AgentInstructionScope.Kind {
  var coreKind: AgentInstructionKind {
    switch self {
    case .account: .account
    case .folder: .folder
    case .list: .list
    }
  }
}
