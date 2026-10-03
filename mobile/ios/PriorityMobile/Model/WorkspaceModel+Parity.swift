import Foundation
import PriorityCore
import PriorityWorkspace
import UIKit

/// How far a task has got: its subtasks, the time against it and its
/// estimate. What the Mac's "Show the task's progress" brings up.
struct TaskProgress: Equatable, Sendable {
  var subtasks = 0
  var subtasksDone = 0
  var loggedSeconds = 0
  var estimateSeconds: Int?

  static func load(store: WorkspaceStore, taskID: String) throws -> TaskProgress {
    guard let task = try store.task(id: taskID) else { return TaskProgress() }
    let tree = try store.listTrees(in: [task.listId])[task.listId]
    var progress = TaskProgress(estimateSeconds: task.estimateSeconds)
    var stack = tree?.children(of: taskID) ?? []
    while let next = stack.popLast() {
      progress.subtasks += 1
      if next.status != .open { progress.subtasksDone += 1 }
      stack += tree?.children(of: next.id) ?? []
    }
    progress.loggedSeconds = try store.workBlocks(for: taskID).reduce(0) { $0 + $1.seconds }
    return progress
  }

  /// "3 of 5 subtasks done · worked 1h 10m of 2h".
  var summary: String {
    var parts: [String] = []
    if subtasks > 0 { parts.append("\(subtasksDone) of \(subtasks) subtasks done") }
    if loggedSeconds > 0 || estimateSeconds != nil {
      var time = "worked \(Format.duration(loggedSeconds))"
      if let estimateSeconds { time += " of \(Format.duration(estimateSeconds))" }
      parts.append(time)
    }
    let line = parts.isEmpty ? "No subtasks and no time logged yet" : parts.joined(separator: " · ")
    return line.prefix(1).uppercased() + line.dropFirst()
  }
}

/// The desktop commands a phone reaches through menus and the iPad keyboard
/// that have no single-call home elsewhere.
@MainActor
extension WorkspaceModel {
  /// Reads the task's progress off the main actor and shows it in passing.
  func showProgress(_ taskID: String) {
    let store = store
    Task { @MainActor [weak self] in
      let progress = await Task.detached(priority: .userInitiated) {
        try? TaskProgress.load(store: store, taskID: taskID)
      }.value
      if let progress { self?.showToast(progress.summary) }
    }
  }

  /// Opens the task's first web or Obsidian link — the same check from a
  /// menu and from ⌘O.
  func openFirstLink(_ taskID: String) {
    guard let snapshot = try? store.taskEditorSnapshot(for: taskID),
      let link = snapshot.metadata.externalLinks.first, let url = URL(string: link),
      ["https", "http", "obsidian"].contains(url.scheme?.lowercased() ?? "")
    else {
      showToast("This task has no link")
      return
    }
    UIApplication.shared.open(url)
  }

  func clearPriority(_ taskID: String) {
    editValues(taskID) { $0.priority = 0 }
  }

  /// Brings back whichever list was archived last. The Mac's ⇧⌘R.
  func restoreLastArchivedList() {
    guard let list = structure.archivedLists.max(by: { $0.updatedAt < $1.updatedAt }) else {
      showToast("No archived lists")
      return
    }
    setArchived(false, list: list.id)
  }

  /// Opens or closes every folder in the list tree. Each folder's state is
  /// its own stored flag, so the tree's disclosure groups follow at once.
  func setAllFoldersExpanded(_ expanded: Bool, defaults: UserDefaults = .standard) {
    for folder in structure.folders {
      defaults.set(expanded, forKey: Self.folderExpandedKey(folder.id))
    }
  }

  nonisolated static func folderExpandedKey(_ folderID: String) -> String { "folderExpanded.\(folderID)" }
}
