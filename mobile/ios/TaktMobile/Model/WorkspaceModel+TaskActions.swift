import Foundation
import TaktCore
import TaktWorkspace
import TaktWorkspaceEditing

/// The task commands every surface shares — the outline's swipe actions and
/// context menu, a board card's menu, a day card's, the keyboard. Each is one
/// store call through `perform`, mirroring the Mac's `WorkspaceViewModel`
/// method of the same name.
@MainActor
extension WorkspaceModel {
  // MARK: - Status

  /// Completes an open task or reopens a closed one.
  func toggleComplete(_ taskID: String) {
    guard let task = task(taskID) else { return }
    let completing = task.status == .open
    if perform({ try $0.setStatus(completing ? .completed : .open, for: taskID) }), completing {
      noteCompletion()
    }
  }

  /// Marks a task as no longer worth doing — closed, but not done — or
  /// reopens an invalidated one.
  func toggleInvalidated(_ taskID: String) {
    guard let task = task(taskID) else { return }
    perform { try $0.setStatus(task.status == .cancelled ? .open : .cancelled, for: taskID) }
  }

  func delete(_ taskID: String) {
    if perform({ try $0.deleteTask(id: taskID) }) {
      if navigation.selectedTaskID == taskID { navigation.selectedTaskID = nil }
      if navigation.inspectedTaskID == taskID { navigation.inspectedTaskID = nil }
    }
  }

  // MARK: - Structure

  func indent(_ taskID: String) { perform { try $0.indentTask(id: taskID) } }
  func outdent(_ taskID: String) { perform { try $0.outdentTask(id: taskID) } }
  func move(_ taskID: String, by offset: Int) { perform { try $0.moveTaskWithinSiblings(id: taskID, by: offset) } }

  /// Puts `taskID` immediately before `targetID`, its sibling.
  func place(_ taskID: String, before targetID: String) {
    perform { try $0.moveTaskBefore(id: taskID, targetId: targetID) }
  }

  /// Moves a task (with its subtree) to the top level of another list.
  func move(_ taskID: String, toList listID: String, parentTaskID: String? = nil) {
    if perform({ try $0.moveTask(id: taskID, toListId: listID, parentTaskId: parentTaskID, toVisibleRoot: parentTaskID == nil) }) {
      showToast("Moved to \(listName(for: listID))")
    }
  }

  /// The move picker's "New list …" row: two undo steps, the list then the
  /// move, because the store journals each write on its own.
  func move(_ taskID: String, toNewListNamed name: String) {
    guard let list = performReturning({ try $0.createList(workspaceId: workspace.id, name: name) }) else { return }
    move(taskID, toList: list.id)
  }

  /// ⇧⌥↑ / ⇧⌥↓: to the list above or below this one in the tree, landing at
  /// its top level.
  func moveToAdjacentList(_ taskID: String, by offset: Int) {
    guard let task = task(taskID) else { return }
    let candidates = structure.listsInTreeOrder.filter { $0.completedAt == nil || $0.id == task.listId }
    guard let index = candidates.firstIndex(where: { $0.id == task.listId }) else { return }
    guard candidates.indices.contains(index + offset) else {
      showToast(offset < 0 ? "Already in the first list" : "Already in the last list")
      return
    }
    move(taskID, toList: candidates[index + offset].id)
  }

  /// Turns a task into a list nested where it is, or a nested list back into
  /// a task.
  func toggleListKind(_ taskID: String) {
    guard let task = task(taskID) else { return }
    perform { try $0.setItemKind(task.isList ? .task : .list, for: taskID) }
  }

  func togglePromoted(_ taskID: String) {
    guard let task = task(taskID), task.isList else { return }
    perform { try $0.setNestedListPromoted(task.isPromoted != true, id: taskID) }
  }

  /// Lifts a branch out into a list of its own at the root of the tree.
  @discardableResult
  func extractBranch(_ taskID: String) -> TaskList? {
    let list = performReturning { try $0.moveTaskToFolder(id: taskID, folderId: nil) }
    if let list { showToast("Extracted to \(list.name)") }
    return list
  }

  // MARK: - Creating

  /// Creates a task from typed text, reading capture tokens (`45m #work
  /// @fri !1`) off the end of the title.
  @discardableResult
  func createTask(
    _ typed: String, listID: String, parentTaskID: String? = nil, adjacentTo adjacentID: String? = nil,
    above: Bool = false, atTop: Bool = false, kanbanColumn: String? = nil
  ) -> WorkspaceTask? {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return performReturning {
      try $0.createTask(
        capturing: text, listId: listID, parentTaskId: parentTaskID, kanbanColumn: kanbanColumn,
        atTop: atTop, adjacentTaskId: adjacentID, above: above)
    }
  }

  // MARK: - Editing values

  /// Edits a task through the same draft the inspector saves, so a keyboard
  /// shortcut and the inspector write identically.
  func editValues(_ taskID: String, _ change: (inout TaskEditorValues) -> Void) {
    perform { store in
      var draft = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: taskID))
      change(&draft.values)
      _ = try store.saveTaskEditor(draft)
    }
  }

  func rename(_ taskID: String, to title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, task(taskID)?.title != trimmed else { return }
    editValues(taskID) { $0.title = trimmed }
  }

  func setDue(_ taskID: String, daysFromToday days: Int) {
    let start = Calendar.current.startOfDay(for: .now)
    let day = Calendar.current.date(byAdding: .day, value: days, to: start)
    editValues(taskID) { $0.dueAt = day; $0.dueDate = nil }
  }

  func clearDue(_ taskID: String) {
    editValues(taskID) { $0.dueAt = nil; $0.dueDate = nil }
  }

  // MARK: - Planning

  func isPlannedToday(_ taskID: String) -> Bool {
    (try? store.kanbanColumn(for: taskID)) == NextUpSelector.todayColumnID
  }

  /// Puts the task on today, or takes it off.
  func togglePlannedToday(_ taskID: String) {
    let planned = isPlannedToday(taskID)
    if perform({ try $0.setPlannedForToday(!planned, taskIds: [taskID]) }) {
      showToast(planned ? "Taken off today" : "Planned for today")
    }
  }

  func isDaily(_ taskID: String) -> Bool {
    (try? store.daily(forTaskId: taskID))?.isArchived == false
  }

  /// Attaches a daily commitment to the task, or archives it.
  func toggleDaily(_ taskID: String) {
    let enabled = isDaily(taskID)
    perform { store in
      if enabled {
        try store.archiveDaily(taskId: taskID)
      } else {
        try store.makeDaily(taskId: taskID, targetSeconds: try store.task(id: taskID)?.estimateSeconds)
      }
    }
  }

  /// Opens Focus with this task staged. The Focus screen owns starting the
  /// block, because that is where the estimate is decided.
  func requestFocus(on taskID: String, isPad: Bool) {
    focusRequestTaskID = taskID
    navigation.go(to: .focus, isPad: isPad)
  }
}
