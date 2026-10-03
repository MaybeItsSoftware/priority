import AppKit
import Foundation
import Observation
import PriorityCore
import os

/// Loads `~/Library/Application Support/Takt/keymap.json`, lays it over
/// the catalogue's keys and keeps it in force as the file changes.
///
/// The parsing and merging are `WorkspaceKeymap`'s, in `PriorityCore`, where
/// they are tested; this is the file, the watcher and the reporting. The file
/// is watched through its directory rather than itself, because most editors
/// save by writing a new file and renaming it over the old one, which leaves a
/// watch on the old file's descriptor looking at nothing. The app becoming
/// active re-reads it as well, for an edit the watcher missed.
@MainActor
@Observable
final class WorkspaceKeymapStore {
  static let shared = WorkspaceKeymapStore()

  /// What the last load could not apply. Empty when the file is fine or absent.
  private(set) var issues: [WorkspaceKeymapIssue] = []
  /// Bumped whenever a load changes the bindings in force, so a view that
  /// prints keys — the menu bar, notably — can depend on it and redraw.
  private(set) var revision = 0

  /// Told the outcome of every load — empty when the file is fine — so a
  /// message about an earlier mistake can be taken down once it is fixed.
  @ObservationIgnored var onIssues: (([WorkspaceKeymapIssue]) -> Void)?

  @ObservationIgnored private var lastContents: Data?
  @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
  @ObservationIgnored private var activationObserver: NSObjectProtocol?
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "WorkspaceKeymapStore")

  let fileURL: URL

  init(fileURL: URL = WorkspaceKeymapStore.defaultFileURL()) {
    self.fileURL = fileURL
  }

  /// Beside the workspace database, in the same Application Support folder.
  nonisolated static func defaultFileURL() -> URL {
    AppIdentity.applicationSupportDirectory()
      .appending(path: "keymap.json", directoryHint: .notDirectory)
  }

  /// Loads the file and starts following it. Called once, at launch.
  func start() {
    reload(force: true)
    watchDirectory()
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  /// Re-reads the file and puts it in force. Without `force`, a file whose
  /// contents have not changed since the last read is left alone, so the
  /// activation hook costs one read and a comparison.
  func reload(force: Bool = false) {
    let contents = try? Data(contentsOf: fileURL)
    if !force, contents == lastContents { return }
    lastContents = contents

    let (keymap, parseIssues) = WorkspaceKeymap.parse(contents ?? Data())
    let (bindings, resolveIssues) = keymap.resolve()
    WorkspaceCommandCatalog.install(bindings)
    issues = parseIssues + resolveIssues
    revision += 1
    if issues.isEmpty {
      logger.info("Keymap loaded: \(keymap.bindings.count) bindings")
    } else {
      logger.error("Keymap loaded with \(self.issues.count) problems")
    }
    onIssues?(issues)
  }

  /// Opens the file in the user's editor, creating it — as an empty keymap,
  /// `[]` — first if it does not exist. The format is in
  /// `docs/keyboard-shortcuts.md`; JSON has no comments to carry it in.
  func openFile() {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !manager.fileExists(atPath: fileURL.path) {
        try Data("[]\n".utf8).write(to: fileURL, options: .atomic)
      }
    } catch {
      logger.error("Could not create keymap.json: \(error.localizedDescription)")
      onIssues?([
        .init(kind: .unreadableFile, message: "Could not create keymap.json: \(error.localizedDescription)")
      ])
      return
    }
    if watcher == nil { watchDirectory() }
    NSWorkspace.shared.open(fileURL)
  }

  // MARK: - Following the file

  private func watchDirectory() {
    let directory = fileURL.deletingLastPathComponent()
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { return }  // No folder yet: `openFile` retries.
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
