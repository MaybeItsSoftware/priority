import AppKit
import Foundation
import Observation
import PriorityCore
import os

/// Loads the user's themes from `~/Library/Application Support/Priority/themes/`
/// and keeps them current as the files change.
///
/// The one provider of user themes: it turns each `*.json` in the folder into
/// a `UserThemePlugin`, and `ThemeManager` lists those after the built-ins.
/// The decoding, `extends` and merging are `ThemeFileLoader`'s, in
/// `PriorityCore`, where they are tested; this is the folder, the watcher and
/// the reporting — shaped like `WorkspaceKeymapStore` on purpose, including
/// watching the directory rather than each file (editors save by renaming a
/// new file over the old one) and re-reading when the app becomes active, for
/// an edit the watcher missed.
@MainActor
@Observable
final class UserThemeLibrary {
  static let shared = UserThemeLibrary()

  /// The themes that loaded, in file-name order.
  private(set) var plugins: [UserThemePlugin] = []
  /// Everything the last load had to say, per file, worst first. Includes the
  /// `validate()` audit of each theme that loaded.
  private(set) var issues: [ThemeFileIssue] = []
  /// The files that were not loaded, and why.
  private(set) var skipped: [(source: String, reason: String)] = []

  /// Told the outcome of every load — empty when every file is fine — and,
  /// on being set, the outcome of the last one, so a hook installed after the
  /// first load still hears about it.
  @ObservationIgnored var onIssues: (([ThemeFileIssue]) -> Void)? {
    didSet { onIssues?(issues) }
  }

  /// The theme being rendered, for "export current theme". Supplied by
  /// `ThemeManager`, which is the one that knows.
  @ObservationIgnored var currentSpecification: (() -> ThemeSpecification)?
  /// Told the identifier of a theme just exported, so it can be put in force
  /// and edits to the file show up live.
  @ObservationIgnored var onExported: ((String) -> Void)?

  @ObservationIgnored private var lastContents: [String: Data]?
  @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
  /// One per theme file, re-armed on every load. The folder watch sees a file
  /// arrive, go or be replaced by rename; only a watch on the file itself sees
  /// an editor that saves in place, and live editing is the point.
  @ObservationIgnored private var fileWatchers: [DispatchSourceFileSystemObject] = []
  @ObservationIgnored private var activationObserver: NSObjectProtocol?
  @ObservationIgnored private var started = false
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "UserThemeLibrary")

  let folderURL: URL

  init(folderURL: URL = UserThemeLibrary.defaultFolderURL()) {
    self.folderURL = folderURL
  }

  /// Beside `keymap.json`, in the same Application Support folder.
  nonisolated static func defaultFolderURL() -> URL {
    WorkspaceKeymapStore.defaultFileURL()
      .deletingLastPathComponent()
      .appending(path: "themes", directoryHint: .isDirectory)
  }

  /// Loads the folder and starts following it. Idempotent, so whoever needs
  /// the themes first can call it.
  func start() {
    guard !started else { return }
    started = true
    try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    reload(force: true)
    watchFolder()
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  /// Re-reads every theme file. Without `force`, a folder whose files have
  /// not changed since the last read is left alone.
  func reload(force: Bool = false) {
    let contents = readFolder()
    // Re-armed even when nothing changed: a file replaced by rename has a new
    // inode, and the old watch would be following the one that went away.
    watchFiles(contents.keys)
    if !force, contents == lastContents { return }
    lastContents = contents

    let library = ThemeFileLoader.load(
      contents.map { ThemeFileSource(name: $0.key, data: $0.value) })
    plugins = library.outcomes.compactMap { outcome in
      outcome.specification.map {
        UserThemePlugin(
          specificationValue: $0,
          fileURL: folderURL.appending(path: outcome.source, directoryHint: .notDirectory))
      }
    }
    skipped = library.outcomes.compactMap { outcome in
      outcome.skippedReason.map { (outcome.source, $0) }
    }
    issues = library.issues
    let errors = issues.filter { $0.severity == .error }.count
    logger.info(
      "User themes: \(self.plugins.count) loaded, \(self.skipped.count) skipped, \(errors) errors")
    onIssues?(issues)
  }

  /// Reveals the folder in Finder, creating it first if need be.
  func openFolder() {
    do {
      try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    } catch {
      report("Could not create the themes folder: \(error.localizedDescription)")
      return
    }
    if watcher == nil { watchFolder() }
    NSWorkspace.shared.open(folderURL)
  }

  /// Writes the theme in force to the folder as a complete, editable file —
  /// every colour and size stated — then opens it and puts the copy in force,
  /// so what the user edits is what they see.
  func exportCurrentTheme() {
    guard let specification = currentSpecification?() else { return }
    let stem = availableStem(for: specification.name)
    var file = ThemeFile(specification: specification)
    file.identifier = ThemeFileLoader.derivedIdentifierPrefix + stem
    file.name = "\(specification.name) copy"
    file.summary = "Exported from \(specification.name). Edit freely; see docs/themes.md."
    let url = folderURL.appending(path: "\(stem).\(ThemeFileLoader.fileExtension)")
    do {
      try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
      try file.encoded().write(to: url, options: .atomic)
    } catch {
      report("Could not export \(specification.name): \(error.localizedDescription)")
      return
    }
    if watcher == nil { watchFolder() }
    reload(force: true)
    if let identifier = file.identifier { onExported?(identifier) }
    NSWorkspace.shared.open(url)
  }

  // MARK: - Private

  private func readFolder() -> [String: Data] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
    var contents: [String: Data] = [:]
    for name in names
    where name.hasSuffix(".\(ThemeFileLoader.fileExtension)") && !name.hasPrefix(".") {
      let url = folderURL.appending(path: name, directoryHint: .notDirectory)
      if let data = try? Data(contentsOf: url) { contents[name] = data }
    }
    return contents
  }

  /// `Chalk Dark` → `chalk-dark-copy`, then `-copy-2`, … until the name is free.
  private func availableStem(for name: String) -> String {
    let slug = name.lowercased()
      .map { $0.isLetter || $0.isNumber ? $0 : "-" }
      .reduce(into: "") { result, character in
        if character == "-", result.last == "-" { return }
        result.append(character)
      }
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let base = (slug.isEmpty ? "theme" : slug) + "-copy"
    let taken = Set(readFolder().keys.map(ThemeFileLoader.stem(of:)))
    var candidate = base
    var counter = 2
    while taken.contains(candidate) {
      candidate = "\(base)-\(counter)"
      counter += 1
    }
    return candidate
  }

  private func report(_ message: String) {
    logger.error("\(message, privacy: .public)")
    onIssues?(issues + [ThemeFileIssue(source: "themes", severity: .error, message: message)])
  }

  private func watchFiles(_ names: Dictionary<String, Data>.Keys) {
    fileWatchers.forEach { $0.cancel() }
    fileWatchers = names.compactMap { name in
      let path = folderURL.appending(path: name, directoryHint: .notDirectory).path
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else { return nil }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.reload() }
      }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      return source
    }
  }

  private func watchFolder() {
    let descriptor = open(folderURL.path, O_EVTONLY)
    guard descriptor >= 0 else { return }  // No folder yet: `openFolder` retries.
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.reload() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    watcher = source
  }
}
