import Foundation
import TaktRustCore

/// How Takt can add itself to a given MCP client.
///
/// Not every client can be configured the same way, and picking the wrong route
/// is worse than doing nothing — it either races the client's own writes or
/// destroys parts of a file the user hand-wrote.
public enum MCPClientInstallStyle: Equatable, Sendable {
  /// A plain JSON file that only ever holds MCP configuration. Takt can
  /// read it, merge one server entry in, and write it back.
  case mergeConfigFile

  /// The client rewrites its own config continuously — Claude Code touches
  /// `~/.claude.json` on nearly every run — so editing it underneath would race
  /// and lose one side of the write. Its CLI is the supported route.
  case terminalCommand

  /// The config is JSON-with-comments. Round-tripping it would silently drop
  /// every comment the user wrote, so hand over a snippet to paste instead of
  /// editing the file.
  case pasteSnippet

  init(core style: McpClientInstallStyle) {
    switch style {
    case .mergeConfigFile: self = .mergeConfigFile
    case .terminalCommand: self = .terminalCommand
    case .pasteSnippet: self = .pasteSnippet
    }
  }
}

/// A known MCP client and everything needed to add Takt to it. The catalogue
/// and where each client's file lives are the Rust core's
/// (`client_config::mcp_client_catalog`).
public struct MCPClientDescriptor: Identifiable, Equatable, Sendable {
  public let id: String
  public let displayName: String

  /// Config file path relative to the user's real home directory.
  public let configPathComponents: [String]

  /// Top-level key holding the server map. Most clients use `mcpServers`;
  /// VS Code uses `servers` and Zed uses `context_servers`.
  public let serversKey: String

  /// VS Code requires an explicit `"type": "stdio"` on each entry; the others
  /// infer stdio from the presence of `command`.
  public let requiresTransportType: Bool

  public let installStyle: MCPClientInstallStyle

  /// Home-relative paths whose existence means this client is worth offering.
  public let homeRelativeMarkers: [String]

  /// App bundle names checked under `/Applications`.
  public let applicationBundleNames: [String]

  /// What the user has to do after the config lands, shown once setup succeeds.
  public let postInstallNote: String

  private let core: McpClientDescriptor

  init(core: McpClientDescriptor) {
    self.core = core
    id = core.id
    displayName = core.displayName
    configPathComponents = core.configPathComponents
    serversKey = core.serversKey
    requiresTransportType = core.requiresTransportType
    installStyle = MCPClientInstallStyle(core: core.installStyle)
    homeRelativeMarkers = core.homeRelativeMarkers
    applicationBundleNames = core.applicationBundleNames
    postInstallNote = core.postInstallNote
  }

  public static func == (lhs: MCPClientDescriptor, rhs: MCPClientDescriptor) -> Bool {
    lhs.core == rhs.core
  }

  public var configPath: String { configPathComponents.joined(separator: "/") }

  public func configPath(inHomeDirectory home: String) -> String {
    mcpClientConfigPath(client: core, home: home)
  }

  /// The directory the config file lives in. Sandboxed builds ask for access to
  /// this rather than the file, so the config can be created when absent.
  public func configDirectoryPath(inHomeDirectory home: String) -> String {
    mcpClientConfigDirectoryPath(client: core, home: home)
  }

  public var configFileName: String { configPathComponents.last ?? "" }

  /// The paths whose existence means this client is on the machine.
  func detectionPaths(homeDirectory: String, applicationsDirectory: String) -> [String] {
    mcpClientDetectionPaths(
      client: core, home: homeDirectory, applicationsDirectory: applicationsDirectory)
  }
}

public enum MCPClientCatalog {
  /// The server name Takt registers itself under in every client.
  public static let serverName = mcpServerName()

  /// Names earlier versions registered under, when the app was Priority. An
  /// entry under one of these that this app wrote is replaced, not left
  /// beside the new one.
  public static let legacyServerNames = mcpLegacyServerNames()

  /// Whether a server entry is one this app wrote under an earlier name, as
  /// opposed to something the user happens to have called `priority`.
  /// Recognised by its command.
  public static func isLegacyEntryWrittenByThisApp(_ entry: [String: Any]) -> Bool {
    guard let command = entry["command"] as? String else { return false }
    return mcpIsLegacyCommand(command: command)
  }

  /// Every client, in the order they are offered.
  public static let all: [MCPClientDescriptor] = mcpClientCatalog().map(
    MCPClientDescriptor.init(core:))

  private static func client(_ id: String) -> MCPClientDescriptor {
    guard let client = all.first(where: { $0.id == id }) else {
      preconditionFailure("The core's MCP client catalogue has no \(id)")
    }
    return client
  }

  public static let claudeCode = client("claude-code")
  public static let claudeDesktop = client("claude-desktop")
  public static let cursor = client("cursor")
  public static let windsurf = client("windsurf")
  public static let visualStudioCode = client("vscode")
  public static let zed = client("zed")

  /// Clients with a trace on this machine, in catalog order.
  ///
  /// Detection is deliberately loose — a marker directory is enough. Offering a
  /// client the user doesn't have costs them one ignored row; hiding one they do
  /// have sends them back to hand-editing JSON.
  public static func detectedClients(
    homeDirectory: String,
    applicationsDirectory: String = "/Applications",
    fileExists: (String) -> Bool
  ) -> [MCPClientDescriptor] {
    all.filter { client in
      client.detectionPaths(
        homeDirectory: homeDirectory, applicationsDirectory: applicationsDirectory
      ).contains(where: fileExists)
    }
  }
}
