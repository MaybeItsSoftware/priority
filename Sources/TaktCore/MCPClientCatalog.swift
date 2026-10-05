import Foundation

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

  /// The config is JSON-with-comments. Round-tripping it through
  /// `JSONSerialization` would silently drop every comment the user wrote, so
  /// hand over a snippet to paste instead of editing the file.
  case pasteSnippet
}

/// A known MCP client and everything needed to add Takt to it.
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

  public var configPath: String { configPathComponents.joined(separator: "/") }

  public func configPath(inHomeDirectory home: String) -> String {
    ([home] + configPathComponents).joined(separator: "/")
  }

  /// The directory the config file lives in. Sandboxed builds ask for access to
  /// this rather than the file, so the config can be created when absent.
  public func configDirectoryPath(inHomeDirectory home: String) -> String {
    ([home] + configPathComponents.dropLast()).joined(separator: "/")
  }

  public var configFileName: String { configPathComponents.last ?? "" }
}

public enum MCPClientCatalog {
  /// The server name Takt registers itself under in every client.
  public static let serverName = "takt"

  /// Names earlier versions registered under, when the app was Priority. An
  /// entry under one of these that this app wrote is replaced, not left
  /// beside the new one, so a client doesn't end up with two copies of the
  /// same server — one of them pointing at an app that is no longer there.
  public static let legacyServerNames = ["priority"]

  /// Whether a server entry is one this app wrote under an earlier name, as
  /// opposed to something the user happens to have called `priority`.
  ///
  /// Recognised by its command: the bundled helper, the app's own
  /// `--mcp-server` executable, or an installed `priority` CLI.
  public static func isLegacyEntryWrittenByThisApp(_ entry: [String: Any]) -> Bool {
    guard let command = entry["command"] as? String else { return false }
    return command.hasSuffix("/Contents/Helpers/priority")
      || command.hasSuffix("/Contents/MacOS/Priority")
      || command.hasSuffix("/bin/priority")
  }

  public static let claudeCode = MCPClientDescriptor(
    id: "claude-code",
    displayName: "Claude Code",
    configPathComponents: [".claude.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .terminalCommand,
    homeRelativeMarkers: [".claude.json", ".claude"],
    applicationBundleNames: [],
    postInstallNote: "Run the command, then use /mcp in Claude Code to check the connection."
  )

  public static let claudeDesktop = MCPClientDescriptor(
    id: "claude-desktop",
    displayName: "Claude Desktop",
    configPathComponents: ["Library", "Application Support", "Claude", "claude_desktop_config.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: ["Library/Application Support/Claude"],
    applicationBundleNames: ["Claude.app"],
    postInstallNote: "Quit and reopen Claude Desktop to pick up the new server."
  )

  public static let cursor = MCPClientDescriptor(
    id: "cursor",
    displayName: "Cursor",
    configPathComponents: [".cursor", "mcp.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: [".cursor"],
    applicationBundleNames: ["Cursor.app"],
    postInstallNote: "Reload Cursor, then check Settings › MCP."
  )

  public static let windsurf = MCPClientDescriptor(
    id: "windsurf",
    displayName: "Windsurf",
    configPathComponents: [".codeium", "windsurf", "mcp_config.json"],
    serversKey: "mcpServers",
    requiresTransportType: false,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: [".codeium/windsurf"],
    applicationBundleNames: ["Windsurf.app"],
    postInstallNote: "Reload Windsurf to pick up the new server."
  )

  public static let visualStudioCode = MCPClientDescriptor(
    id: "vscode",
    displayName: "VS Code",
    configPathComponents: ["Library", "Application Support", "Code", "User", "mcp.json"],
    serversKey: "servers",
    requiresTransportType: true,
    installStyle: .mergeConfigFile,
    homeRelativeMarkers: ["Library/Application Support/Code/User"],
    applicationBundleNames: ["Visual Studio Code.app"],
    postInstallNote: "Reload the VS Code window to pick up the new server."
  )

  public static let zed = MCPClientDescriptor(
    id: "zed",
    displayName: "Zed",
    configPathComponents: [".config", "zed", "settings.json"],
    serversKey: "context_servers",
    requiresTransportType: false,
    // Zed's settings.json ships with explanatory comments and most users add
    // their own. Rewriting it as plain JSON would delete all of them.
    installStyle: .pasteSnippet,
    homeRelativeMarkers: [".config/zed"],
    applicationBundleNames: ["Zed.app"],
    postInstallNote: "Paste into settings.json — Zed picks the server up on save."
  )

  public static let all: [MCPClientDescriptor] = [
    claudeCode, claudeDesktop, cursor, windsurf, visualStudioCode, zed,
  ]

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
      let homeHit = client.homeRelativeMarkers.contains { marker in
        fileExists(([homeDirectory] + marker.split(separator: "/").map(String.init))
          .joined(separator: "/"))
      }
      if homeHit { return true }
      return client.applicationBundleNames.contains { bundleName in
        fileExists("\(applicationsDirectory)/\(bundleName)")
      }
    }
  }
}
