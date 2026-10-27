import AppKit
import Foundation
import TaktWorkspace
import UniformTypeIdentifiers

/// A task's links: Drive files and folders, Obsidian notes and folders, web
/// pages. Stored and described by the Rust core (core/src/links.rs); found by
/// the Links plugin; see docs/links.md.
@MainActor
extension WorkspaceViewModel {
  /// The link picker, on the selected task. Nothing for a list or no task.
  func presentLinkPicker() {
    guard let task = selectedTask, !task.isList else { return }
    presentOverlay(.link(WorkspaceLinkRequest(task: task)))
  }

  /// The task's links, described for drawing.
  func links(of task: WorkspaceTask) -> [WorkspaceTaskLink] {
    (try? store?.links(of: task.id)) ?? []
  }

  /// Links `url` to `task` as one undo step, named as the picker found it.
  /// Returns an error message, or nil once saved.
  @discardableResult
  func addLink(_ url: String, title: String? = nil, mimeType: String? = nil, to task: WorkspaceTask) -> String? {
    guard let store else { return "The workspace is not open." }
    var failure: String?
    perform {
      do {
        try store.addLink(url, title: title, mimeType: mimeType, to: task.id)
      } catch {
        failure = error.localizedDescription
        throw error
      }
      waitingDetailsAreStale = true
      refresh([.outline])
    }
    return failure
  }

  /// Takes `url` off `task`'s links, as one undo step.
  func removeLink(_ url: String, from task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.removeLink(url, from: task.id)
      waitingDetailsAreStale = true
      refresh([.outline])
    }
  }

  /// Opens a link where it lives: the browser, Obsidian, Finder, default app.
  func openLink(_ url: String) {
    if let target = fileURL(from: url) {
      NSWorkspace.shared.open(target)
    } else if let target = URL(string: url) {
      NSWorkspace.shared.open(target)
    } else if let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let target = URL(string: encoded) {
      NSWorkspace.shared.open(target)
    }
  }

  /// Resolves `raw` (file:// URL, absolute path, tilde path) to a local file URL if valid.
  func fileURL(from raw: String) -> URL? {
    if raw.hasPrefix("file://") {
      let pathPart = String(raw.dropFirst(7))
      if let decoded = pathPart.removingPercentEncoding {
        return URL(fileURLWithPath: decoded)
      }
      return URL(string: raw)
    }
    if raw.hasPrefix("/") {
      return URL(fileURLWithPath: raw)
    }
    if raw.hasPrefix("~/") {
      let expanded = NSString(string: raw).expandingTildeInPath
      return URL(fileURLWithPath: expanded)
    }
    if let url = URL(string: raw), url.isFileURL {
      return url
    }
    return nil
  }

  /// Checks whether a local file URL points to a directory.
  func isDirectory(url: URL) -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
      return isDir.boolValue
    }
    return url.path.hasSuffix("/")
  }

  /// Whether the Alacritty terminal emulator is installed on this system.
  var isAlacrittyAvailable: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.alacritty") != nil ||
      FileManager.default.fileExists(atPath: "/Applications/Alacritty.app")
  }

  /// Opens a file or folder link in Finder (opens directory in Finder, or selects file in Finder).
  func openLinkInFinder(_ url: String) {
    guard let target = fileURL(from: url) else {
      openLink(url)
      return
    }
    if isDirectory(url: target) {
      NSWorkspace.shared.open(target)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([target])
    }
  }

  /// Reveals a file or directory selected in Finder.
  func revealInFinder(_ url: String) {
    guard let target = fileURL(from: url) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([target])
  }

  /// Opens a linked folder in Alacritty.
  func openFolderInAlacritty(_ url: String) {
    guard let target = fileURL(from: url) else { return }
    let path = target.path

    let alacrittyApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.alacritty")
      ?? (FileManager.default.fileExists(atPath: "/Applications/Alacritty.app") ? URL(fileURLWithPath: "/Applications/Alacritty.app") : nil)

    guard let appURL = alacrittyApp else {
      openFolderInTerminal(url)
      return
    }

    let binary = appURL.appendingPathComponent("Contents/MacOS/alacritty")
    let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "org.alacritty").isEmpty

    if isRunning && FileManager.default.isExecutableFile(atPath: binary.path) {
      let msg = Process()
      msg.executableURL = binary
      msg.arguments = ["msg", "create-window", "--working-directory", path]
      try? msg.run()
      msg.waitUntilExit()
      if msg.terminationStatus == 0 {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "org.alacritty").first {
          app.activate()
        }
        return
      }
    }

    let config = NSWorkspace.OpenConfiguration()
    config.arguments = ["--working-directory", path]
    config.createsNewApplicationInstance = isRunning

    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
      if let app {
        app.activate()
      } else if let error {
        NSLog("Takt: Failed to open Alacritty: %@", error.localizedDescription)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Alacritty", "--args", "--working-directory", path]
        try? proc.run()
      }
    }
  }

  /// Opens a linked folder in macOS Terminal.
  func openFolderInTerminal(_ url: String) {
    guard let target = fileURL(from: url) else { return }
    if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
      let config = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open([target], withApplicationAt: terminalURL, configuration: config) { app, _ in
        app?.activate()
      }
    } else {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      proc.arguments = ["-a", "Terminal", target.path]
      try? proc.run()
    }
  }

  /// Opens a file or folder with a specific application.
  func openFile(_ url: String, withApplicationAt appURL: URL) {
    guard let target = fileURL(from: url) else { return }
    let config = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: config) { app, error in
      if let app {
        app.activate()
      } else if let error {
        NSLog("Takt: Failed to open %@ with %@: %@", target.path, appURL.path, error.localizedDescription)
      }
    }
  }

  /// Prompts the user to choose an application to open this file with.
  func promptOpenWith(_ url: String) {
    guard let target = fileURL(from: url) else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose Application"
    panel.prompt = "Choose"
    panel.message = "Choose an application to open “\(target.lastPathComponent)”"
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    if panel.runModal() == .OK, let chosenAppURL = panel.url {
      openFile(url, withApplicationAt: chosenAppURL)
    }
  }

  /// Returns the default application and other compatible applications to open `url`.
  func availableApplications(for url: String) -> (defaultApp: URL?, otherApps: [URL]) {
    guard let target = fileURL(from: url) else { return (nil, []) }
    let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: target)
    let allApps = NSWorkspace.shared.urlsForApplications(toOpen: target)
    var seen = Set<String>()
    if let defaultPath = defaultApp?.path {
      seen.insert(defaultPath)
    }
    var other: [URL] = []
    for app in allApps {
      if !seen.contains(app.path) {
        seen.insert(app.path)
        other.append(app)
      }
    }
    other.sort {
      $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
        $1.deletingPathExtension().lastPathComponent
      ) == .orderedAscending
    }
    return (defaultApp, other)
  }

  /// Presents an open panel to link a file or folder to `task`.
  func pickFileLink(for task: WorkspaceTask) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Link"
    panel.message = "Choose a file or folder to link"
    if panel.runModal() == .OK, let url = panel.url {
      let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      var finalURL = url
      if isDir && !finalURL.path.hasSuffix("/") {
        finalURL.appendPathComponent("")
      }
      addLink(finalURL.absoluteString, title: url.lastPathComponent, to: task)
    }
  }

  /// Links a dropped local file or folder URL to `task`.
  func linkDroppedURL(_ url: URL, to task: WorkspaceTask) {
    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    var finalURL = url
    if isDir && !finalURL.path.hasSuffix("/") {
      finalURL.appendPathComponent("")
    }
    let title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    addLink(finalURL.absoluteString, title: title, to: task)
  }

  /// Creates a new task named after the dropped file or folder URL and links it.
  func createTaskWithDroppedURL(_ url: URL, inKanbanColumn column: WorkspaceKanbanColumn? = nil) {
    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    var finalURL = url
    if isDir && !finalURL.path.hasSuffix("/") {
      finalURL.appendPathComponent("")
    }
    let title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    if viewMode == .board {
      if let task = createBoardTask(named: title, in: column) {
        addLink(finalURL.absoluteString, title: title, to: task)
      }
    } else {
      guard let store,
        let destinationID = isMultiListScope ? (folderScopeDestinationID ?? newTaskListID) : selectedListID,
        let destinationList = lists.first(where: { $0.id == destinationID })
      else { return }
      perform {
        let parentID = isMultiListScope
          ? try self.visibleRootParentTaskID(for: destinationList, store: store) : self.scopeTaskID
        let task = try store.createTask(capturing: title, listId: destinationID, parentTaskId: parentID)
        self.selectedTaskID = task.id
        self.reloadOutline()
        self.addLink(finalURL.absoluteString, title: title, to: task)
      }
    }
  }
}

/// Helper for reading dragged file URLs from Finder drops.
enum WorkspaceFileDrop {
  @discardableResult
  static func handleFileDrop(
    providers: [NSItemProvider],
    onURL: @escaping @MainActor (URL) -> Void
  ) -> Bool {
    var handled = false
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
         provider.hasItemConformingToTypeIdentifier("public.file-url") ||
         provider.canLoadObject(ofClass: URL.self) {
        handled = true
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          if let url, url.isFileURL {
            Task { @MainActor in
              onURL(url)
            }
          } else {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
              let resolvedURL: URL? = {
                if let u = item as? URL { return u }
                if let u = item as? NSURL { return u as URL }
                if let data = item as? Data, let str = String(data: data, encoding: .utf8), let u = URL(string: str) { return u }
                return nil
              }()
              if let resolvedURL, resolvedURL.isFileURL {
                Task { @MainActor in
                  onURL(resolvedURL)
                }
              }
            }
          }
        }
      }
    }
    return handled
  }
}
