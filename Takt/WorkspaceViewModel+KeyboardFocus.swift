import Foundation
import TaktCore
import TaktWorkspace

/// Which region holds the keyboard, and what navigation keys move through.
/// Split from `WorkspaceViewModel.swift` for size — it is the same type.
extension WorkspaceViewModel {
  /// Collapsing while the sidebar holds the keyboard hands focus to the tasks,
  /// rather than leaving it on a pane that is no longer on screen.
  ///
  /// The left dock has an agent tab too; this is the Lists tab's toggle, so
  /// with the agent showing it turns the dock to the lists rather than
  /// putting it away.
  func toggleSidebar() {
    if isListsPaneVisible {
      hideLeftDock()
    } else {
      showLeftDock(.lists)
    }
  }

  func requestTaskComposerFocus() {
    if !isQuickCaptureActive {
      quickCaptureDestinationID = nil
      quickCaptureStartDayOffset = nil
    }
    taskInsertionReference = nil
    // Not `requestKeyboardFocus(.tasks)`: the draft row takes the key itself,
    // and asking SwiftUI to focus the task pane would race it for it.
    desktopShortcutSequence.reset()
    if isQuickCaptureActive {
      quickCaptureFocusRequest += 1
    } else {
      isDraftingTask = true
      taskComposerFocusRequest += 1
    }
  }

  /// Closes the draft row and gives the keyboard back to the tasks.
  func endTaskDraft() {
    guard isDraftingTask else { return }
    isDraftingTask = false
    taskInsertionReference = nil
    taskInsertionAbove = false
    taskInsertionIsChild = false
    requestKeyboardFocus(.tasks)
  }

  /// ↑ or ↓ in the draft row: drop what was being typed, as Esc does, and
  /// carry on navigating from where the row sat — up lands on the task just
  /// above it, down on the one just below.
  func leaveTaskDraft(by offset: Int) {
    guard isDraftingTask else { return }
    let reference = taskInsertionReference
    let above = taskInsertionAbove && !taskInsertionIsChild
    endTaskDraft()
    let rows = navigationRowIDs()
    guard !rows.isEmpty else { return }
    // With no reference the row is at the foot of the pane: nothing below it.
    guard let reference, let index = rows.firstIndex(of: reference.id) else {
      if offset < 0 { selectedTaskID = rows.last }
      return
    }
    // The row sits in the gap before `index` (above) or after it.
    let gapBefore = above ? index - 1 : index
    let destination = offset < 0 ? gapBefore : gapBefore + 1
    selectedTaskID = rows[min(max(destination, 0), rows.count - 1)]
  }

  /// Whether the draft row belongs right before (`above`) or after the row
  /// for `taskID`; with no reference it goes at the end of the pane.
  func draftsBeside(_ taskID: String, above: Bool) -> Bool {
    isDraftingTask && taskInsertionReference?.id == taskID && taskInsertionAbove == above
      && !(above && taskInsertionIsChild)
  }

  var draftsAtEnd: Bool { isDraftingTask && taskInsertionReference == nil }

  func requestRelativeTaskComposerFocus(above: Bool = false, child: Bool = false) {
    let reference = selectedTask
    requestTaskComposerFocus()
    taskInsertionReference = reference
    taskInsertionAbove = above
    taskInsertionIsChild = child
  }

  func requestKeyboardFocus(_ area: WorkspaceFocusArea) {
    desktopShortcutSequence.reset()
    if area == .tasks && selectedTaskID == nil && !(viewMode == .board && focusedBoardColumnID != nil) {
      selectedTaskID = visibleNavigationTasks.first?.id
    }
    if area == .sidebar {
      taskInsertionReference = nil
      // The sidebar is the left dock's Lists tab; with the agent showing
      // there is no sidebar on screen to take the keyboard.
      if leftDockTab != .lists { leftDockTab = .lists }
    }
    if let tab = WorkspaceDockTab(area: area) { showRightDock(tab) }
    requestedFocusArea = area
    keyboardFocusArea = area
    focusRequest += 1
  }

  func reportKeyboardFocus(_ area: WorkspaceFocusArea?) {
    if area != keyboardFocusArea { desktopShortcutSequence.reset() }
    keyboardNavigationSurfaceActive = area != nil
    if let area { keyboardFocusArea = area }
  }

  func cycleKeyboardFocus(by offset: Int) {
    var areas: [WorkspaceFocusArea] = isListsPaneVisible ? [.sidebar, .tasks] : [.tasks]
    // The dock's tab is a stop when it has something to hold the keyboard:
    // the inspector needs a task, the rail and the timeline do not.
    if isRightDockVisible, rightDockTab != .inspector || selectedTask != nil {
      areas.append(rightDockTab.area)
    }
    let current = areas.firstIndex(of: keyboardFocusArea) ?? 0
    let destination = (current + offset + areas.count) % areas.count
    requestKeyboardFocus(areas[destination])
  }

  var visibleNavigationTasks: [WorkspaceTask] {
    // Mid-`perform`, a scope change has only been marked. Whoever asks what is
    // on screen wants the answer after it, not before.
    if !pendingRefresh.isEmpty { flushPendingRefresh() }
    return switch viewMode {
    case .today: dayItems.map(\.task)
    case .outline: outlineRows.map(\.task)
    case .board: boardColumns.flatMap { tasks(in: $0) }
    case .matrix: boardTasks
    }
  }
}

@MainActor
extension WorkspaceViewModel {
  /// Tab in a draft row: the task being typed goes inside the one it was
  /// to follow. Only in the outline, where depth is something you can see.
  func indentTaskDraft() {
    guard viewMode == .outline, !taskInsertionAbove else { return }
    // A draft at the foot of the list follows the last row on screen, so Tab
    // there puts it inside that one.
    if taskInsertionReference == nil {
      guard let last = outlineRows.last?.task else { return }
      taskInsertionReference = last
    }
    taskInsertionIsChild = true
  }

  /// ⇧Tab: back out a level — from inside the task above to beside it, and
  /// from beside it to after its parent.
  func outdentTaskDraft() {
    guard viewMode == .outline, let reference = taskInsertionReference else { return }
    if taskInsertionIsChild {
      taskInsertionIsChild = false
    } else if let parentID = reference.parentTaskId, parentID != scopeTaskID,
      let parent = task(withID: parentID), outlineRows.contains(where: { $0.id == parentID }) {
      taskInsertionReference = parent
      taskInsertionAbove = false
    }
  }
}
