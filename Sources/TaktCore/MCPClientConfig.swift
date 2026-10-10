import Foundation
import TaktRustCore

/// One stdio MCP server, in the shape every supported client expects.
///
/// The shape itself — `command`, `args`, `env` only when it holds something,
/// `type` only when asked for — is the Rust core's (`core/src/client_config.rs`).
public struct MCPServerEntry: Equatable {
  public let command: String
  public let args: [String]
  public let env: [String: String]
  /// `"stdio"` for clients that demand an explicit transport (VS Code); `nil`
  /// where the presence of `command` is enough.
  public let transportType: String?

  public init(command: String, args: [String], env: [String: String], transportType: String? = nil) {
    self.command = command
    self.args = args
    self.env = env
    self.transportType = transportType
  }

  var core: McpServerEntry {
    McpServerEntry(command: command, args: args, env: env, transportType: transportType)
  }

  public var jsonObject: [String: Any] {
    let json = mcpEntryJson(entry: core)
    return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
  }
}

public enum MCPConfigWriteOutcome: Equatable {
  case added
  case updated
  case unchanged

  init(core outcome: ConfigWriteOutcome) {
    switch outcome {
    case .added: self = .added
    case .updated: self = .updated
    case .unchanged: self = .unchanged
    }
  }
}

public enum MCPConfigError: LocalizedError, Equatable {
  case unreadableConfig(client: String, path: String)
  case serversKeyNotAnObject(client: String, key: String)
  case encodingFailed

  public var errorDescription: String? {
    switch self {
    case .unreadableConfig(let client, let path):
      return
        "\(client)'s config isn't valid JSON, so it wasn't touched. Fix or move \(path) and try again."
    case .serversKeyNotAnObject(let client, let key):
      return "\(client)'s config has a \"\(key)\" entry that isn't an object, so it wasn't touched."
    case .encodingFailed:
      return "Could not encode the MCP configuration."
    }
  }
}

/// The Rust core's MCP client config format (`core/src/client_config.rs`),
/// with the Swift signatures the app calls.
public enum MCPClientConfigWriter {
  /// Merges `entry` into an existing config, preserving every other key and
  /// every other server — except an entry this app wrote under one of its
  /// earlier names (`MCPClientCatalog.legacyServerNames`), which the new entry
  /// replaces.
  ///
  /// Returns `.unchanged` when the entry is already identical, so a repeat
  /// install doesn't rewrite the file (and doesn't claim it did something).
  /// Keys come back sorted.
  public static func merged(
    entry: MCPServerEntry,
    named serverName: String = MCPClientCatalog.serverName,
    into existingContents: String?,
    serversKey: String,
    clientName: String,
    configPath: String
  ) throws -> (contents: String, outcome: MCPConfigWriteOutcome) {
    do {
      let write = try mcpConfigMerged(
        entry: entry.core, serverName: serverName, existing: existingContents,
        serversKey: serversKey, configPath: configPath)
      return (write.contents, MCPConfigWriteOutcome(core: write.outcome))
    } catch {
      switch error.clientConfigFailure {
      case .unreadableConfig(let path):
        throw MCPConfigError.unreadableConfig(client: clientName, path: path)
      case .serversKeyNotAnObject(let key):
        throw MCPConfigError.serversKeyNotAnObject(client: clientName, key: key)
      default:
        throw MCPConfigError.encodingFailed
      }
    }
  }

  /// The whole config — `{ serversKey: { serverName: entry } }` — for a user
  /// to paste into a file of their own.
  public static func document(
    entry: MCPServerEntry,
    serversKey: String = "mcpServers",
    named serverName: String = MCPClientCatalog.serverName
  ) -> String {
    mcpConfigDocument(entry: entry.core, serversKey: serversKey, serverName: serverName)
  }

  /// The `claude mcp add-json` invocation for clients that own their config file
  /// and would race a direct write, led by a quiet `claude mcp remove` of each
  /// earlier name.
  public static func terminalCommand(
    entry: MCPServerEntry,
    named serverName: String = MCPClientCatalog.serverName
  ) -> String {
    mcpTerminalCommand(entry: entry.core, serverName: serverName)
  }

  /// A fragment to paste inside an existing top-level object, for configs that
  /// carry comments we must not destroy.
  public static func pasteSnippet(
    entry: MCPServerEntry,
    serversKey: String,
    named serverName: String = MCPClientCatalog.serverName
  ) -> String {
    mcpPasteSnippet(entry: entry.core, serversKey: serversKey, serverName: serverName)
  }
}
