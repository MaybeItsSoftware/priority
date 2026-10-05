import Foundation
import XCTest

@testable import TaktPlugins

@MainActor
final class UserPluginManagerLoadingTests: XCTestCase {
  func testReloadSkipsFoldersWithoutManifest() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    // Create a folder without plugin.json — should be silently skipped.
    let orphanFolder = pluginsRoot.appendingPathComponent("orphan-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)

    // Create a valid plugin folder alongside it.
    try makePluginFolder(
      in: pluginsRoot,
      folderName: "valid-plugin",
      manifestJSON: """
        {
          "id": "loading.test.valid",
          "name": "Valid Plugin",
          "pluginApiVersion": 1
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.2.0",
      pluginsDirectoryURL: pluginsRoot,
      defaults: makeIsolatedDefaults()
    )
    manager.reloadInstalledPlugins()

    // Only the valid plugin should be loaded; no validation issue for the orphan.
    XCTAssertEqual(manager.installedPlugins.count, 1)
    XCTAssertEqual(manager.installedPlugins.first?.manifest.id, "loading.test.valid")
    XCTAssertTrue(manager.validationIssues.isEmpty)
  }

  func testReloadLoadsMultipleValidPlugins() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    try makePluginFolder(
      in: pluginsRoot,
      folderName: "plugin-a",
      manifestJSON: """
        {
          "id": "loading.test.a",
          "name": "Plugin A",
          "pluginApiVersion": 1
        }
        """
    )
    try makePluginFolder(
      in: pluginsRoot,
      folderName: "plugin-b",
      manifestJSON: """
        {
          "id": "loading.test.b",
          "name": "Plugin B",
          "pluginApiVersion": 1
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.2.0",
      pluginsDirectoryURL: pluginsRoot,
      defaults: makeIsolatedDefaults()
    )
    manager.reloadInstalledPlugins()

    XCTAssertEqual(manager.installedPlugins.count, 2)
    let ids = Set(manager.installedPlugins.map(\.manifest.id))
    XCTAssertEqual(ids, ["loading.test.a", "loading.test.b"])
    XCTAssertTrue(manager.validationIssues.isEmpty)
  }

  func testReloadRejectsDuplicatePluginIDs() throws {
    let pluginsRoot = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: pluginsRoot) }

    try makePluginFolder(
      in: pluginsRoot,
      folderName: "plugin-first",
      manifestJSON: """
        {
          "id": "loading.test.dup",
          "name": "First Plugin",
          "pluginApiVersion": 1
        }
        """
    )
    try makePluginFolder(
      in: pluginsRoot,
      folderName: "plugin-second",
      manifestJSON: """
        {
          "id": "loading.test.dup",
          "name": "Duplicate Plugin",
          "pluginApiVersion": 1
        }
        """
    )

    let manager = UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.2.0",
      pluginsDirectoryURL: pluginsRoot,
      defaults: makeIsolatedDefaults()
    )
    manager.reloadInstalledPlugins()

    XCTAssertEqual(manager.installedPlugins.count, 1)
    XCTAssertEqual(manager.validationIssues.count, 1)
    XCTAssertTrue(
      manager.validationIssues.first?.message.localizedCaseInsensitiveContains("duplicate") ?? false
    )
  }

  /// A throwaway suite per test. Without this the manager reads and writes the
  /// developer's real preferences (it persists plugin enablement state), so runs
  /// leak into each other and into the local app install.
  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "priority-plugin-tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Could not create an isolated UserDefaults suite.")
      return .standard
    }
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    return defaults
  }

  private func makeTemporaryPluginsRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "priority-plugin-loading-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  private func makePluginFolder(in root: URL, folderName: String, manifestJSON: String) throws
    -> URL
  {
    let pluginFolder = root.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
    let manifestURL = pluginFolder.appendingPathComponent("plugin.json")
    guard let manifestData = manifestJSON.data(using: .utf8) else {
      throw NSError(domain: "UserPluginManagerLoadingTests", code: 1)
    }
    try manifestData.write(to: manifestURL)
    return pluginFolder
  }
}
