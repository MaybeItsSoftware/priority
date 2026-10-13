import Foundation
import TaktRustCore

/// The keys that would have made the change an agent card shows: "`dd` then
/// type “friday”". Worked out by the Rust core from the tool call
/// (`core/src/agent_hints.rs`), never by the model, against the commands with
/// the keys in force — so a rebound command's hint moves with it. See
/// `docs/agent-panel.md`.
public struct AgentKeyHintLine: Equatable, Sendable {
  public enum Part: Equatable, Sendable {
    /// A key in the catalogue's spelling; `ShortcutReference` draws it.
    case key(String)
    case text(String)
  }

  public let parts: [Part]

  public init(parts: [Part]) {
    self.parts = parts
  }

  /// The hint for one tool call, or nil when nothing in the app does the
  /// same. `commands` defaults to the catalogue with the user's keymap.
  public static func forTool(
    _ tool: String,
    input: JSONValue,
    commands: [WorkspaceCommand] = WorkspaceCommandCatalog.all
  ) -> AgentKeyHintLine? {
    agentKeyHint(tool: tool, inputJson: input.jsonString(), commands: commands.map(\.core)).map { hint in
      AgentKeyHintLine(
        parts: hint.parts.map { part in
          switch part {
          case .key(let key): .key(key)
          case .text(let text): .text(text)
          }
        })
    }
  }

  /// The hint as plain text, keys drawn as the palette draws them: "M M then
  /// choose the list". For help text and tests.
  public var plainText: String {
    parts.map { part in
      switch part {
      case .key(let key): ShortcutReference.displayKeys(forBinding: key).joined(separator: " ")
      case .text(let text): text
      }
    }.joined(separator: " ")
  }
}
