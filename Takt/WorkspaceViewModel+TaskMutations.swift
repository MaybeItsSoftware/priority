import Foundation
import TaktCore
import TaktWorkspace

/// The outline's structural writes: completing, moving, indenting and deleting
/// a task. Split from `WorkspaceViewModel.swift` for size — it is the same type.
extension WorkspaceViewModel {
  func toggleTask(_ task: WorkspaceTask) {
    guard let store else { return }
    // A habit is ticked for the day, not finished: its task is what the
    // next appearance is made of.
    if task.status == .open, isHabitTask(task) {
      if dailyItem(for: task) != nil {
        toggleDailyProgress(task)
      } else if let daily = try? store.daily(forTaskId: task.id) {
        // Not showing today, so there is nothing to un-tick: doing it now
        // simply counts for today.
        perform {
          try store.logContribution(dailyId: daily.id)
          reloadDailies()
          reloadNextUp()
          refresh([.outline, .board])
        }
      }
      return
    }
    perform {
      try store.setStatus(task.status == .open ? .completed : .open, for: task.id)
      if task.status == .open { celebrateCompletion(of: task) }
      // An ordinary task's status is not something the sidebar shows: its
      // counts include finished tasks, and only lists are drawn there.
      reloadOutline(refreshSidebar: task.isList)
      // Closing a task can end the habits made from it.
      reloadDailies()
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

  /// ⌥↑/⌥↓ on the board: past the neighbour drawn beside it — the card above
  /// or below in its column, or for a subtask row the row above or below on
  /// its card. See `WorkspaceBoardShape.siblingStep`.
  func moveBoardTaskWithinSiblings(_ task: WorkspaceTask, by offset: Int) {
    guard let store else { return }
    let column = boardColumns.first { $0.id == activeBoardColumnID }
    let cards = column.map { tasks(in: $0) } ?? []
    let drawn: [WorkspaceTask]
    if cards.contains(where: { $0.id == task.id }) {
      drawn = cards
    } else if let cardID = boardCardID(owning: task.id), let card = self.task(withID: cardID) {
      drawn = boardTreeRows(of: card).map(\.task)
    } else {
      return
    }
    let blocked = Set(drawn.filter { isBlocked($0) }.map(\.id))
    guard let step = WorkspaceBoardShape.siblingStep(of: task.id, by: offset, drawn: drawn, blocked: blocked)
    else { return }
    perform {
      try store.moveTaskBefore(id: step.moving, targetId: step.before)
      reloadOutline(refreshSidebar: task.isList)
    }
  }

  /// Puts the task inside the one above it. On the board "above" is the card
  /// above in the same column: the store's own indent takes the previous
  /// sibling in the list's order, which there is as likely as not a card in
  /// another column, so a new card filed itself under a task you could not
  /// see beside it.
  func indentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    if viewMode == .board, let column = column(for: task) {
      let cards = tasks(in: column)
      if let index = cards.firstIndex(where: { $0.id == task.id }) {
        guard index > 0 else { return }
        let parent = cards[index - 1]
        perform {
          try store.moveTask(id: task.id, toListId: parent.listId, parentTaskId: parent.id)
          reloadOutline(refreshSidebar: task.isList)
        }
        return
      }
    }
    perform {
      try store.indentTask(id: task.id)
      reloadOutline(refreshSidebar: task.isList)
    }
  }

  /// Takes the task out a level, but never above the pane's own root: a card
  /// at the top of a nested list's board stays in the list rather than
  /// leaving it for the level the list sits on. A combined scope enters no
  /// task, so there only a list's own root bounds it.
  func outdentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      let moved = try store.outdentTask(id: task.id, within: isMultiListScope ? nil : scopeTaskID)
      guard moved else {
        onStatusMessage?("Already at the top level here")
        return
      }
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
