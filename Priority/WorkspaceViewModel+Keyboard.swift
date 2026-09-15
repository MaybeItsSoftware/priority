import AppKit
import Foundation
import PriorityWorkspace

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
    if showsFocusScreen, handleFocusLadderKey(event, flags: flags) { return true }
    if handleViewSwitchKey(event, flags: flags) { return true }
    if handleModifiedKey(event, flags: flags) { return true }
    if keyboardFocusArea == .sidebar { return handleSidebarKey(event) }
    return handleTaskSurfaceKey(event)
  }

  /// Climbing the focus ladder. Up is *less* important — the direction matches
  /// the screen, where the most important thing sits at the foot.
  private func handleFocusLadderKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
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
    case "x": completeFocusLadderSelection(); return true
    // Space stages rather than ticking off: on a screen whose whole purpose is
    // starting work, the big key should start work.
    case " ": if stagedTaskID == nil { stageFocusLadderSelection() } else { beginStagedFocus() }; return true
    default: return false
    }
  }

  /// Command-digit: the regions and view modes, plus the focus screen on ⌘8.
  private func handleViewSwitchKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {

    if flags == [.command] {
      switch event.charactersIgnoringModifiers {
      case "0": selectEverything(); requestKeyboardFocus(.tasks); return true
      case "1": requestKeyboardFocus(.sidebar); return true
      case "2": requestKeyboardFocus(.tasks); return true
      case "3":
        if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
        requestKeyboardFocus(selectedTask == nil ? .tasks : .inspector)
        return true
      case "4": selectViewMode(.board); requestKeyboardFocus(.tasks); return true
      case "5": selectViewMode(.outline); requestKeyboardFocus(.tasks); return true
      case "6": selectViewMode(.dailies); requestKeyboardFocus(.tasks); return true
      case "7": selectViewMode(.matrix); requestKeyboardFocus(.tasks); return true
      case "8":
        // A running session is returned to rather than restarted; otherwise the
        // focus screen decides what to start on, which is its whole job.
        if activeFocusSession != nil { showsFocusPanel = true } else { presentFocusScreen() }
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
      default:
        break
      }
    }
    if flags == [.command, .shift] {
      switch event.charactersIgnoringModifiers?.lowercased() {
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
    if flags == [.command] {
      switch event.keyCode {
      case 125:  // Cmd+Down
        if let task = selectedTask {
          moveTaskWithinSiblings(task, by: 1)
        } else if let list = selectedList {
          moveListWithinFolder(list, by: 1)
        }
        return true
      case 126:  // Cmd+Up
        if let task = selectedTask {
          moveTaskWithinSiblings(task, by: -1)
        } else if let list = selectedList {
          moveListWithinFolder(list, by: -1)
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
    if event.charactersIgnoringModifiers?.lowercased() == "i" {
      toggleInspector()
      return true
    }
    if event.charactersIgnoringModifiers?.lowercased() == "m" {
      requestMoveSelectedTask()
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
          requestKeyboardFocus(.tasks)
        }
      case 124:  // Right
        if let folder = selectedFolder {
          setFolderExpanded(folder, expanded: true)
        } else {
          requestKeyboardFocus(.tasks)
        }
      case 123:  // Left
        if let folder = selectedFolder, expandedFolderIDs.contains(folder.id) {
          setFolderExpanded(folder, expanded: false)
        } else if let parentID = selectedFolder?.parentFolderId,
          let parent = folders.first(where: { $0.id == parentID }) {
          selectFolder(parent)
        } else if let parentID = selectedList?.folderId,
          let parent = folders.first(where: { $0.id == parentID }) {
          selectFolder(parent)
        } else if !isEverythingSelected {
          selectEverything()
        }
      case 53:  // Escape
        selectedFolderID = nil
      default:
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": moveSidebarSelection(by: 1)
        case "k": moveSidebarSelection(by: -1)
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
      if viewMode == .board, let task = selectedTask {
        selectTaskInAdjacentColumn(from: task, by: 1)
      } else {
        enterSelectedTask()
      }
    case 123:  // ←
      if viewMode == .board, let task = selectedTask {
        selectTaskInAdjacentColumn(from: task, by: -1)
      } else {
        leaveSelectedTaskScope()
      }
    case 36, 76:  // Return / keypad Enter
      enterSelectedTask()
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
      case "[": moveListSelection(by: -1)
      case "]": moveListSelection(by: 1)
      case "?": showsKeyboardHelp = true
      default: return false
      }
    }
    return true
  }
}
