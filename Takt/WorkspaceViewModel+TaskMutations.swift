import Foundation
import TaktCore
import TaktWorkspace

/// The outline's structural writes: completing, moving, indenting and deleting
/// a task. Split from `WorkspaceViewModel.swift` for size — it is the same type.
extension WorkspaceViewModel {
  func toggleTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setStatus(task.status == .open ? .completed : .open, for: task.id)
      if task.status == .open { celebrateCompletion(of: task) }
      // An ordinary task's status is not something the sidebar shows: its
      // counts include finished tasks, and only lists are drawn there.
      reloadOutline(refreshSidebar: task.isList)
      reloadNextUp()
    }
  }

  func moveTask(_ task: WorkspaceTask, toListId listId: String) {
    guard let store else { return }
    perform {
      try store.moveTask(id: task.id, toListId: listId, toVisibleRoot: true)
      if let scopeTaskID, let scope = try store.task(id: scopeTaskID), scope.listId != selectedListID {
        self.scopeTaskID = nil
      }
      if isEverythingSelected || task.listId == selectedListID || listId == selectedListID {
        reloadOutline()
      }
      selectedTaskID = isEverythingSelected || listId == selectedListID ? task.id : nil
    }
  }

  /// ⇧⌥↑ and ⇧⌥↓: the selected task to the list above or below its own in
  /// the sidebar, landing at that list's top level. The cursor stays where the
  /// task was, on its neighbour, so a run of tasks can be sent off one after
  /// another; the status bar says where each went, since it has left the
  /// screen.
  func moveSelectedTaskToAdjacentList(by offset: Int) {
    guard let task = selectedTask else { return }
    let candidates = listsInSidebarOrder.filter {
      !$0.isArchived && $0.completedAt == nil || $0.id == task.listId
    }
    guard let index = candidates.firstIndex(where: { $0.id == task.listId }) else { return }
    guard candidates.indices.contains(index + offset) else {
      onStatusMessage?(offset < 0 ? "Already in the first list" : "Already in the last list")
      return
    }
    let destination = candidates[index + offset]
    let rows = navigationRowIDs()
    let hidden = Set(descendants(of: task).map(\.task.id)).union([task.id])
    let neighbour = rows.firstIndex(of: task.id).flatMap { position in
      rows[(position + 1)...].first { !hidden.contains($0) }
        ?? rows[..<position].last { !hidden.contains($0) }
    }
    moveTask(task, toListId: destination.id)
    if selectedTaskID == nil { selectedTaskID = neighbour }
    onStatusMessage?("Moved to \(destination.name)")
  }

  func moveTaskWithinSiblings(_ task: WorkspaceTask, by offset: Int) {
    guard let store else { return }
    perform {
      try store.moveTaskWithinSiblings(id: task.id, by: offset)
      reloadOutline(refreshSidebar: task.isList)
    }
  }

  func indentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.indentTask(id: task.id)
      reloadOutline(refreshSidebar: task.isList)
    }
  }

  func outdentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.outdentTask(id: task.id)
      reloadOutline(refreshSidebar: task.isList)
    }
  }

  /// The delete keys ask before they act: a task takes its subtasks with it,
  /// and ⌫ sits right beside the keys you type with. Return confirms.
  func requestSelectedTaskDeletion() {
    guard let task = selectedTask else { return }
    requestTaskDeletion(task)
  }

  func requestTaskDeletion(_ task: WorkspaceTask) {
    pendingTaskDeletionID = task.id
  }

  var pendingTaskDeletion: WorkspaceTask? {
    pendingTaskDeletionID.flatMap { task(withID: $0) }
  }

  func confirmPendingTaskDeletion() {
    let task = pendingTaskDeletion
    pendingTaskDeletionID = nil
    if let task { deleteTask(task) }
  }

  func cancelPendingTaskDeletion() {
    pendingTaskDeletionID = nil
  }

  func deleteTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.deleteTask(id: task.id)
      if selectedTaskID == task.id { selectedTaskID = nil }
      if scopeTaskID == task.id { scopeTaskID = task.parentTaskId }
      reloadOutline()
      reloadFocus()
    }
  }
}
