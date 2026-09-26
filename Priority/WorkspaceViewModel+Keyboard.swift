import AppKit
import Foundation
import PriorityWorkspace
import PriorityCore

/// The desktop window's key handling. Split from `WorkspaceViewModel.swift`
/// both for size and because one 270-line method was impossible to read: the
/// dispatch below names each region of the keyboard it is deciding about.
@MainActor
extension WorkspaceViewModel {
  /// Handles keys that belong to the desktop workspace only. Text editing is
  /// filtered by `MainWindowController` before this method is reached.
  @discardableResult
  func handleDesktopKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    // Focus mode owns the keyboard outright while it is up. It replaced the
    // workspace on screen, so leaving the workspace's own keys live would mean
    // ⌘4 quietly switching a board nobody can see.
    if showsFocusScreen, handleRunningFocusKey(event, flags: flags) { return true }
    if showsFocusScreen, handleFocusLadderKey(event, flags: flags) { return true }
    if showsTimelineScreen, handleTimelineKey(event, flags: flags) { return true }
    if handleViewSwitchKey(event, flags: flags) { return true }
    if handleModifiedKey(event, flags: flags) { desktopShortcutSequence.reset(); return true }
    guard flags.isEmpty || flags == [.shift] else { desktopShortcutSequence.reset(); return false }
    if flags.isEmpty && keyboardFocusArea != .inspector && !showsFocusScreen {
      switch desktopShortcutSequence.advance(event.charactersIgnoringModifiers ?? "", at: event.timestamp) {
      case .pending: return true
      case .command(let command): return handleCheckvistCommand(command)
      case .pass: break
      }
    } else { desktopShortcutSequence.reset() }
    if keyboardFocusArea == .sidebar { return handleSidebarKey(event) }
    return handleTaskSurfaceKey(event)
  }

  /// A completed two-key sequence, resolved through the catalogue rather than
  /// through a `switch` of its own.
  ///
  /// This used to be twenty hand-written cases sitting a few hundred lines
  /// from the reference sheet that described them, which is how `sd` came to
  /// be documented and `dr` not. Now the sequence *is* the catalogue entry's
  /// key, so a row that prints a shortcut is a row that runs it.
  private func handleCheckvistCommand(_ command: String) -> Bool {
    guard let match = WorkspaceCommandCatalog.command(forKey: command, on: commandSurface)
    else { return false }
    run(match.id)
    return true
  }

  func quickEdit(_ kind: WorkspaceTaskQuickEditKind) {
    guard let task = selectedTask else { return }
    taskQuickEditRequest = WorkspaceTaskQuickEditRequest(task: task, kind: kind)
  }

  func editSelectedTaskTitle() {
    if keyboardFocusArea == .sidebar { beginRenamingSelection() }
    else { quickEdit(.title) }
  }

  func editTaskValues(_ change: (inout TaskEditorValues) -> Void) {
    guard let task = selectedTask, let store else { return }
    perform {
      var draft = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: task.id))
      change(&draft.values)
      _ = try store.saveTaskEditor(draft)
      reloadOutline()
      reloadDailies()
      reloadNextUp()
    }
  }

  func invalidateTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setStatus(task.status == .cancelled ? .open : .cancelled, for: task.id)
      reloadOutline()
      reloadNextUp()
    }
  }

  func selectTaskAtEnd(first: Bool) {
    let candidates = viewMode == .board
      ? boardColumns.first(where: { $0.id == activeBoardColumnID }).map { tasks(in: $0) } ?? []
      : visibleNavigationTasks
    selectedTaskID = first ? candidates.first?.id : candidates.last?.id
  }

  /// The timeline's own keys. Like focus mode it owns the keyboard while it is
  /// up, so the workspace's single-letter shortcuts cannot edit a board that is
  /// no longer on screen.
  private func handleTimelineKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    guard flags.isEmpty else { return false }
    switch event.keyCode {
    case 53: run(.timelineClose); return true
    // Left goes back in time, which is also up the list: earlier is further
    // from now, and the arrow points the way the day moves.
    case 123: run(.timelinePreviousDay); return true
    case 124: run(.timelineNextDay); return true
    default: break
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "h": run(.timelinePreviousDay); return true
    case "l": run(.timelineNextDay); return true
    case "t": run(.timelineToday); return true
    default: return true
    }
  }

  /// Climbing the focus ladder. Up is *less* important — the direction matches
  /// the screen, where the most important thing sits at the foot.
  /// The running session's own keys. Checked before the ladder's, because
  /// while a block is running the pane is showing the block — the ladder is
  /// not on screen to be driven.
  private func handleRunningFocusKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    guard activeFocusSession != nil, activeFocusTask != nil, pendingFocusCompletion == nil else { return false }
    guard flags.isEmpty else { return false }
    switch event.keyCode {
    case 36, 76:  // Return, Enter — finish the block, which is what Done does.
      run(.focusFinish)
      return true
    case 53:  // Escape leaves the pane; the block keeps running behind it.
      run(.focusLeave)
      return true
    default:
      break
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "p": run(.focusPause); return true
    case "l": run(.focusLogAndKeep); return true
    case "f": run(.focusFloat); return true
    default: return false
    }
  }

  private func handleFocusLadderKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    // Option-arrow moves the task itself rather than the cursor, which is the
    // same gesture that reorders a task everywhere else in the workspace.
    // Same sign as the cursor keys below, so the task travels the way the arrow
    // points: up the screen is up the ladder, which is *less* important.
    if flags == [.option] {
      switch event.keyCode {
      case 126: reorderFocusLadder(by: 1); return true
      case 125: reorderFocusLadder(by: -1); return true
      default: return false
      }
    }
    guard flags.isEmpty || flags == [.shift] else { return false }
    switch event.keyCode {
    case 53:  // Escape
      if stagedTaskID != nil { unstageFocusTask() } else { dismissFocusScreen() }
      return true
    case 126:  // Up
      run(.focusLadderUp)
      return true
    case 125:  // Down
      run(.focusLadderDown)
      return true
    case 36, 76:  // Return, Enter
      run(stagedTaskID == nil ? .focusStage : .focusBegin)
      return true
    default:
      break
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "k": run(.focusLadderUp); return true
    case "j": run(.focusLadderDown); return true
    // Not completed here: the celebration is allowed to cancel, and only the
    // view can play it. Same path as the button, so both animate.
    case "x": run(.focusTickOff); return true
    case "l": run(.focusDefer); return true
    // Space stages rather than ticking off: on a screen whose whole purpose is
    // starting work, the big key should start work.
    case " ": run(stagedTaskID == nil ? .focusStage : .focusBegin); return true
    default: return false
    }
  }

  /// Command-digit: the places you can be, in the order they are worth being
  /// in — Today, Board, Outline, Matrix — plus the focus screen on ⌘8 and the
  /// timeline on ⌘9.
  ///
  /// The digits used to address the window's three regions instead, which spent
  /// the most reachable keys on moving the caret between panes. Region focus is
  /// a smaller thing than changing what you are looking at, so it moved to
  /// ⌃1–⌃3 and the modes took the row.
  private func handleViewSwitchKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.control] {
      switch event.charactersIgnoringModifiers {
      case "1": run(.goSidebarRegion); return true
      case "2": run(.goTaskRegion); return true
      case "3": run(.goInspectorRegion); return true
      default: break
      }
    }

    if flags == [.command] {
      switch event.charactersIgnoringModifiers {
      case "0": run(.goEverything); return true
      // Leaving whichever full-pane surface is up is part of asking for a
      // mode — see `run(_:)`. ⌘1 on the timeline means "show me today", not
      // "remember that I wanted today once the timeline is dismissed".
      case "1": run(.goToday); return true
      case "2": run(.goBoard); return true
      case "3": run(.goOutline); return true
      case "4": run(.goMatrix); return true
      case "8":
        // One key for the one surface. What it shows — a running session or
        // the ladder that picks one — is the screen's business, not the key's.
        run(.goFocus)
        return true
      case "9":
        // A toggle rather than a second way in: the timeline answers a question
        // in a glance, and pressing the same key to put it away again is what
        // makes it cheap enough to glance at.
        run(.goTimeline)
        return true
      default: break
      }
    }
    return false
  }

  /// Focus cycling and the creation chords: new task, list, folder.
  private func handleModifiedKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.control] || flags == [.control, .shift], event.keyCode == 48 {
      cycleKeyboardFocus(by: flags == [.control, .shift] ? -1 : 1)
      return true
    }

    if (flags == [.control] || flags == [.control, .shift]), event.charactersIgnoringModifiers?.lowercased() == "z" {
      run(flags.contains(.shift) ? .windowRedo : .windowUndo)
      return true
    }
    if keyboardFocusArea == .tasks {
      if event.keyCode == 48 && (flags.isEmpty || flags == [.shift]) {
        run(flags.contains(.shift) ? .taskOutdent : .taskIndent)
        return true
      }
      if (event.keyCode == 36 || event.keyCode == 76) && (flags == [.option] || flags == [.shift]) {
        requestRelativeTaskComposerFocus(above: flags == [.option], child: flags == [.shift])
        return true
      }
      if flags == [.shift] {
        switch event.keyCode {
        case 124: run(.planEnterTask); return true
        case 123: run(.planLeaveTask); return true
        case 49: run(.taskInvalidate); return true
        default: break
        }
      }
    }
    if flags == [.command] {
      if event.charactersIgnoringModifiers?.lowercased() == "n" {
        run(.taskNew)
        return true
      }
      if event.charactersIgnoringModifiers?.lowercased() == "k" {
        run(.goCommandPalette)
        return true
      }
    }
    if flags == [.command, .shift] {
      if event.charactersIgnoringModifiers?.lowercased() == "n" {
        run(.listNew)
        return true
      }
    }
    if flags == [.command, .option] {
      if event.charactersIgnoringModifiers?.lowercased() == "n" {
        run(.folderNew)
        return true
      }
      if isEverythingSelected {
        switch event.charactersIgnoringModifiers {
        case "[": cycleNewTaskDestination(by: -1); return true
        case "]": cycleNewTaskDestination(by: 1); return true
        default: break
        }
      }
      if selectedFolder != nil {
        switch event.keyCode {
        case 125: run(.folderMoveDown); return true
        case 126: run(.folderMoveUp); return true
        default: break
        }
      }
    }
    return handleListChordKey(event, flags: flags)
  }

  /// Chords that act on the selected list, the board, or the window itself.
  private func handleListChordKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.command] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "i": run(.listSettings); return true
      case "/": run(.goKeyboardReference); return true
      case "f": run(.goSearch); return true
      case "r": run(.listRename); return true
      case "z": run(.windowUndo); return true
      default:
        break
      }
    }
    if flags == [.command, .shift] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "l": run(.taskConvertToList); return true
      case "p": run(.taskPromoteList); return true
      case "x": run(.listComplete); return true
      case "a": run(.listArchive); return true
      case "c":
        if viewMode == .board { run(.planBoardNewColumn); return true }
        return false
      case "d":
        if selectedTask != nil { run(.taskToggleDaily); return true }
        return false
      case "r": run(.listRestore); return true
      case "z": run(.windowRedo); return true
      default:
        break
      }
    }
    return handleOrderingKey(event, flags: flags)
  }

  /// Reordering, deletion, the matrix quadrants and the help sheet.
  private func handleOrderingKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.command, .shift] && (event.keyCode == 51 || event.keyCode == 117) {
      run(.listDelete)
      return true
    }
    if flags == [.control, .option] {
      switch event.keyCode {
      case 125: run(.folderSelectNext); return true
      case 126: run(.folderSelectPrevious); return true
      default: break
      }
    }
    if flags == [.shift], event.characters == "?" {
      run(.goKeyboardReference)
      return true
    }
    if flags == [.command] || flags == [.control] {
      switch event.keyCode {
      // One command either way: what moves is whatever the caret is standing
      // on, which `run(_:)` resolves rather than each key restating it.
      case 125: run(.taskMoveDown); return true
      case 126: run(.taskMoveUp); return true
      default: break
      }
    }
    if flags == [.command, .option], keyboardFocusArea == .tasks {
      switch event.keyCode {
      case 123: run(.taskOutdent); return true
      case 124: run(.taskIndent); return true
      default: break
      }
    }
    return handlePlacementKey(event, flags: flags)
  }

  /// Where a task sits: which board column, which matrix quadrant — and the two
  /// unmodified keys that open the inspector and the move sheet.
  private func handlePlacementKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.option], keyboardFocusArea == .tasks {
      if event.charactersIgnoringModifiers?.lowercased() == "t" { run(.taskEditEstimate); return true }
      if event.charactersIgnoringModifiers?.lowercased() == "s" { run(.taskEditStart); return true }
      if viewMode == .board, keyboardNavigationSurfaceActive {
        switch event.keyCode {
        case 123: run(.planBoardMoveCardLeft); return true
        case 124: run(.planBoardMoveCardRight); return true
        default: break
        }
      }
      if viewMode == .matrix, let task = selectedTask {
        switch event.charactersIgnoringModifiers {
        case "1": setMatrixPosition(.init(urgency: 1, importance: 1), for: task); return true
        case "2": setMatrixPosition(.init(urgency: 0, importance: 1), for: task); return true
        case "3": setMatrixPosition(.init(urgency: 1, importance: 0), for: task); return true
        case "4": setMatrixPosition(.init(urgency: 0, importance: 0), for: task); return true
        default: break
        }
      }
    }
    guard flags.isEmpty else { return false }
    if keyboardFocusArea == .tasks, let digit = Int(event.charactersIgnoringModifiers ?? ""), (0...9).contains(digit) {
      editTaskValues { $0.priority = digit }
      return true
    }
    if event.charactersIgnoringModifiers?.lowercased() == "i" {
      run(.taskToggleInspector)
      return true
    }
    return false
  }

  private func handleSidebarKey(_ event: NSEvent) -> Bool {
    if keyboardFocusArea == .sidebar {
      switch event.keyCode {
      case 125:  // Down
        moveSidebarSelection(by: 1)
      case 126:  // Up
        moveSidebarSelection(by: -1)
      case 36, 76:  // Return / keypad Enter
        activateSidebarCursor(expandOnly: false)
      case 124:  // Right
        activateSidebarCursor(expandOnly: true)
      case 123:  // Left
        // Focus and the timeline are not in anything, so there is nothing for
        // left to leave. Doing nothing beats selecting Everything, which would
        // change the pane behind a key that was asked to go outwards.
        if sidebarCursorRow?.selectsAList == false {
          break
        } else if let folder = selectedFolder, expandedFolderIDs.contains(folder.id) {
          setFolderExpanded(folder, expanded: false)
        } else if let scope = scopeTask, scope.isList {
          leaveTaskScope()
        } else if let parentID = selectedFolder?.parentFolderId,
          let parent = folders.first(where: { $0.id == parentID }) {
          selectFolder(parent)
        } else if let parentID = selectedList?.folderId,
          let parent = folders.first(where: { $0.id == parentID }) {
          selectFolder(parent)
        } else if !isEverythingSelected {
          selectEverything()
        }
      case 120: run(.listRename)
      case 115: moveSidebarSelectionToEnd(first: true)
      case 119: moveSidebarSelectionToEnd(first: false)
      case 116: moveSidebarSelection(by: -8)
      case 121: moveSidebarSelection(by: 8)
      case 53:  // Escape
        selectedFolderID = nil
      default:
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": moveSidebarSelection(by: 1)
        case "k": moveSidebarSelection(by: -1)
        case "/": run(.goSearch)
        case "?": run(.goKeyboardReference)
        default: return false
        }
      }
      return true
    }

    // Once an inspector control has focus, AppKit/SwiftUI owns Return, Space,
    // arrows, and Tab. Do not turn those into task commands.
    return false
  }

  /// The task list, the board, and the inspector's escape hatch.
  private func handleTaskSurfaceKey(_ event: NSEvent) -> Bool {
    // Today is not an outline. It keeps its own selection in its own view, and
    // the outline selection these keys move is not on screen there — so
    // arrowing around the day did nothing visible at all whenever its field
    // had lost the caret. Hand the caret back rather than move something
    // nobody can see; the pane takes the key itself from then on.
    if viewMode == .today, keyboardFocusArea != .inspector {
      switch event.keyCode {
      // Left is out of the pane entirely, which is the one key here the day
      // itself has no answer for. The rest belong to the day, so the caret
      // goes back and the pane takes them from then on.
      case 123:
        returnToCurrentListInSidebar()
        return true
      case 36, 49, 76, 124, 125, 126:
        dayFieldFocusRequest += 1
        return true
      default:
        break
      }
    }
    if keyboardFocusArea == .inspector {
      if event.keyCode == 53 {
        isInspectorVisible = false
        requestKeyboardFocus(.tasks)
        return true
      }
      return false
    }

    switch event.keyCode {
    case 125:  // ↓
      moveTaskSelection(by: 1)
    case 126:  // ↑
      moveTaskSelection(by: -1)
    case 124:  // →
      if viewMode == .board { focusAdjacentBoardColumn(by: 1) } else { run(.planEnterTask) }
    case 123:  // ←
      if viewMode == .board { focusAdjacentBoardColumn(by: -1) } else { run(.planLeaveTask) }
    case 120:  // F2
      run(.taskRename)
    case 115: selectTaskAtEnd(first: true)
    case 119: selectTaskAtEnd(first: false)
    case 116: moveTaskSelection(by: -8)
    case 121: moveTaskSelection(by: 8)
    case 36, 76:  // Return / keypad Enter
      if viewMode == .board && selectedTask == nil { run(.taskNew) }
      else if viewMode == .board { run(.planEnterTask) }
      else { requestRelativeTaskComposerFocus() }
    case 49:  // Space
      run(.taskComplete)
    case 51, 117:  // Delete / forward delete
      run(.taskDelete)
    case 53:  // Escape
      dismissKeyboardContext()
    default:
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "j": moveTaskSelection(by: 1)
      case "k": moveTaskSelection(by: -1)
      case "l": run(.planEnterTask)
      case "h": run(.planLeaveTask)
      case "x", " ": run(.taskComplete)
      case "f": run(.taskStartFocus)
      case "[":
        if scopeTaskID != nil { run(.planLeaveTask) }
        requestKeyboardFocus(.tasks)
      case "]":
        run(.planEnterTask)
        requestKeyboardFocus(.tasks)
      case "/": run(.goSearch)
      case "?": run(.goKeyboardReference)
      default: return false
      }
    }
    return true
  }
}
