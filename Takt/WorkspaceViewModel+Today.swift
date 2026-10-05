import Foundation
import TaktCore
import TaktWorkspace

/// Choosing the day and arranging it — Blitzit's core gesture, from the
/// keyboard.
///
/// "On today" is the Today board column (see `WorkspaceStore+Today`). A task
/// can be in the day for other reasons, a deadline or a start date, but those
/// rows follow their dates; only a planned row has a place you gave it, so
/// only planned rows can be moved.
@MainActor
extension WorkspaceViewModel {

  /// Plans the selected task for today, or takes it off.
  ///
  /// Asks the store rather than the day's rows whether the task is planned:
  /// the running block heads the day as "running" even when it is also in the
  /// column, and reading the reason would plan it a second time instead of
  /// taking it off.
  func togglePlannedTodayForSelection() {
    guard let store, let task = selectedTask else { return }
    let isPlanned = (try? store.kanbanColumn(for: task.id)) == NextUpSelector.todayColumnID
    var succeeded = false
    perform {
      try store.setPlannedForToday(!isPlanned, taskIds: [task.id])
      succeeded = true
      // The column is the board's as well as the day's.
      reloadBoard()
      reloadNextUp()
    }
    if succeeded { onStatusMessage?(isPlanned ? "Taken off today" : "Planned for today") }
  }

  /// Whether ⌥↑ and ⌥↓ arrange the day rather than move a task among its
  /// siblings. Only on Today with the task pane holding the keyboard; the
  /// sidebar keeps its own meaning for them, and a full-pane screen is not
  /// showing the day at all.
  var arrangesDayOnMove: Bool {
    viewMode == .today && keyboardFocusArea == .tasks && !showsFocusScreen
      && !showsTimelineScreen
  }

  /// Moves the selected task `offset` places through the planned part of the
  /// day, and writes the whole planned order, so the arrangement holds when a
  /// neighbour's score changes.
  ///
  /// The selection is by id, so it stays on the moved task without help.
  /// `todayPlan` is rewritten straight away rather than left to the ranking
  /// that lands a moment later — otherwise a second press made before it
  /// lands would move the task from where it used to be.
  func arrangeSelectedDayTask(by offset: Int) {
    guard let store, let task = selectedTask else { return }
    let planned = todayPlan.filter { $0.reason == .planned }.map(\.id)
    guard planned.contains(task.id) else {
      // The running block heads the day whether or not it was planned, so
      // "plan it first" would be advice that changes nothing.
      if todayPlan.first?.id == task.id, todayPlan.first?.reason == .running {
        onStatusMessage?("The running block stays at the top of the day")
        return
      }
      let key = WorkspaceCommandHelpText.firstKey(for: .taskTogglePlannedToday)
      onStatusMessage?("Only planned tasks can be arranged — plan it first with \(key)")
      return
    }
    guard let arranged = DayArrangement.moving(task.id, by: offset, in: planned) else { return }
    perform {
      try store.arrangeDay(orderedTaskIds: arranged)
      todayPlan = DayArrangement.applying(arranged, to: todayPlan)
      // `dayItems` is what the pane draws, and it is only rebuilt on request.
      rebuildDayItems()
      reloadNextUp()
    }
  }
}
