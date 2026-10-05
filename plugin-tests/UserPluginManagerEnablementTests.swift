import Foundation
import XCTest

@testable import TaktPlugins

/// Covers which plugins end up enabled after a reload. The rule is:
/// auto-enable on first discovery, then never touch the user's choice again.
@MainActor
final class UserPluginManagerEnablementTests: XCTestCase {
  func testNewlyDiscoveredPluginIsAutoEnabled() throws {
    let root = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try makePluginFolder(in: root, folderName: "alpha", id: "enablement.alpha")

    let manager = makeManager(pluginsDirectoryURL: root, defaults: makeIsolatedDefaults())

    XCTAssertTrue(manager.isPluginEnabled("enablement.alpha"))
  }

  /// Regression: `reloadInstalledPlugins` used to auto-enable every plugin that
  /// wasn't in the enabled set — which is exactly the set the user had just
  /// disabled — so switching a plugin off silently reverted.
  func testDisabledPluginStaysDisabledAcrossReload() throws {
    let root = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try makePluginFolder(in: root, folderName: "alpha", id: "enablement.alpha")

    let manager = makeManager(pluginsDirectoryURL: root, defaults: makeIsolatedDefaults())
    manager.setPluginEnabled(false, pluginIdentifier: "enablement.alpha")

    manager.reloadInstalledPlugins()

    XCTAssertFalse(manager.isPluginEnabled("enablement.alpha"))
  }

  /// The choice is persisted, so it must also survive a relaunch — `init` runs
  /// `reloadInstalledPlugins`, which was the path that reverted it in practice.
  func testDisabledPluginStaysDisabledAcrossRelaunch() throws {
    let root = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try makePluginFolder(in: root, folderName: "alpha", id: "enablement.alpha")

    let defaults = makeIsolatedDefaults()
    let firstLaunch = makeManager(pluginsDirectoryURL: root, defaults: defaults)
    firstLaunch.setPluginEnabled(false, pluginIdentifier: "enablement.alpha")

    let secondLaunch = makeManager(pluginsDirectoryURL: root, defaults: defaults)

    XCTAssertFalse(secondLaunch.isPluginEnabled("enablement.alpha"))
  }

  /// Auto-enable must still fire for genuinely new plugins alongside a
  /// deliberately disabled one.
  func testDisablingOnePluginDoesNotSuppressAutoEnableOfAnother() throws {
    let root = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try makePluginFolder(in: root, folderName: "alpha", id: "enablement.alpha")

    let defaults = makeIsolatedDefaults()
    let manager = makeManager(pluginsDirectoryURL: root, defaults: defaults)
    manager.setPluginEnabled(false, pluginIdentifier: "enablement.alpha")

    try makePluginFolder(in: root, folderName: "beta", id: "enablement.beta")
    manager.reloadInstalledPlugins()

    XCTAssertFalse(manager.isPluginEnabled("enablement.alpha"))
    XCTAssertTrue(manager.isPluginEnabled("enablement.beta"))
  }

  /// Uninstalling forgets the plugin, so re-installing counts as new again.
  func testReinstallingAPreviouslyDisabledPluginAutoEnablesIt() throws {
    let root = try makeTemporaryPluginsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try makePluginFolder(in: root, folderName: "alpha", id: "enablement.alpha")

    let defaults = makeIsolatedDefaults()
    let manager = makeManager(pluginsDirectoryURL: root, defaults: defaults)
    manager.setPluginEnabled(false, pluginIdentifier: "enablement.alpha")

    try FileManager.default.removeItem(at: folder)
    manager.reloadInstalledPlugins()
    XCTAssertTrue(manager.installedPlugins.isEmpty)

    try makePluginFolder(in: root, folderName: "alpha", id: "enablement.alpha")
    manager.reloadInstalledPlugins()

    XCTAssertTrue(manager.isPluginEnabled("enablement.alpha"))
  }

  // MARK: - Helpers

  private func makeManager(pluginsDirectoryURL: URL, defaults: UserDefaults) -> UserPluginManager {
    UserPluginManager(
      builtInPluginIdentifiers: [],
      currentAppVersion: "1.2.0",
      pluginsDirectoryURL: pluginsDirectoryURL,
      defaults: defaults
    )
  }

  /// A throwaway suite per test — the manager persists enablement state, and
  /// falling back to `.standard` would read and write the developer's real
  /// preferences and leak state between runs.
  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "priority-enablement-tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Could not create an isolated UserDefaults suite.")
      return .standard
    }
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    return defaults
  }

  private func makeTemporaryPluginsRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "priority-enablement-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  private func makePluginFolder(in root: URL, folderName: String, id: String) throws -> URL {
    let pluginFolder = root.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
    let manifest = """
      {
        "id": "\(id)",
        "name": "\(folderName)",
        "pluginApiVersion": 1
      }
      """
    try Data(manifest.utf8).write(to: pluginFolder.appendingPathComponent("plugin.json"))
    return pluginFolder
  }
}
