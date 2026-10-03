import Foundation

/// The credentials the `takt` CLI keeps in its own store.
///
/// The CLI is a peer of the app rather than a front end for it, and it cannot
/// read the app's keychain item — that would depend on the app's code
/// signature. So the app hands its login down instead: it writes into
/// `~/.config/takt/config.json`, which is the only credential source the
/// MCP server has once the generated client entry stops carrying secrets in
/// `env`. See the header of `cli/src/config.rs`.
public struct PriorityCLICredentials: Equatable {
  public let username: String
  public let remoteKey: String
  /// Optional, and only ever used to fill a gap — see `seeded(...)`.
  public let listId: String

  public init(username: String, remoteKey: String, listId: String = "") {
    self.username = username
    self.remoteKey = remoteKey
    self.listId = listId
  }

  public var normalizedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedRemoteKey: String {
    remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedListId: String {
    listId.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum PriorityCLIConfigError: LocalizedError, Equatable {
  case missingCredentials
  case unreadableConfig(path: String)
  case encodingFailed
  case writeFailed(path: String)

  public var errorDescription: String? {
    switch self {
    case .missingCredentials:
      return
        "Connect Checkvist first — the MCP server signs in with your Checkvist credentials."
    case .unreadableConfig(let path):
      return
        "The takt CLI's config isn't valid JSON, so it wasn't touched. Fix or move \(path) and try again."
    case .encodingFailed:
      return "Could not encode the takt CLI's configuration."
    case .writeFailed(let path):
      return "Could not write \(path)."
    }
  }
}

/// Seeds the `takt` CLI's credential file from the app's own login.
///
/// Pure on purpose: the merge is the part worth testing, and the app layer owns
/// the filesystem (it is the only side that knows the real home directory and
/// can set the file mode).
public enum PriorityCLIConfigWriter {
  public static let usernameKey = "username"
  public static let remoteKeyKey = "remote_key"
  public static let listIdKey = "list_id"

  /// Where the CLI looks by default.
  ///
  /// The CLI also honours `$PRIORITY_CONFIG_PATH` and `$XDG_CONFIG_HOME`, but
  /// those live in the *client's* environment when it launches the server, not
  /// in the app's, so guessing from here would be worse than using the default.
  public static func defaultConfigPath(inHomeDirectory home: String) -> String {
    (home as NSString).appendingPathComponent(".config/takt/config.json")
  }

  /// Where the CLI kept its config when it was called `priority`. The CLI
  /// still reads it while the new one is missing, so the first seeding starts
  /// from it — keeping a hand-set `base_url` — rather than from nothing.
  public static func legacyConfigPaths(inHomeDirectory home: String) -> [String] {
    [(home as NSString).appendingPathComponent(".config/priority/config.json")]
  }

  /// Merges `credentials` into the CLI's existing config.
  ///
  /// Every other key survives — `base_url` in particular, which a user on a
  /// self-hosted Checkvist will have set by hand and which the app knows
  /// nothing about.
  ///
  /// The app is authoritative for the username and remote key: this only runs
  /// when the user explicitly sets up an MCP client, and a stale key here is
  /// the exact failure the change is meant to end (rotate in the app, every
  /// client follows). `list_id` is different — it is the CLI's *default* list
  /// for terminal use, and the generated MCP entry already overrides it per
  /// client, so it is only filled when absent rather than overwritten.
  ///
  /// Returns `.unchanged` when the file already says this, so a repeat setup
  /// doesn't rewrite it (and doesn't claim it did something).
  public static func seeded(
    credentials: PriorityCLICredentials,
    into existingContents: String?,
    configPath: String
  ) throws -> (contents: String, outcome: MCPConfigWriteOutcome) {
    let username = credentials.normalizedUsername
    let remoteKey = credentials.normalizedRemoteKey
    guard !username.isEmpty, !remoteKey.isEmpty else {
      throw PriorityCLIConfigError.missingCredentials
    }

    var values: [String: Any] = [:]
    let trimmed = existingContents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty {
      guard let data = trimmed.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data),
        let object = parsed as? [String: Any]
      else {
        throw PriorityCLIConfigError.unreadableConfig(path: configPath)
      }
      values = object
    }

    let hadCredentials =
      nonEmptyString(values[usernameKey]) != nil || nonEmptyString(values[remoteKeyKey]) != nil
    var changed = false

    if nonEmptyString(values[usernameKey]) != username {
      values[usernameKey] = username
      changed = true
    }
    if nonEmptyString(values[remoteKeyKey]) != remoteKey {
      values[remoteKeyKey] = remoteKey
      changed = true
    }

    let listId = credentials.normalizedListId
    if !listId.isEmpty, nonEmptyString(values[listIdKey]) == nil {
      values[listIdKey] = listId
      changed = true
    }

    let outcome: MCPConfigWriteOutcome
    if !changed {
      outcome = .unchanged
    } else if hadCredentials {
      outcome = .updated
    } else {
      outcome = .added
    }

    return (try prettyPrinted(values) + "\n", outcome)
  }

  /// Only a non-empty string counts as present: the CLI itself trims and
  /// discards blanks (`Config::string`), so `"username": " "` is the same as no
  /// username at all and should be replaced rather than left alone.
  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func prettyPrinted(_ object: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ),
      let text = String(data: data, encoding: .utf8)
    else {
      throw PriorityCLIConfigError.encodingFailed
    }
    return text
  }
}
