import Foundation

/// One stdio MCP server, in the shape every supported client expects.
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

  public var jsonObject: [String: Any] {
    var object: [String: Any] = ["command": command, "args": args]
    if !env.isEmpty { object["env"] = env }
    if let transportType { object["type"] = transportType }
    return object
  }
}

public enum MCPConfigWriteOutcome: Equatable {
  case added
  case updated
  case unchanged
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

public enum MCPClientConfigWriter {
  /// Merges `entry` into an existing config, preserving every other key and
  /// every other server — except an entry this app wrote under one of its
  /// earlier names (`MCPClientCatalog.legacyServerNames`), which the new entry
  /// replaces.
  ///
  /// Returns `.unchanged` when the entry is already byte-identical, so a repeat
  /// install doesn't rewrite the file (and doesn't claim it did something).
  ///
  /// Keys come back sorted: `JSONSerialization` has no ordering guarantee, and a
  /// stable order beats reshuffling the user's file differently on every write.
  public static func merged(
    entry: MCPServerEntry,
    named serverName: String = MCPClientCatalog.serverName,
    into existingContents: String?,
    serversKey: String,
    clientName: String,
    configPath: String
  ) throws -> (contents: String, outcome: MCPConfigWriteOutcome) {
    var root: [String: Any] = [:]

    let trimmed = existingContents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty {
      guard let data = trimmed.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data),
        let object = parsed as? [String: Any]
      else {
        throw MCPConfigError.unreadableConfig(client: clientName, path: configPath)
      }
      root = object
    }

    var servers: [String: Any] = [:]
    if let existing = root[serversKey] {
      guard let typed = existing as? [String: Any] else {
        throw MCPConfigError.serversKeyNotAnObject(client: clientName, key: serversKey)
      }
      servers = typed
    }

    let newEntry = entry.jsonObject
    var outcome: MCPConfigWriteOutcome
    if let previous = servers[serverName] as? [String: Any] {
      outcome = NSDictionary(dictionary: previous).isEqual(to: newEntry) ? .unchanged : .updated
    } else {
      outcome = .added
    }

    for legacyName in MCPClientCatalog.legacyServerNames where legacyName != serverName {
      guard let legacy = servers[legacyName] as? [String: Any],
        MCPClientCatalog.isLegacyEntryWrittenByThisApp(legacy)
      else { continue }
      servers.removeValue(forKey: legacyName)
      outcome = .updated
    }

    servers[serverName] = newEntry
    root[serversKey] = servers

    return (try prettyPrinted(root) + "\n", outcome)
  }

  /// The `claude mcp add-json` invocation for clients that own their config file
  /// and would race a direct write.
  ///
  /// Led by a quiet `claude mcp remove` of each earlier name, so an entry the
  /// app added when it was called Priority is replaced rather than left to
  /// point at an app that is gone. `;` rather than `&&`, because on a machine
  /// that never had one the remove fails, and the add must run regardless.
  public static func terminalCommand(
    entry: MCPServerEntry,
    named serverName: String = MCPClientCatalog.serverName
  ) -> String {
    let json = (try? compactPrinted(entry.jsonObject)) ?? "{}"
    let removals = MCPClientCatalog.legacyServerNames
      .filter { $0 != serverName }
      .map { "claude mcp remove \($0) --scope user >/dev/null 2>&1; " }
      .joined()
    return "\(removals)claude mcp add-json \(serverName) --scope user \(singleQuoted(json))"
  }

  /// A fragment to paste inside an existing top-level object, for configs that
  /// carry comments we must not destroy.
  public static func pasteSnippet(
    entry: MCPServerEntry,
    serversKey: String,
    named serverName: String = MCPClientCatalog.serverName
  ) -> String {
    let wrapped: [String: Any] = [serversKey: [serverName: entry.jsonObject]]
    guard let full = try? prettyPrinted(wrapped) else { return "" }

    // Strip the outer braces so the result drops straight into the user's
    // existing object. `prettyPrinted` indents with two spaces, so the body is
    // every line between the first and last, dedented once.
    let lines = full.components(separatedBy: "\n")
    guard lines.count > 2, lines.first == "{", lines.last == "}" else { return full }
    return lines.dropFirst().dropLast()
      .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
      .joined(separator: "\n")
  }

  private static func prettyPrinted(_ object: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ),
      let text = String(data: data, encoding: .utf8)
    else {
      throw MCPConfigError.encodingFailed
    }
    return text
  }

  private static func compactPrinted(_ object: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ),
      let text = String(data: data, encoding: .utf8)
    else {
      throw MCPConfigError.encodingFailed
    }
    return text
  }

  /// Wraps `value` for a POSIX shell. A remote key or list id has no business
  /// containing a quote, but the config also carries an email address, and a
  /// broken paste is a worse failure than an ugly one.
  private static func singleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
