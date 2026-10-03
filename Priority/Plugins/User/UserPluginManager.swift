import AppKit
import Foundation
import PriorityCore
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor
// swiftlint:disable type_body_length
@Observable final class UserPluginManager {
  private struct ResolvedPluginPackage {
    let pluginRootURL: URL
    let temporaryURLs: [URL]
  }

  private struct PluginTemplateDefinition {
    let folderName: String
    let manifest: UserPluginManifest
    let entrypointFileName: String?
  }

  struct InstalledUserPlugin: Identifiable, Hashable {
    let manifest: UserPluginManifest
    let folderURL: URL

    var id: String { manifest.id }
  }

  struct PluginValidationIssue: Identifiable, Hashable {
    let pluginFolderName: String
    let message: String

    var id: String { "\(pluginFolderName):\(message)" }
  }

  enum PluginInstallError: LocalizedError {
    case unsupportedSource
    case pluginManifestNotFound
    case multiplePluginManifestsFound
    case pluginAlreadyInstalled(String)
    case pluginIdentifierConflictsWithBuiltIn(String)
    case invalidPluginID
    case invalidPluginName
    case invalidCapability(String)
    case invalidPluginAPIVersion
    case unsupportedPluginAPIVersion(Int)
    case invalidMinAppVersion(String)
    case appVersionUnavailable
    case appVersionTooOld(minimum: String, current: String)
    case invalidEntrypointPath(String)
    case missingEntrypoint(String)
    case archiveExtractionFailed

    var errorDescription: String? {
      switch self {
      case .unsupportedSource:
        return "Unsupported plugin package. Use a plugin folder, .zip, or .priority-plugin file."
      case .pluginManifestNotFound:
        return "No plugin.json found in plugin package."
      case .multiplePluginManifestsFound:
        return "Multiple candidate plugin folders found. Package should contain one plugin."
      case .pluginAlreadyInstalled(let identifier):
        return "Plugin \(identifier) is already installed."
      case .pluginIdentifierConflictsWithBuiltIn(let identifier):
        return "Plugin identifier \(identifier) conflicts with a built-in plugin."
      case .invalidPluginID:
        return "Plugin id is invalid. Allowed: letters, numbers, dot, dash, underscore."
      case .invalidPluginName:
        return "Plugin name is missing."
      case .invalidCapability(let capability):
        return "Plugin capability '\(capability)' is not recognized."
      case .invalidPluginAPIVersion:
        return "Plugin API version is invalid."
      case .unsupportedPluginAPIVersion(let pluginVersion):
        return
          "Plugin API version \(pluginVersion) is not supported. This app supports API version \(UserPluginManifest.defaultPluginAPIVersion)."
      case .invalidMinAppVersion(let version):
        return "Minimum app version '\(version)' is invalid."
      case .appVersionUnavailable:
        return "Current app version is unavailable, so plugin compatibility cannot be verified."
      case .appVersionTooOld(let minimum, let current):
        return "Plugin requires app version \(minimum) or newer. Current version is \(current)."
      case .invalidEntrypointPath(let path):
        return "Entrypoint path '\(path)' is invalid."
      case .missingEntrypoint(let path):
        return "Entrypoint '\(path)' does not exist in the plugin folder."
      case .archiveExtractionFailed:
        return "Failed to extract plugin archive."
      }
    }
  }

  private static let enabledPluginIdentifiersDefaultsKey = "userPluginEnabledIdentifiers"
  /// Every plugin id we have already surfaced to the user. Needed to tell a
  /// brand-new plugin (auto-enable it) apart from one the user deliberately
  /// switched off (leave it off) — both look identical from
  /// `enabledPluginIdentifiers` alone.
  private static let knownPluginIdentifiersDefaultsKey = "userPluginKnownIdentifiers"
  private static let pluginSettingValuesDefaultsKey = "userPluginSettingValuesByPluginIdentifier"
  private static let supportedPluginAPIVersion = UserPluginManifest.defaultPluginAPIVersion

  private static let allowedCapabilities: Set<String> = [
    "checkvist-sync",
    "obsidian",
    "google-calendar",
    "mcp",
    "custom",
  ]

  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "plugins")
  private let builtInPluginIdentifiers: Set<String>
  private let currentAppVersion: String?
  private let defaults: UserDefaults
  private let fileManager: FileManager

  private(set) var pluginsDirectoryURL: URL
  private(set) var installedPlugins: [InstalledUserPlugin] = []
  private(set) var validationIssues: [PluginValidationIssue] = []
  private(set) var enabledPluginIdentifiers: Set<String>
  private var knownPluginIdentifiers: Set<String>
  var lastErrorMessage: String?

  init(
    builtInPluginIdentifiers: Set<String>,
    currentAppVersion: String? = nil,
    pluginsDirectoryURL: URL? = nil,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) {
    self.builtInPluginIdentifiers = builtInPluginIdentifiers
    let resolvedAppVersion = currentAppVersion ?? Self.bundleAppVersion()
    self.currentAppVersion = resolvedAppVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.defaults = defaults
    self.fileManager = fileManager
    self.pluginsDirectoryURL =
      pluginsDirectoryURL?.standardizedFileURL
      ?? Self.defaultPluginsDirectoryURL(fileManager: fileManager)
    let storedEnabled = Set(
      defaults.stringArray(forKey: Self.enabledPluginIdentifiersDefaultsKey) ?? []
    )
    self.enabledPluginIdentifiers = storedEnabled
    // Installs predating this key never persisted a "known" set. Seeding it
    // from the enabled set keeps their first launch a no-op instead of
    // re-announcing every installed plugin as new.
    self.knownPluginIdentifiers =
      defaults.object(forKey: Self.knownPluginIdentifiersDefaultsKey) == nil
      ? storedEnabled
      : Set(defaults.stringArray(forKey: Self.knownPluginIdentifiersDefaultsKey) ?? [])
    do {
      try ensurePluginsDirectoryExists()
      reloadInstalledPlugins()
    } catch {
      lastErrorMessage = "Failed to initialize plugin directory: \(error.localizedDescription)"
    }
  }

  var sortedInstalledPlugins: [InstalledUserPlugin] {
    installedPlugins.sorted { lhs, rhs in
      lhs.manifest.name.localizedCaseInsensitiveCompare(rhs.manifest.name) == .orderedAscending
    }
  }

  func isPluginEnabled(_ pluginIdentifier: String) -> Bool {
    enabledPluginIdentifiers.contains(pluginIdentifier)
  }

  func setPluginEnabled(_ enabled: Bool, pluginIdentifier: String) {
    if enabled {
      enabledPluginIdentifiers.insert(pluginIdentifier)
    } else {
      enabledPluginIdentifiers.remove(pluginIdentifier)
    }
    persistEnabledPluginIdentifiers()
  }

  func reloadInstalledPlugins() {
    do {
      lastErrorMessage = nil
      try ensurePluginsDirectoryExists()
      let folderURLs = try fileManager.contentsOfDirectory(
        at: pluginsDirectoryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ).filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }

      var resolvedPlugins: [InstalledUserPlugin] = []
      var resolvedIssues: [PluginValidationIssue] = []
      var identifiersSeen = Set<String>()

      for folderURL in folderURLs {
        let pluginFolderName = folderURL.lastPathComponent
        let manifestURL = folderURL.appendingPathComponent("plugin.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
          logger.info("Skipping plugin folder '\(pluginFolderName)': no plugin.json found")
          continue
        }

        do {
          let manifest = try loadManifest(at: manifestURL)
          try validateManifest(manifest, pluginRootURL: folderURL)

          if identifiersSeen.contains(manifest.id) {
            resolvedIssues.append(
              PluginValidationIssue(
                pluginFolderName: pluginFolderName,
                message: "Duplicate plugin id \(manifest.id)."
              )
            )
            continue
          }
          identifiersSeen.insert(manifest.id)
          resolvedPlugins.append(InstalledUserPlugin(manifest: manifest, folderURL: folderURL))
        } catch {
          resolvedIssues.append(
            PluginValidationIssue(
              pluginFolderName: pluginFolderName,
              message: error.localizedDescription
            )
          )
        }
      }

      let installedIdentifiers = Set(resolvedPlugins.map(\.manifest.id))
      var normalizedEnabled = enabledPluginIdentifiers.intersection(installedIdentifiers)
      // Auto-enable only plugins we have never seen before. Testing against
      // `enabledPluginIdentifiers` here (as this used to) re-enabled anything
      // the user had switched off, because "disabled" and "newly discovered"
      // are the same state in that set.
      for plugin in resolvedPlugins where !knownPluginIdentifiers.contains(plugin.manifest.id) {
        normalizedEnabled.insert(plugin.manifest.id)
      }
      // Forget uninstalled plugins so a later reinstall counts as new again.
      knownPluginIdentifiers = installedIdentifiers
      persistKnownPluginIdentifiers()

      installedPlugins = resolvedPlugins
      validationIssues = resolvedIssues.sorted {
        $0.pluginFolderName.localizedCaseInsensitiveCompare($1.pluginFolderName)
          == .orderedAscending
      }
      enabledPluginIdentifiers = normalizedEnabled
      persistEnabledPluginIdentifiers()
      cleanupStalePluginSettingValues(activePluginIdentifiers: installedIdentifiers)
      if !validationIssues.isEmpty {
        lastErrorMessage = "Some plugins failed validation. Open Plugins settings for details."
      }
    } catch {
      lastErrorMessage = "Failed to reload plugins: \(error.localizedDescription)"
    }
  }

  func openPluginsFolder() {
    do {
      try ensurePluginsDirectoryExists()
      NSWorkspace.shared.open(pluginsDirectoryURL)
    } catch {
      lastErrorMessage = "Failed to open plugins folder: \(error.localizedDescription)"
    }
  }

  func revealPluginInFinder(_ plugin: InstalledUserPlugin) {
    NSWorkspace.shared.activateFileViewerSelecting([plugin.folderURL])
  }

  func removePlugin(_ plugin: InstalledUserPlugin) {
    do {
      try fileManager.removeItem(at: plugin.folderURL)
      enabledPluginIdentifiers.remove(plugin.manifest.id)
      persistEnabledPluginIdentifiers()
      clearSettingsValues(forPluginIdentifier: plugin.manifest.id)
      reloadInstalledPlugins()
    } catch {
      lastErrorMessage = "Failed to remove plugin: \(error.localizedDescription)"
    }
  }

  func installPluginPackageInteractively() {
    do {
      try ensurePluginsDirectoryExists()
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = true
      panel.allowsMultipleSelection = false
      panel.allowedContentTypes = {
        var contentTypes: [UTType] = [.zip]
        if let pluginArchiveType = UTType(filenameExtension: "priority-plugin") {
          contentTypes.append(pluginArchiveType)
        }
        return contentTypes
      }()
      panel.prompt = "Install Plugin"
      panel.message =
        "Choose a plugin folder, .zip, or .priority-plugin package containing plugin.json."

      guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
      try installPlugin(from: sourceURL)
      reloadInstalledPlugins()
    } catch {
      lastErrorMessage = "Failed to install plugin: \(error.localizedDescription)"
    }
  }

  func installPlugin(from sourceURL: URL) throws {
    try ensurePluginsDirectoryExists()
    let resolvedPackage = try resolvePluginPackage(from: sourceURL)
    defer {
      for temporaryURL in resolvedPackage.temporaryURLs {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    let resolvedPluginRootURL = resolvedPackage.pluginRootURL
    let manifestURL = resolvedPluginRootURL.appendingPathComponent("plugin.json")
    let manifest = try loadManifest(at: manifestURL)
    try validateManifest(manifest, pluginRootURL: resolvedPluginRootURL)

    if builtInPluginIdentifiers.contains(manifest.id) {
      throw PluginInstallError.pluginIdentifierConflictsWithBuiltIn(manifest.id)
    }

    let destinationURL = pluginsDirectoryURL.appendingPathComponent(manifest.id, isDirectory: true)
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw PluginInstallError.pluginAlreadyInstalled(manifest.id)
    }
    try fileManager.copyItem(at: resolvedPluginRootURL, to: destinationURL)
    enabledPluginIdentifiers.insert(manifest.id)
    persistEnabledPluginIdentifiers()
  }

  func settingValue(pluginIdentifier: String, key: String) -> String? {
    pluginSettingValuesByPluginIdentifier[pluginIdentifier]?[key]
  }

  func setSettingValue(_ value: String?, pluginIdentifier: String, key: String) {
    var byPlugin = pluginSettingValuesByPluginIdentifier
    var values = byPlugin[pluginIdentifier] ?? [:]
    if let value, !value.isEmpty {
      values[key] = value
    } else {
      values.removeValue(forKey: key)
    }
    byPlugin[pluginIdentifier] = values.isEmpty ? nil : values
    pluginSettingValuesByPluginIdentifier = byPlugin
    persistPluginSettingValues()
  }

  private var pluginSettingValuesByPluginIdentifier: [String: [String: String]] {
    get {
      defaults.dictionary(forKey: Self.pluginSettingValuesDefaultsKey)
        as? [String: [String: String]]
        ?? [:]
    }
    set {
      defaults.set(newValue, forKey: Self.pluginSettingValuesDefaultsKey)
    }
  }

  private func cleanupStalePluginSettingValues(activePluginIdentifiers: Set<String>) {
    var values = pluginSettingValuesByPluginIdentifier
    let staleIdentifiers = Set(values.keys).subtracting(activePluginIdentifiers)
    for identifier in staleIdentifiers {
      values.removeValue(forKey: identifier)
    }
    pluginSettingValuesByPluginIdentifier = values
  }

  private func clearSettingsValues(forPluginIdentifier pluginIdentifier: String) {
    var values = pluginSettingValuesByPluginIdentifier
    values.removeValue(forKey: pluginIdentifier)
    pluginSettingValuesByPluginIdentifier = values
  }

  private func persistPluginSettingValues() {
    defaults.set(pluginSettingValuesByPluginIdentifier, forKey: Self.pluginSettingValuesDefaultsKey)
  }

  private func persistEnabledPluginIdentifiers() {
    defaults.set(
      Array(enabledPluginIdentifiers).sorted(), forKey: Self.enabledPluginIdentifiersDefaultsKey)
  }

  private func persistKnownPluginIdentifiers() {
    defaults.set(
      Array(knownPluginIdentifiers).sorted(), forKey: Self.knownPluginIdentifiersDefaultsKey)
  }

  private func ensurePluginsDirectoryExists() throws {
    if !fileManager.fileExists(atPath: pluginsDirectoryURL.path) {
      try fileManager.createDirectory(
        at: pluginsDirectoryURL,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }
    try writeBootstrapReadmeIfNeeded()
    try writeTemplatePluginsIfNeeded()
  }

  private func writeBootstrapReadmeIfNeeded() throws {
    let readmeURL = pluginsDirectoryURL.appendingPathComponent("README.txt")
    guard !fileManager.fileExists(atPath: readmeURL.path) else { return }
    let readme = """
      Priority user plugins folder

      End-user plugin install methods:
      1) Open Preferences -> Plugins -> Install Plugin
      2) Or drop plugin folders directly in this directory

      Plugin package requirements:
      - Each plugin directory must include plugin.json at its root
      - Optional package formats: .zip and .priority-plugin
      - Installed folders are named by plugin id

      Built-in integrations are bundled with the app and appear in Preferences automatically.
      An example plugin template is available under ./templates/example-plugin.
      """
    try readme.write(to: readmeURL, atomically: true, encoding: .utf8)
  }

  private func writeTemplatePluginsIfNeeded() throws {
    let templatesRootURL = pluginsDirectoryURL.appendingPathComponent(
      "templates", isDirectory: true)
    if !fileManager.fileExists(atPath: templatesRootURL.path) {
      try fileManager.createDirectory(
        at: templatesRootURL,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }

    for template in templateDefinitions {
      let folderURL = templatesRootURL.appendingPathComponent(
        template.folderName, isDirectory: true)
      if !fileManager.fileExists(atPath: folderURL.path) {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
      }

      let manifestURL = folderURL.appendingPathComponent("plugin.json")
      if !fileManager.fileExists(atPath: manifestURL.path) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(template.manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
      }

      if let entrypointFileName = template.entrypointFileName {
        let entrypointURL = folderURL.appendingPathComponent(entrypointFileName)
        if !fileManager.fileExists(atPath: entrypointURL.path) {
          let contents = """
            # Placeholder entrypoint for \(template.manifest.name)
            # Replace with your executable script or binary bridge.
            """
          try contents.write(to: entrypointURL, atomically: true, encoding: .utf8)
        }
      }
    }
  }

  private func loadManifest(at url: URL) throws -> UserPluginManifest {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(UserPluginManifest.self, from: data)
  }

  private func validateManifest(_ manifest: UserPluginManifest, pluginRootURL: URL) throws {
    let trimmedID = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else { throw PluginInstallError.invalidPluginID }
    guard !trimmedName.isEmpty else { throw PluginInstallError.invalidPluginName }
    guard trimmedID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
      throw PluginInstallError.invalidPluginID
    }

    for capability in manifest.capabilities where !Self.allowedCapabilities.contains(capability) {
      throw PluginInstallError.invalidCapability(capability)
    }

    let resolvedPluginAPIVersion = manifest.pluginApiVersion ?? Self.supportedPluginAPIVersion
    guard resolvedPluginAPIVersion > 0 else {
      throw PluginInstallError.invalidPluginAPIVersion
    }
    guard resolvedPluginAPIVersion == Self.supportedPluginAPIVersion else {
      throw PluginInstallError.unsupportedPluginAPIVersion(resolvedPluginAPIVersion)
    }

    if let minAppVersion = manifest.minAppVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
      !minAppVersion.isEmpty
    {
      guard Self.isValidVersionString(minAppVersion) else {
        throw PluginInstallError.invalidMinAppVersion(minAppVersion)
      }
      guard let currentAppVersion, !currentAppVersion.isEmpty else {
        throw PluginInstallError.appVersionUnavailable
      }
      if !Self.isVersion(currentAppVersion, atLeast: minAppVersion) {
        throw PluginInstallError.appVersionTooOld(
          minimum: minAppVersion, current: currentAppVersion)
      }
    }

    if let entrypoint = manifest.entrypoint,
      !entrypoint.trimmingCharacters(in: .whitespaces).isEmpty
    {
      guard !entrypoint.hasPrefix("/") else {
        throw PluginInstallError.invalidEntrypointPath(entrypoint)
      }
      let entrypointURL = pluginRootURL.appendingPathComponent(entrypoint).standardizedFileURL
      guard entrypointURL.path.hasPrefix(pluginRootURL.standardizedFileURL.path) else {
        throw PluginInstallError.invalidEntrypointPath(entrypoint)
      }
      guard fileManager.fileExists(atPath: entrypointURL.path) else {
        throw PluginInstallError.missingEntrypoint(entrypoint)
      }
    }
  }

  private func resolvePluginPackage(from sourceURL: URL) throws -> ResolvedPluginPackage {
    if sourceURL.hasDirectoryPath {
      let manifestURL = sourceURL.appendingPathComponent("plugin.json")
      guard fileManager.fileExists(atPath: manifestURL.path) else {
        throw PluginInstallError.pluginManifestNotFound
      }
      return ResolvedPluginPackage(pluginRootURL: sourceURL, temporaryURLs: [])
    }

    let lowercasedExtension = sourceURL.pathExtension.lowercased()
    guard lowercasedExtension == "zip" || lowercasedExtension == "priority-plugin" else {
      throw PluginInstallError.unsupportedSource
    }

    let extractionRoot = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)

    guard try extractArchive(sourceURL, into: extractionRoot) else {
      try? fileManager.removeItem(at: extractionRoot)
      throw PluginInstallError.archiveExtractionFailed
    }

    let directManifestURL = extractionRoot.appendingPathComponent("plugin.json")
    if fileManager.fileExists(atPath: directManifestURL.path) {
      let stagedPluginRoot = try copyExtractedPluginRoot(from: extractionRoot)
      return ResolvedPluginPackage(
        pluginRootURL: stagedPluginRoot,
        temporaryURLs: [extractionRoot, stagedPluginRoot]
      )
    }

    let candidates = try fileManager.contentsOfDirectory(
      at: extractionRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      guard isDirectory else { return false }
      return fileManager.fileExists(atPath: url.appendingPathComponent("plugin.json").path)
    }

    guard !candidates.isEmpty else {
      try? fileManager.removeItem(at: extractionRoot)
      throw PluginInstallError.pluginManifestNotFound
    }
    guard candidates.count == 1 else {
      try? fileManager.removeItem(at: extractionRoot)
      throw PluginInstallError.multiplePluginManifestsFound
    }

    let stagedPluginRoot = try copyExtractedPluginRoot(from: candidates[0])
    return ResolvedPluginPackage(
      pluginRootURL: stagedPluginRoot,
      temporaryURLs: [extractionRoot, stagedPluginRoot]
    )
  }

  private func copyExtractedPluginRoot(from extractedRoot: URL) throws -> URL {
    let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try fileManager.copyItem(at: extractedRoot, to: stagingURL)
    return stagingURL
  }

  private func extractArchive(_ sourceURL: URL, into destinationURL: URL) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", sourceURL.path, destinationURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return false }

    // Validate that no extracted paths escape the destination via path traversal.
    // Both sides are symlink-resolved so the comparison comes from the same
    // namespace, and the prefix carries a trailing separator so a sibling
    // directory whose name merely starts with the destination's (".../abc" vs
    // ".../abcdef") can't slip through a bare `hasPrefix`.
    let canonicalDestination = destinationURL.resolvingSymlinksInPath().standardizedFileURL.path
    let containmentPrefix =
      canonicalDestination.hasSuffix("/") ? canonicalDestination : canonicalDestination + "/"
    if let enumerator = fileManager.enumerator(
      at: destinationURL, includingPropertiesForKeys: [.isSymbolicLinkKey])
    {
      for case let fileURL as URL in enumerator {
        // Resolve symlinks so we catch links pointing outside the destination.
        let resolvedPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == canonicalDestination || resolvedPath.hasPrefix(containmentPrefix)
        else {
          // Path traversal detected — clean up and fail.
          try? fileManager.removeItem(at: destinationURL)
          return false
        }
      }
    }
    return true
  }

  private static func defaultPluginsDirectoryURL(fileManager: FileManager) -> URL {
    AppIdentity.applicationSupportDirectory(fileManager: fileManager)
      .appendingPathComponent("Plugins", isDirectory: true)
  }

  private static func bundleAppVersion() -> String? {
    let info = Bundle.main.infoDictionary
    let shortVersion = info?["CFBundleShortVersionString"] as? String
    if let shortVersion, !shortVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return shortVersion
    }
    let bundleVersion = info?["CFBundleVersion"] as? String
    if let bundleVersion, !bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return bundleVersion
    }
    return nil
  }

  private static func isValidVersionString(_ version: String) -> Bool {
    versionComponents(version) != nil
  }

  private static func isVersion(_ current: String, atLeast minimum: String) -> Bool {
    guard let currentParts = versionComponents(current),
      let minimumParts = versionComponents(minimum)
    else {
      return false
    }

    let maxLength = max(currentParts.count, minimumParts.count)
    for index in 0..<maxLength {
      let left = index < currentParts.count ? currentParts[index] : 0
      let right = index < minimumParts.count ? minimumParts[index] : 0
      if left > right { return true }
      if left < right { return false }
    }
    return true
  }

  private static func versionComponents(_ raw: String) -> [Int]? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let segments = trimmed.split(separator: ".")
    guard !segments.isEmpty else { return nil }

    var parsed: [Int] = []
    parsed.reserveCapacity(segments.count)

    for segment in segments {
      let numbersOnly = segment.prefix { $0.isNumber }
      guard !numbersOnly.isEmpty, let value = Int(numbersOnly) else {
        return nil
      }
      parsed.append(value)
    }
    return parsed
  }

  private var templateDefinitions: [PluginTemplateDefinition] {
    [
      PluginTemplateDefinition(
        folderName: "example-plugin",
        manifest: UserPluginManifest(
          id: "example.plugin",
          name: "Example Plugin",
          version: "0.1.0",
          pluginApiVersion: Self.supportedPluginAPIVersion,
          minAppVersion: currentAppVersion,
          summary: "Template for a user-installed plugin manifest.",
          iconSystemName: "puzzlepiece.extension",
          capabilities: ["custom"],
          entrypoint: "main.sh",
          settingsSchema: [
            .init(
              key: "api_base",
              title: "API Base URL",
              type: .string,
              help: "Optional API endpoint for your plugin backend.",
              defaultValue: "https://example.com"
            ),
            .init(
              key: "enabled",
              title: "Enable feature",
              type: .bool,
              defaultBool: true
            ),
            .init(
              key: "transport",
              title: "Transport",
              type: .select,
              defaultValue: "stdio",
              options: [
                .init(value: "stdio", label: "stdio"),
                .init(value: "http", label: "http"),
              ]
            ),
          ]
        ),
        entrypointFileName: "main.sh"
      )
    ]
  }
}
// swiftlint:enable type_body_length
