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

  private func handleCheckvistCommand(_ command: String) -> Bool {
    switch command {
    case "uu": undoLastChange()
    case "ll": showsListNavigator = true
    case "gh": selectEverything(); requestKeyboardFocus(.sidebar)
    case "mm": requestMoveSelectedTask()
    case "ee": editSelectedTaskTitle()
    case "dd": quickEdit(.due)
    case "nn": quickEdit(.notes)
    case "tt": quickEdit(.tags)
    case "dr": quickEdit(.recurrence)
    case "td": editTaskValues { $0.dueAt = Calendar.current.startOfDay(for: .now); $0.dueDate = nil }
    case "tm": editTaskValues { $0.dueAt = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)); $0.dueDate = nil }
    case "cd": editTaskValues { $0.dueAt = nil; $0.dueDate = nil }
    case "cn": editTaskValues { $0.notes = "" }
    case "ct": editTaskValues { $0.tags = "" }
    case "hc":
      hidesCompletedTasks.toggle()
      reloadOutline()
      if let selectedTaskID, !visibleNavigationTasks.contains(where: { $0.id == selectedTaskID }) {
        self.selectedTaskID = nil
      }
    case "sd": toggleInspector()
    case "oo": showSelectedListSettings()
    case "pc":
      if selectedTask != nil { requestKeyboardFocus(.inspector) }
    case "xx":
      if let task = selectedTask { moveDroppedItem(task.id, toFolderID: nil) }
    case "gg":
      if let task = selectedTask, let store,
        let snapshot = try? store.taskEditorSnapshot(for: task.id),
        let link = snapshot.metadata.externalLinks.first, let url = URL(string: link),
        ["https", "http", "obsidian"].contains(url.scheme?.lowercased() ?? "") {
        NSWorkspace.shared.open(url)
      }
    default: return false
    }
    return true
  }

  private func quickEdit(_ kind: WorkspaceTaskQuickEditKind) {
    guard let task = selectedTask else { return }
    taskQuickEditRequest = WorkspaceTaskQuickEditRequest(task: task, kind: kind)
  }

  private func editSelectedTaskTitle() {
    if keyboardFocusArea == .sidebar { beginRenamingSelection() }
    else { quickEdit(.title) }
  }

  private func editTaskValues(_ change: (inout TaskEditorValues) -> Void) {
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

  private func invalidateTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setStatus(task.status == .cancelled ? .open : .cancelled, for: task.id)
      reloadOutline()
      reloadNextUp()
    }
  }

  private func selectTaskAtEnd(first: Bool) {
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
    case 53: dismissTimelineScreen(); return true
    // Left goes back in time, which is also up the list: earlier is further
    // from now, and the arrow points the way the day moves.
    case 123: moveTimelineDay(by: -1); return true
    case 124: moveTimelineDay(by: 1); return true
    default: break
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "h": moveTimelineDay(by: -1); return true
    case "l": moveTimelineDay(by: 1); return true
    case "t": showTimelineToday(); return true
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
      requestFocusCompletion()
      return true
    case 53:  // Escape leaves the pane; the block keeps running behind it.
      dismissFocusScreen()
      return true
    default:
      break
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "p": toggleFocusPause(); return true
    case "l": requestFocusCompletion(completeTask: false); return true
    case "f": requestFocusFloat(); return true
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
      moveFocusLadder(by: 1)
      return true
    case 125:  // Down
      moveFocusLadder(by: -1)
      return true
    case 36, 76:  // Return, Enter
      if stagedTaskID == nil { stageFocusLadderSelection() } else { beginStagedFocus() }
      return true
    default:
      break
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "k": moveFocusLadder(by: 1); return true
    case "j": moveFocusLadder(by: -1); return true
    // Not completed here: the celebration is allowed to cancel, and only the
    // view can play it. Same path as the button, so both animate.
    case "x": focusCompletionRequest += 1; return true
    case "l": deferFocusLadderSelection(); return true
    // Space stages rather than ticking off: on a screen whose whole purpose is
    // starting work, the big key should start work.
    case " ": if stagedTaskID == nil { stageFocusLadderSelection() } else { beginStagedFocus() }; return true
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
      case "1": requestKeyboardFocus(.sidebar); return true
      case "2": requestKeyboardFocus(.tasks); return true
      case "3":
        if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
        requestKeyboardFocus(selectedTask == nil ? .tasks : .inspector)
        return true
      default: break
      }
    }

    if flags == [.command] {
      switch event.charactersIgnoringModifiers {
      case "0": selectEverything(); requestKeyboardFocus(.tasks); return true
      case "1", "2", "3", "4":
        guard let character = event.charactersIgnoringModifiers?.first,
          let mode = WorkspaceViewMode.planningModes.first(where: { $0.shortcutDigit == character })
        else { return false }
        // Leaving whichever full-pane surface is up is part of asking for a
        // mode: ⌘1 on the timeline means "show me today", not "remember that I
        // wanted today once the timeline is dismissed".
        dismissFocusScreen()
        dismissTimelineScreen()
        selectViewMode(mode)
        requestKeyboardFocus(.tasks)
        return true
      case "8":
        // One key for the one surface. What it shows — a running session or
        // the ladder that picks one — is the screen's business, not the key's.
        presentFocusScreen()
        return true
      case "9":
        // A toggle rather than a second way in: the timeline answers a question
        // in a glance, and pressing the same key to put it away again is what
        // makes it cheap enough to glance at.
        if showsTimelineScreen { dismissTimelineScreen() } else { presentTimelineScreen() }
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
      if flags.contains(.shift) { redoLastUndoneChange() } else { undoLastChange() }
      return true
    }
    if keyboardFocusArea == .tasks {
      if event.keyCode == 48 && (flags.isEmpty || flags == [.shift]) {
        if let task = selectedTask {
          if flags.contains(.shift) { outdentTask(task) } else { indentTask(task) }
        }
        return true
      }
      if (event.keyCode == 36 || event.keyCode == 76) && (flags == [.option] || flags == [.shift]) {
        requestRelativeTaskComposerFocus(above: flags == [.option], child: flags == [.shift])
        return true
      }
      if flags == [.shift] {
        switch event.keyCode {
        case 124: enterSelectedTask(); return true
        case 123: leaveSelectedTaskScope(); return true
        case 49:
          if let task = selectedTask { invalidateTask(task) }
          return true
        default: break
        }
      }
    }
    if flags == [.command] {
      if event.charactersIgnoringModifiers?.lowercased() == "n" {
        requestTaskComposerFocus()
        return true
      }
    }
    if flags == [.command, .shift] {
      if event.charactersIgnoringModifiers?.lowercased() == "n" {
        requestListCreationForSelection()
        return true
      }
    }
    if flags == [.command, .option] {
      if event.charactersIgnoringModifiers?.lowercased() == "n" {
        requestFolderCreationForSelection()
        return true
      }
      if isEverythingSelected {
        switch event.charactersIgnoringModifiers {
        case "[": cycleNewTaskDestination(by: -1); return true
        case "]": cycleNewTaskDestination(by: 1); return true
        default: break
        }
      }
      if let folder = selectedFolder {
        switch event.keyCode {
        case 125:
          moveFolderWithinSiblings(folder, by: 1)
          return true
        case 126:
          moveFolderWithinSiblings(folder, by: -1)
          return true
        default:
          break
        }
      }
    }
    return handleListChordKey(event, flags: flags)
  }

  /// Chords that act on the selected list, the board, or the window itself.
  private func handleListChordKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.command] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "i":
        showSelectedListSettings()
        return true
      case "/":
        showsKeyboardHelp = true
        return true
      case "f":
        presentSearch()
        return true
      case "r":
        beginRenamingSelection()
        return true
      case "z":
        undoLastChange()
        return true
      default:
        break
      }
    }
    if flags == [.command, .shift] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "l":
        if let task = keyboardFocusArea == .sidebar ? scopeTask : selectedTask ?? scopeTask { convertItem(task) }
        else if let list = selectedList, !list.isSystemList { convertListToTask(list) }
        return true
      case "p":
        if let task = keyboardFocusArea == .sidebar ? scopeTask : selectedTask ?? scopeTask { toggleListPromotion(task) }
        return true
      case "x":
        toggleCurrentListCompletion()
        return true
      case "a":
        archiveSelectedList()
        return true
      case "c":
        if viewMode == .board { newKanbanColumnRequest = true; return true }
        return false
      case "d":
        if let task = selectedTask { setDailyProgressTask(task, enabled: !isDailyProgressTask(task)); return true }
        return false
      case "r":
        restoreMostRecentlyArchivedList()
        return true
      case "z":
        redoLastUndoneChange()
        return true
      default:
        break
      }
    }
    return handleOrderingKey(event, flags: flags)
  }

  /// Reordering, deletion, the matrix quadrants and the help sheet.
  private func handleOrderingKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.command, .shift] && (event.keyCode == 51 || event.keyCode == 117) {
      requestDeletionOfSelectedSidebarItem()
      return true
    }
    if flags == [.control, .option] {
      switch event.keyCode {
      case 125:
        moveFolderSelection(by: 1)
        return true
      case 126:
        moveFolderSelection(by: -1)
        return true
      default:
        break
      }
    }
    if flags == [.shift], event.characters == "?" {
      showsKeyboardHelp = true
      return true
    }
    if flags == [.command] || flags == [.control] {
      switch event.keyCode {
      case 125:  // Cmd+Down
        if keyboardFocusArea == .sidebar, let folder = selectedFolder {
          moveFolderWithinSiblings(folder, by: 1)
        } else if keyboardFocusArea == .sidebar, let list = selectedList {
          moveListWithinFolder(list, by: 1)
        } else if let task = selectedTask {
          moveTaskWithinSiblings(task, by: 1)
        }
        return true
      case 126:  // Cmd+Up
        if keyboardFocusArea == .sidebar, let folder = selectedFolder {
          moveFolderWithinSiblings(folder, by: -1)
        } else if keyboardFocusArea == .sidebar, let list = selectedList {
          moveListWithinFolder(list, by: -1)
        } else if let task = selectedTask {
          moveTaskWithinSiblings(task, by: -1)
        }
        return true
      default: break
      }
    }
    if flags == [.command, .option], keyboardFocusArea == .tasks {
      switch event.keyCode {
      case 123:
        if let task = selectedTask { outdentTask(task) }
        return true
      case 124:
        if let task = selectedTask { indentTask(task) }
        return true
      default: break
      }
    }
    return handlePlacementKey(event, flags: flags)
  }

  /// Where a task sits: which board column, which matrix quadrant — and the two
  /// unmodified keys that open the inspector and the move sheet.
  private func handlePlacementKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
    if flags == [.option], keyboardFocusArea == .tasks {
      if event.charactersIgnoringModifiers?.lowercased() == "t" { quickEdit(.estimate); return true }
      if event.charactersIgnoringModifiers?.lowercased() == "s" { quickEdit(.start); return true }
      if viewMode == .board, keyboardNavigationSurfaceActive {
        switch event.keyCode {
        case 123: moveSelectedTaskToAdjacentColumn(by: -1); return true
        case 124: moveSelectedTaskToAdjacentColumn(by: 1); return true
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
      toggleInspector()
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
        if let folder = selectedFolder {
          toggleFolderExpansion(folder)
        } else {
          enterTaskSurfaceFromSidebar()
        }
      case 124:  // Right
        if let folder = selectedFolder {
          setFolderExpanded(folder, expanded: true)
        } else {
          enterTaskSurfaceFromSidebar()
        }
      case 123:  // Left
        if let folder = selectedFolder, expandedFolderIDs.contains(folder.id) {
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
      case 120: beginRenamingSelection()
      case 115: selectEverything()
      case 119: moveSidebarSelection(by: 10000)
      case 116: moveSidebarSelection(by: -8)
      case 121: moveSidebarSelection(by: 8)
      case 53:  // Escape
        selectedFolderID = nil
      default:
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": moveSidebarSelection(by: 1)
        case "k": moveSidebarSelection(by: -1)
        case "/": presentSearch()
        case "?": showsKeyboardHelp = true
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
      if viewMode == .board {
        focusAdjacentBoardColumn(by: 1)
      } else {
        enterSelectedTask()
      }
    case 123:  // ←
      if viewMode == .board {
        focusAdjacentBoardColumn(by: -1)
      } else {
        leaveSelectedTaskScope()
      }
    case 120:  // F2
      editSelectedTaskTitle()
    case 115: selectTaskAtEnd(first: true)
    case 119: selectTaskAtEnd(first: false)
    case 116: moveTaskSelection(by: -8)
    case 121: moveTaskSelection(by: 8)
    case 36, 76:  // Return / keypad Enter
      if viewMode == .board && selectedTask == nil { requestTaskComposerFocus() }
      else if viewMode == .board { enterSelectedTask() }
      else { requestRelativeTaskComposerFocus() }
    case 49:  // Space
      toggleSelectedTask()
    case 51, 117:  // Delete / forward delete
      deleteSelectedTask()
    case 53:  // Escape
      dismissKeyboardContext()
    default:
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "j": moveTaskSelection(by: 1)
      case "k": moveTaskSelection(by: -1)
      case "l": enterSelectedTask()
      case "h": leaveSelectedTaskScope()
      case "x", " ": toggleSelectedTask()
      case "f": focusSelectedTask()
      case "[":
        if scopeTaskID != nil { leaveSelectedTaskScope() }
        requestKeyboardFocus(.tasks)
      case "]":
        enterSelectedTask()
        requestKeyboardFocus(.tasks)
      case "/": presentSearch()
      case "?": showsKeyboardHelp = true
      default: return false
      }
    }
    return true
  }
}
