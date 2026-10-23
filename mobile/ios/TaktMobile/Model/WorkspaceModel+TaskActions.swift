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

  /// Completes an open task or reopens a closed one. A habit is ticked for
  /// the day instead, never finished — its task is what the next appearance
  /// is made of — as the Mac's `toggleTask` and Android's `tickHabit` do.
  func toggleComplete(_ taskID: String) {
    guard let task = task(taskID) else { return }
    if task.status == .open, let habit = habitTick(for: taskID) {
      tickHabit(habit, title: task.title)
      return
    }
    let completing = task.status == .open
    guard perform({ try $0.setStatus(completing ? .completed : .open, for: taskID) }) else { return }
    if completing { noteCompletion() }
    announce(completing ? "Completed \(task.title)" : "Reopened \(task.title)")
  }

  /// A habit on an open task, and whether today's appearance is already
  /// ticked: what ticking its task does instead of completing it. Nil for
  /// anything that is not a live habit.
  func habitTick(for taskID: String, on day: Date = .now) -> (daily: WorkspaceDaily, isDoneToday: Bool)? {
    guard let daily = try? store.daily(forTaskId: taskID), daily.isHabit, !daily.isArchived else { return nil }
    let today = (try? store.dailies(on: day))?.first { $0.daily.id == daily.id }
    return (daily, today?.isDoneToday ?? false)
  }

  /// Logs today's contribution to a habit, or clears it when today is
  /// already ticked. Not showing today, there is nothing to un-tick: doing it
  /// now simply counts for today.
  private func tickHabit(_ habit: (daily: WorkspaceDaily, isDoneToday: Bool), title: String) {
    let dailyID = habit.daily.id
    if habit.isDoneToday {
      if perform({ try $0.clearContribution(dailyId: dailyID) }) { announce("Unticked \(title) for today") }
    } else if perform({ _ = try $0.logContribution(dailyId: dailyID) }) {
      noteCompletion()
      announce("Ticked \(title) for today")
    }
  }

  /// Marks a task as no longer worth doing — closed, but not done — or
  /// reopens an invalidated one.
  func toggleInvalidated(_ taskID: String) {
    guard let task = task(taskID) else { return }
    let cancelling = task.status != .cancelled
    if perform({ try $0.setStatus(cancelling ? .cancelled : .open, for: taskID) }) {
      announce(cancelling ? "Cancelled \(task.title)" : "Reinstated \(task.title)")
    }
  }

  func delete(_ taskID: String) {
    let title = task(taskID)?.title
    if perform({ try $0.deleteTask(id: taskID) }) {
      announce(title.map { "Deleted \($0)" })
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
      announce("Moved to \(listName(for: listID))")
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
    if let list { announce("Extracted to \(list.name)") }
    return list
  }

  // MARK: - Creating

  /// Creates a task from typed text, reading capture tokens (`45m #work
  /// ^mon @fri !1`) off the end of the title.
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
  /// shortcut and the inspector write identically. A move of a repeating
  /// task onto its next turn asks first; `saved` follows the save, whether
  /// it is made now or from that question.
  func editValues(
    _ taskID: String, saved: (@MainActor () -> Void)? = nil, _ change: (inout TaskEditorValues) -> Void
  ) {
    guard var draft = performReturning({ TaskEditorDraft(snapshot: try $0.taskEditorSnapshot(for: taskID)) })
    else { return }
    change(&draft.values)
    let save: @MainActor () -> Bool = { [weak self, draft] in
      self?.perform { _ = try $0.saveTaskEditor(draft) } ?? false
    }
    if askAboutRecurrenceClash(draft, save: save, saved: saved) { return }
    if save() { saved?() }
  }

  func rename(_ taskID: String, to title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, task(taskID)?.title != trimmed else { return }
    editValues(taskID) { $0.title = trimmed }
  }

  func setDue(_ taskID: String, daysFromToday days: Int) {
    let start = Calendar.current.startOfDay(for: .now)
    let day = Calendar.current.date(byAdding: .day, value: days, to: start)
    editValues(taskID, saved: { [weak self] in
      self?.announce(days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : nil)
    }) { $0.dueAt = day; $0.dueDate = nil }
  }

  /// Starts the task at the beginning of tomorrow: the Mac's bury.
  func bury(_ taskID: String) {
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
    editValues(taskID, saved: { [weak self] in self?.announce("Buried until tomorrow") }) { $0.startAt = tomorrow }
  }

  /// Announced once the save lands: a repeating task that asks first and is
  /// then left alone has cleared nothing.
  func clearDue(_ taskID: String) {
    editValues(taskID, saved: { [weak self] in self?.announce("Cleared the due date") }) {
      $0.dueAt = nil; $0.dueDate = nil
    }
  }

  func clearStart(_ taskID: String) {
    editValues(taskID, saved: { [weak self] in self?.announce("Cleared the start") }) { $0.startAt = nil }
  }

  // MARK: - Planning

  func isPlannedToday(_ taskID: String) -> Bool {
    (try? store.kanbanColumn(for: taskID)) == NextUpSelector.todayColumnID
  }

  /// Puts the task on today, or takes it off.
  func togglePlannedToday(_ taskID: String) {
    let planned = isPlannedToday(taskID)
    if perform({ try $0.setPlannedForToday(!planned, taskIds: [taskID]) }) {
      announce(planned ? "Taken off today" : "Planned for today")
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
