import Foundation
import TaktCore
import TaktWorkspace

/// The right-hand rail: what you have actually finished.
///
/// The app was good at telling you what was left and said nothing about what
/// was done. A completed task dropped out of the outline and out of the board
/// and the only record of it was the timeline, which is a chart of *logged
/// blocks* — so anything you ticked off without running a timer left no trace at
/// all. That is the wrong answer to "am I getting anywhere": the evidence is the
/// list of things you closed, in the order you closed them.
///
/// It is a rail rather than a view mode because progress is read *beside* the
/// work, not instead of it — the comparison you want is today's board against
/// today's finished column, and a fifth mode would put them on separate screens.
@MainActor
extension WorkspaceViewModel {
  /// How far back the rail looks. Five weeks covers "this week against the last
  /// few" without turning the query into an archive browse.
  static let doneRailWindowDays = 35
  static let doneRailVisibleKey = "localWorkspaceDoneRailVisibleV1"

  /// The row the keyboard is on, defaulting to the newest thing finished so the
  /// rail is navigable the moment it opens. A lookup, not a scan: the rail
  /// asks once per render.
  var doneCursorTask: WorkspaceTask? {
    if let doneCursorID, let index = doneCursorIndex(of: doneCursorID) { return completedTasks[index] }
    return completedTasks.first
  }

  /// Where the task sits in `completedTasks`. Reads `completedTasks` so a view
  /// that asks is told when the rows change, as the scan this replaced was.
  private func doneCursorIndex(of id: String) -> Int? {
    guard let index = completedTaskIndex[id], completedTasks.indices.contains(index) else { return nil }
    return index
  }

  func leaveDoneRail() {
    guard keyboardFocusArea == .done else { return }
    requestKeyboardFocus(.tasks)
  }

  /// Only while the rail is on screen. Every mutation reloads the outline, and
  /// making each one pay for a query nobody is looking at is how a list view
  /// gets slow.
  func reloadCompleted() {
    guard isDoneRailVisible, let store else {
      if !isDoneRailVisible { completedTasks = [] }
      return
    }
    let since = Calendar.current.date(
      byAdding: .day, value: -Self.doneRailWindowDays, to: Date.now) ?? .distantPast
    do {
      // Only when it moved: every mutation reloads this, and an assignment
      // regroups the rail and redraws it whether or not anything changed.
      let fetched = try store.completedTasks(since: since)
      if completedTasks != fetched { completedTasks = fetched }
    } catch {
      errorMessage = error.localizedDescription
    }
    if let doneCursorID, doneCursorIndex(of: doneCursorID) == nil {
      self.doneCursorID = completedTasks.first?.id
    }
  }

  /// Steps the rail's cursor. Flattened across day groups on purpose: the days
  /// are headings over one sequence, not separate lists to be escaped from.
  func moveDoneCursor(by offset: Int) {
    guard !completedTasks.isEmpty else { return }
    let current = doneCursorID.flatMap { doneCursorIndex(of: $0) } ?? 0
    let next = CursorStepping.index(from: current, by: offset, count: completedTasks.count)
    doneCursorID = completedTasks[next].id
  }

  /// Goes to where the task lives rather than showing it in place. A finished
  /// task you want to look at properly is nearly always one you want in context
  /// — what it was part of, what is still open beside it.
  func revealDoneTask(_ task: WorkspaceTask) {
    doneCursorID = task.id
    revealTask(task)
  }

  /// A task from a dock tab — the done rail, the timeline — shown in its own
  /// list's outline, selected, with the keyboard on it.
  func revealTask(_ task: WorkspaceTask) {
    batchingRefreshes {
      if task.listId != selectedListID || isEverythingSelected { selectList(task.listId) }
      scopeTaskID = nil
      viewMode = .outline
      // Something ticked off is invisible in an outline that hides completions,
      // so revealing one has to stop hiding them or the reveal shows nothing.
      if task.status != .open { hidesCompletedTasks = false }
      reloadOutline(refreshSidebar: false)
    }
    unfoldAncestors(of: task)
    selectedTaskID = task.id
    requestKeyboardFocus(.tasks)
  }

  /// Puts a finished task back on the list, cancelled ones included — `r` means
  /// "this is open again" whichever way it was closed.
  func reopenDoneTask(_ task: WorkspaceTask) {
    guard let store else { return }
    let successor = completedTasks.first { $0.id != task.id }?.id
    perform {
      try store.setStatus(.open, for: task.id)
      reloadOutline(refreshSidebar: task.isList)
      reloadNextUp()
      reloadDailies()
      doneCursorID = successor
      reloadCompleted()
    }
  }
}
