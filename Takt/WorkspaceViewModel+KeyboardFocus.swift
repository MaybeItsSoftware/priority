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
  /// ⌘B, three states like the right dock's: hidden opens it with the
  /// keyboard on the list you are in, open-but-elsewhere brings the keyboard
  /// over, and open with the keyboard in it puts it away.
  func toggleSidebar() {
    if isListsPaneVisible && keyboardFocusArea == .sidebar {
      hideLeftDock()
    } else {
      showLeftDock(.lists)
      returnToCurrentListInSidebar()
    }
  }

  func requestTaskComposerFocus() {
    if !isQuickCaptureActive { quickCaptureDestinationID = nil }
    taskInsertionReference = nil
    // Not `requestKeyboardFocus(.tasks)`: the draft row takes the key itself,
    // and asking SwiftUI to focus the task pane would race it for it.
    desktopShortcutSequence.reset()
    if isQuickCaptureActive {
      quickCaptureFocusRequest += 1
    } else {
      // A card typed at the foot of the board goes to the column it was
      // started in, wherever the selection moves while it is typed.
      taskDraftColumnID = viewMode == .board ? activeBoardColumnID : nil
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

  func requestRelativeTaskComposerFocus(
    above: Bool = false, child: Bool = false, reference: WorkspaceTask? = nil
  ) {
    // Today draws its draft at the foot of the day, or beside a subtask
    // drawn under an unfolded task — a new task there is another of its
    // parent's subtasks, as Return in Checkvist adds a sibling.
    let reference = viewMode == .today
      ? selectedTask.flatMap { !child && dayTreeParentID(of: $0.id) != nil ? $0 : nil }
      : reference ?? selectedTask
    requestTaskComposerFocus()
    taskInsertionReference = reference
    taskInsertionAbove = above
    taskInsertionIsChild = child
  }

  func requestKeyboardFocus(_ area: WorkspaceFocusArea, onTitle: Bool = true) {
    desktopShortcutSequence.reset()
    inspectorFocusesTitle = onTitle
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
    if let tab = WorkspaceBottomDockTab(area: area) { showBottomDock(tab) }
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
    // Left to right, and the bottom dock before the right one since it sits
    // under the tasks. A dock's tab is a stop when it has something to hold
    // the keyboard: the inspector needs a task, the graph has nothing, and
    // the rest always do.
    if isBottomDockVisible, let area = bottomDockTab.area {
      areas.append(area)
    }
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
    case .today: dayTree.map(\.task)
    case .outline: outlineRows.map(\.task)
    case .board: boardColumns.flatMap { tasks(in: $0) }
    // As it is drawn: the unplaced column, then the quadrants in reading order.
    case .matrix: matrixQuadrants.drawnOrder
    }
  }
}

@MainActor
extension WorkspaceViewModel {
  /// Tab in a draft row: the task being typed goes inside the one above it.
  /// In the outline that is the row it was to follow; on the board, the card
  /// above it in its column, where it lands as a row on that card.
  func indentTaskDraft() {
    if viewMode == .board {
      indentBoardTaskDraft()
      return
    }
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
    if viewMode == .board {
      // A card has no level to back out to, only the card it went inside.
      taskInsertionIsChild = false
      return
    }
    guard viewMode == .outline, let reference = taskInsertionReference else { return }
    if taskInsertionIsChild {
      taskInsertionIsChild = false
    } else if let parentID = reference.parentTaskId, parentID != scopeTaskID,
      let parent = task(withID: parentID), outlineRows.contains(where: { $0.id == parentID }) {
      taskInsertionReference = parent
      taskInsertionAbove = false
    }
  }

  /// The board's Tab: the card above the draft in its column — the one it
  /// follows, the one before the card it precedes, or the column's last at
  /// the foot — becomes the new task's parent. Nothing above, nothing to go
  /// inside.
  private func indentBoardTaskDraft() {
    guard !taskInsertionIsChild else { return }
    let parent: WorkspaceTask?
    if let reference = taskInsertionReference {
      if taskInsertionAbove {
        let cards = column(for: reference).map { tasks(in: $0) } ?? []
        parent = cards.firstIndex(where: { $0.id == reference.id }).flatMap { $0 > 0 ? cards[$0 - 1] : nil }
      } else {
        parent = reference
      }
    } else {
      parent = boardColumns.first { $0.id == taskDraftBoardColumnID }.flatMap { tasks(in: $0).last }
    }
    guard let parent, !parent.isList else { return }
    taskInsertionReference = parent
    taskInsertionAbove = false
    taskInsertionIsChild = true
  }

  /// Sends a key to the inspector's cursor: a motion in normal mode, or a
  /// key that ends an edit. The inspector walks its own stops
  /// (`inspectorStop`) and decides what the key does on the one it is on.
  func sendInspectorKey(_ action: InspectorKeyAction) {
    inspectorKeyRequest = InspectorKeyRequest(action: action, serial: inspectorKeyRequest.serial + 1)
  }
}

/// What a key asks of the inspector's cursor.
enum InspectorKeyAction: Equatable {
  case step(Int)
  case first, last
  /// Return, `i`, `e`: edit or press the row.
  case edit
  /// `x`, Delete.
  case clear
  /// `h`, `←`.
  case leave(byArrow: Bool)
  /// A key typed inside one of its fields.
  case editing(InspectorEditingKey)
}

struct InspectorKeyRequest: Equatable {
  let action: InspectorKeyAction
  let serial: Int
}
