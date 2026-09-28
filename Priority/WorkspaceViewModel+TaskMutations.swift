import Foundation
import PriorityCore
import PriorityWorkspace

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

  func deleteSelectedTask() {
    guard let store, let task = selectedTask else { return }
    perform {
      try store.deleteTask(id: task.id)
      selectedTaskID = nil
      if scopeTaskID == task.id { scopeTaskID = task.parentTaskId }
      reloadOutline()
      reloadFocus()
    }
  }
}
