import Foundation
import TaktRustCore

/// The credentials the `takt` CLI keeps in its own store.
///
/// The CLI is a peer of the app rather than a front end for it, and it cannot
/// read the app's keychain item — that would depend on the app's code
/// signature. So the app hands its login down instead: it writes into
/// `~/.config/takt/config.json`, which is the only credential source the
/// MCP server has once the generated client entry stops carrying secrets in
/// `env`. See the header of `cli/src/config.rs`.
public struct TaktCLICredentials: Equatable {
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

public enum TaktCLIConfigError: LocalizedError, Equatable {
  case missingCredentials
  case unreadableConfig(path: String)
  case encodingFailed
  case readFailed(path: String)
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
    case .readFailed(let path):
      return "Could not read \(path)."
    case .writeFailed(let path):
      return "Could not write \(path)."
    }
  }

  /// The core's refusal, in this type's terms.
  init(core error: Error) {
    switch error.clientConfigFailure {
    case .missingCredentials: self = .missingCredentials
    case .unreadableConfig(let path): self = .unreadableConfig(path: path)
    case .readFailed(let path, _): self = .readFailed(path: path)
    case .writeFailed(let path, _): self = .writeFailed(path: path)
    case .serversKeyNotAnObject, nil: self = .encodingFailed
    }
  }
}

/// Seeds the `takt` CLI's credential file from the app's own login.
///
/// The format, the merge and the private write are the Rust core's
/// (`core/src/client_config.rs`), which `cli/src/config.rs` reads and saves
/// the same file through; this keeps the Swift face.
public enum TaktCLIConfigWriter {
  public static let usernameKey = "username"
  public static let remoteKeyKey = "remote_key"
  public static let listIdKey = "list_id"

  /// Where the CLI looks by default.
  ///
  /// The CLI also honours `$PRIORITY_CONFIG_PATH` and `$XDG_CONFIG_HOME`, but
  /// those live in the *client's* environment when it launches the server, not
  /// in the app's, so guessing from here would be worse than using the default.
  public static func defaultConfigPath(inHomeDirectory home: String) -> String {
    cliConfigDefaultPath(home: home)
  }

  /// Where the CLI kept its config when it was called `priority`. The CLI
  /// still reads it while the new one is missing, so the first seeding starts
  /// from it — keeping a hand-set `base_url` — rather than from nothing.
  public static func legacyConfigPaths(inHomeDirectory home: String) -> [String] {
    cliConfigLegacyPaths(home: home)
  }

  /// Merges `credentials` into the CLI's existing config.
  ///
  /// Every other key survives — `base_url` in particular. The app is
  /// authoritative for the username and remote key; `list_id` is only filled
  /// when absent. Returns `.unchanged` when the file already says this.
  public static func seeded(
    credentials: TaktCLICredentials,
    into existingContents: String?,
    configPath: String
  ) throws -> (contents: String, outcome: MCPConfigWriteOutcome) {
    do {
      let write = try cliConfigSeeded(
        credentials: credentials.core, existing: existingContents, configPath: configPath)
      return (write.contents, MCPConfigWriteOutcome(core: write.outcome))
    } catch {
      throw TaktCLIConfigError(core: error)
    }
  }

  /// Seeds the file under `home` itself: reads the current config, or the
  /// legacy one (read, never written), and writes the current path through a
  /// 0600 temporary renamed into place, creating missing folders at 0700.
  /// Nothing is written when nothing would change.
  @discardableResult
  public static func seed(
    credentials: TaktCLICredentials,
    inHomeDirectory home: String
  ) throws -> MCPConfigWriteOutcome {
    do {
      return MCPConfigWriteOutcome(
        core: try seedCliConfig(home: home, credentials: credentials.core))
    } catch {
      throw TaktCLIConfigError(core: error)
    }
  }

  /// Blanks the seeded username and remote key in the current config under
  /// `home`, leaving every other key alone; the legacy file is never written.
  /// True when the file was rewritten.
  @discardableResult
  public static func clearSeededCredentials(inHomeDirectory home: String) throws -> Bool {
    do {
      return try clearCliConfigCredentials(home: home)
    } catch {
      throw TaktCLIConfigError(core: error)
    }
  }
}

extension TaktCLICredentials {
  var core: CliCredentials {
    CliCredentials(username: username, remoteKey: remoteKey, listId: listId)
  }
}
