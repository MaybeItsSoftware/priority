import AppKit
import Foundation
import OSLog
import TaktCore

/// Writes Priority's MCP entry into the config files of clients that keep one.
///
/// The app currently ships unsandboxed — `Priority.release.entitlements` sets
/// `com.apple.security.app-sandbox` to false and explains why — so a client's
/// config file under the real home directory is simply readable and writable,
/// and installing is a plain merge-and-write.
///
/// Everything below the "Sandbox access" mark is therefore dormant: the open
/// panel, the security-scoped bookmark and `withSecurityScope` never run in a
/// shipping build. It is kept because turning the sandbox back on is a live
/// possibility (it only wants a provisioning profile and a keychain access
/// group), and under the sandbox nothing outside the container is reachable
/// until the user hands a directory over through an open panel. Bookmarking
/// the granted directory makes that once per client rather than once per
/// install. Rewriting it later would cost more than keeping it.
@MainActor
final class MCPClientInstaller {
  enum InstallResult: Equatable {
    case wrote(MCPConfigWriteOutcome)
    case cancelled
  }

  enum InstallError: LocalizedError {
    /// The client's config folder isn't there.
    ///
    /// A client is detected from an installed bundle or a home-relative
    /// marker, never from its config file, so a client that has been installed
    /// but never opened is detected with no folder to write into. Launching it
    /// once is what creates the folder; we won't create it ourselves, because
    /// a config sitting somewhere the client has never looked is worse than a
    /// message saying what to do.
    case configDirectoryMissing(client: String, directory: String)

    var errorDescription: String? {
      switch self {
      case .configDirectoryMissing(let client, let directory):
        return "\(client)'s config folder isn't there (\(directory)). Open \(client) once, then retry."
      }
    }
  }

  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "MCPClientInstaller")
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Environment

  /// The user's actual home directory.
  ///
  /// `FileManager.homeDirectoryForCurrentUser` returns the *container* under the
  /// sandbox, which is never where an MCP client keeps its config.
  static var realHomeDirectory: URL {
    if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: directory))
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  /// False in every shipping build today; see the note on the type.
  private static var isSandboxed: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }

  func detectedClients() -> [MCPClientDescriptor] {
    MCPClientCatalog.detectedClients(
      homeDirectory: Self.realHomeDirectory.path,
      fileExists: { FileManager.default.fileExists(atPath: $0) }
    )
  }

  func configURL(for client: MCPClientDescriptor) -> URL {
    URL(fileURLWithPath: client.configPath(inHomeDirectory: Self.realHomeDirectory.path))
  }

  // MARK: - Install

  func install(entry: MCPServerEntry, into client: MCPClientDescriptor) throws -> InstallResult {
    let configURL = configURL(for: client)
    let directoryURL = configURL.deletingLastPathComponent()

    // Every path checks the folder first, including the bookmarked one: a
    // bookmark outlives what it points at, so a client the user has since
    // removed resolves to a directory that is no longer there. Without this
    // the write fails somewhere in Foundation and the user gets a file-system
    // error instead of the one sentence that tells them what to do.
    if let bookmarked = resolvedBookmarkURL(for: client) {
      return .wrote(
        try withSecurityScope(bookmarked) {
          try requireConfigDirectory(directoryURL, client: client)
          return try mergeAndWrite(entry: entry, client: client, configURL: configURL)
        })
    }

    try requireConfigDirectory(directoryURL, client: client)

    guard Self.isSandboxed else {
      return .wrote(try mergeAndWrite(entry: entry, client: client, configURL: configURL))
    }

    guard let granted = try requestAccess(to: directoryURL, client: client) else {
      return .cancelled
    }
    return .wrote(
      try withSecurityScope(granted) {
        try mergeAndWrite(entry: entry, client: client, configURL: configURL)
      })
  }

  /// Throws unless the client's config folder already exists. Never creates it
  /// — see `InstallError.configDirectoryMissing`.
  private func requireConfigDirectory(_ directoryURL: URL, client: MCPClientDescriptor) throws {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      throw InstallError.configDirectoryMissing(
        client: client.displayName, directory: directoryURL.path)
    }
  }

  private func mergeAndWrite(
    entry: MCPServerEntry,
    client: MCPClientDescriptor,
    configURL: URL
  ) throws -> MCPConfigWriteOutcome {
    let existing = try existingContents(at: configURL)
    let merged = try MCPClientConfigWriter.merged(
      entry: entry,
      into: existing,
      serversKey: client.serversKey,
      clientName: client.displayName,
      configPath: configURL.path
    )

    // Don't touch the file when nothing would change — a no-op write still
    // bumps the modification date and can nudge clients into a reload.
    guard merged.outcome != .unchanged else { return .unchanged }

    try merged.contents.write(to: configURL, atomically: true, encoding: .utf8)

    // A config we created ourselves lands at whatever the umask allows —
    // usually 0644 — and these files can hold credentials, so tighten it to
    // 0600 the way the CLI does with its own config. Only when we created it:
    // a file that was already there has a mode its owner chose, and quietly
    // clamping another app's config is not this code's business.
    if existing == nil {
      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: configURL.path)
      } catch {
        // The entry is written and usable; a wider mode than we'd like is not
        // worth failing the install over, so say so and carry on.
        logger.warning(
          "Could not restrict permissions on \(configURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    logger.info(
      "Wrote MCP entry for \(client.id, privacy: .public): \(String(describing: merged.outcome), privacy: .public)"
    )
    return merged.outcome
  }

  private func existingContents(at url: URL) throws -> String? {
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
  }

  // MARK: - Sandbox access

  private func requestAccess(to directoryURL: URL, client: MCPClientDescriptor) throws -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    // Several clients hide their config under a dotted folder.
    panel.showsHiddenFiles = true
    panel.directoryURL = directoryURL
    panel.prompt = "Grant Access"
    panel.message =
      "Takt needs permission to edit \(client.displayName)'s MCP configuration. "
      + "The folder is already selected — click Grant Access."

    guard panel.runModal() == .OK, let selected = panel.url else { return nil }

    let bookmark = try selected.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    defaults.set(bookmark, forKey: bookmarkKey(for: client))
    return selected
  }

  private func bookmarkKey(for client: MCPClientDescriptor) -> String {
    "mcpClientConfigDirectoryBookmark.\(client.id)"
  }

  private func resolvedBookmarkURL(for client: MCPClientDescriptor) -> URL? {
    guard let data = defaults.data(forKey: bookmarkKey(for: client)) else { return nil }
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else {
      defaults.removeObject(forKey: bookmarkKey(for: client))
      return nil
    }
    if isStale,
      let refreshed = try? url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    {
      defaults.set(refreshed, forKey: bookmarkKey(for: client))
    }
    return url
  }

  /// Every read and write under a bookmark-resolved directory has to happen
  /// inside one of these. Mirrors `ObsidianSyncService.withSecurityScope`.
  private func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    return try body()
  }
}
