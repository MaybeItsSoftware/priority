import Foundation
import TaktCore

@MainActor
final class NativeMCPIntegrationPlugin: MCPIntegrationPlugin {
  private struct ResolvedMCPCommand {
    let command: String
    let args: [String]
    let displayURL: URL?
  }

  let pluginIdentifier = "native.mcp.integration"
  let displayName = "Native MCP Integration"
  let pluginDescription = "Expose Takt as a local MCP server for AI assistants and tools."

  private let guideRelativePath = "docs/mcp-server.md"
  /// The MCP server is the `takt` CLI, shipped inside the bundle by
  /// `scripts/bundle_cli.sh`. Configurations point straight at it rather than
  /// at `Takt --mcp-server`, which now only exists to keep configurations
  /// written before that change working. See `MCPServerShim`.
  private let helperRelativePath = "Contents/Helpers/takt"
  private let defaultCommandPlaceholder =
    "/Applications/Takt.app/Contents/Helpers/takt"
  private let serverArguments = ["mcp"]

  func serverCommandURL() -> URL? {
    resolvedMCPCommand().displayURL
  }

  func guideURL() -> URL? {
    let fileManager = FileManager.default
    for candidate in guideCandidates() where fileManager.fileExists(atPath: candidate.path) {
      return candidate.standardizedFileURL
    }
    return nil
  }

  func serverInvocation() -> MCPServerInvocation {
    let resolved = resolvedMCPCommand()
    return MCPServerInvocation(command: resolved.command, args: resolved.args)
  }

  /// Deliberately credential-free.
  ///
  /// The CLI's precedence is environment-beats-file, and it does not read the
  /// file at all for a variable the environment already sets — so a
  /// `CHECKVIST_REMOTE_KEY` here would both pin the key at install time (a
  /// rotation then 401s every configured client, silently) and permanently
  /// shut out `~/.config/takt/config.json`, which is the store the app
  /// seeds. The list id is neither a secret nor a credential, and overriding it
  /// per client is the point of having it here.
  func serverEnvironment(listId: String) -> [String: String] {
    let trimmedListId = listId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedListId.isEmpty else { return [:] }
    return ["CHECKVIST_LIST_ID": trimmedListId]
  }

  /// The whole `mcpServers` config, in the entry shape the Rust core gives
  /// every client (`MCPClientConfigWriter.document`): no `env` when there is
  /// no list to override.
  func makeClientConfigurationJSON(listId: String) -> String {
    let command = resolvedMCPCommand()
    return MCPClientConfigWriter.document(
      entry: MCPServerEntry(
        command: command.command,
        args: command.args,
        env: serverEnvironment(listId: listId)
      )
    )
  }

  private func resolvedMCPCommand() -> ResolvedMCPCommand {
    let fileManager = FileManager.default
    let envOverride =
      ProcessInfo.processInfo.environment["PRIORITY_MCP_EXECUTABLE_PATH"]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !envOverride.isEmpty {
      let overrideURL = URL(fileURLWithPath: envOverride).standardizedFileURL
      if fileManager.fileExists(atPath: overrideURL.path) {
        return ResolvedMCPCommand(
          command: overrideURL.path,
          args: serverArguments,
          displayURL: overrideURL
        )
      }
    }

    for candidate in commandCandidates() where fileManager.fileExists(atPath: candidate.path) {
      return ResolvedMCPCommand(
        command: candidate.path,
        args: serverArguments,
        displayURL: candidate.standardizedFileURL
      )
    }

    return ResolvedMCPCommand(
      command: defaultCommandPlaceholder,
      args: serverArguments,
      displayURL: nil
    )
  }

  private func commandCandidates() -> [URL] {
    let fileManager = FileManager.default
    var candidates: [URL] = []

    // The installed app first, so a configuration written from a development
    // build still names the path the user will actually have.
    candidates.append(
      URL(fileURLWithPath: "/Applications/Takt.app").appendingPathComponent(
        helperRelativePath))

    let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
    candidates.append(
      bundleParent.appendingPathComponent("Takt.app").appendingPathComponent(
        helperRelativePath))
    candidates.append(Bundle.main.bundleURL.appendingPathComponent(helperRelativePath))

    // A separately installed CLI, for a bundle built with
    // TAKT_SKIP_CLI_BUNDLE=1.
    let home = NSHomeDirectory()
    candidates.append(contentsOf: [
      "\(home)/.local/bin/takt",
      "\(home)/bin/takt",
      "/usr/local/bin/takt",
      "/opt/homebrew/bin/takt",
    ].map(URL.init(fileURLWithPath:)))

    var deduplicated: [URL] = []
    var seenPaths = Set<String>()
    for candidate in candidates {
      let standardized = candidate.standardizedFileURL
      guard fileManager.fileExists(atPath: standardized.path) else { continue }
      if seenPaths.insert(standardized.path).inserted {
        deduplicated.append(standardized)
      }
    }
    return deduplicated
  }

  private func guideCandidates() -> [URL] {
    candidateURLs(forRelativePath: guideRelativePath, envOverrideKey: "PRIORITY_MCP_GUIDE_PATH")
  }

  private func candidateURLs(forRelativePath relativePath: String, envOverrideKey: String) -> [URL]
  {
    var candidates: [URL] = []

    let envOverride =
      ProcessInfo.processInfo.environment[envOverrideKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !envOverride.isEmpty {
      candidates.append(URL(fileURLWithPath: envOverride))
    }

    let sourceBasedRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    candidates.append(sourceBasedRoot.appendingPathComponent(relativePath))

    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    candidates.append(currentDirectory.appendingPathComponent(relativePath))

    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(
        resourceURL.appendingPathComponent((relativePath as NSString).lastPathComponent))
    }

    let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
    candidates.append(bundleParent.appendingPathComponent(relativePath))
    candidates.append(bundleParent.deletingLastPathComponent().appendingPathComponent(relativePath))

    var deduplicated: [URL] = []
    var seenPaths = Set<String>()
    for candidate in candidates {
      let standardized = candidate.standardizedFileURL
      if seenPaths.insert(standardized.path).inserted {
        deduplicated.append(standardized)
      }
    }
    return deduplicated
  }
}
