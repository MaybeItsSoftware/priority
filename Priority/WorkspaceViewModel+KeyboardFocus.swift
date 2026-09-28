import Foundation
import PriorityCore
import PriorityWorkspace

/// Which region holds the keyboard, and what navigation keys move through.
/// Split from `WorkspaceViewModel.swift` for size — it is the same type.
extension WorkspaceViewModel {
  /// Collapsing while the sidebar holds the keyboard hands focus to the tasks,
  /// rather than leaving it on a pane that is no longer on screen.
  func toggleSidebar() {
    isSidebarVisible.toggle()
    if !isSidebarVisible, keyboardFocusArea == .sidebar {
      requestKeyboardFocus(.tasks)
    }
  }

  func requestTaskComposerFocus() {
    if !isQuickCaptureActive {
      quickCaptureDestinationID = nil
      quickCaptureStartDayOffset = nil
    }
    taskInsertionReference = nil
    // Not `requestKeyboardFocus(.tasks)`: the field is in the title bar now,
    // and asking SwiftUI to focus the task pane would race it for the key.
    desktopShortcutSequence.reset()
    taskComposerFocusRequest += 1
  }

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
    if area == .sidebar { taskInsertionReference = nil }
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
    var areas: [WorkspaceFocusArea] = isSidebarVisible ? [.sidebar, .tasks] : [.tasks]
    // The dock's tab is a stop when it has something to hold the keyboard:
    // the inspector needs a task, the rail does not.
    if isRightDockVisible, rightDockTab == .done || selectedTask != nil {
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
    case .outline: outline.map(\.task)
    case .board: boardColumns.flatMap { tasks(in: $0) }
    case .matrix: boardTasks
    }
  }
}
