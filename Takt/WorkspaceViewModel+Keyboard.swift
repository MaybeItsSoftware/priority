import AppKit
import Foundation
import TaktWorkspace
import TaktCore

/// The desktop window's key handling: spell the key the way the catalogue
/// does, run the two-letter sequence machine over it, and ask
/// `WorkspaceCommandCatalog` what it means on the surface on screen.
///
/// There is no `switch` over key codes here any more, and that is the point.
/// The router used to be one, a few hundred lines long, beside a catalogue it
/// was meant to agree with and a second copy of the sequence list — so the
/// reference advertised keys that did nothing (`⌘⌃C`, the ladder's `o`), and
/// the focus screen "owned the keyboard" while `⌫` fell through it to delete a
/// task hidden behind it. A key now does what its catalogue row says, on the
/// surface the row names, and what a command *does* lives in `run(_:key:)`.
extension NSEvent {
  /// This key press as the catalogue spells it — `cmd+shift+c`, `?`, `enter`.
  var workspaceCommandKey: String? {
    let flags = modifierFlags.intersection([.command, .option, .control, .shift])
    return WorkspaceCommandCatalog.key(
      keyCode: keyCode,
      charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
      shift: flags.contains(.shift),
      ctrl: flags.contains(.control),
      cmd: flags.contains(.command),
      option: flags.contains(.option))
  }
}

@MainActor
extension WorkspaceViewModel {
  /// Handles keys that belong to the desktop workspace only. Text editing is
  /// filtered by `MainWindowController` before this method is reached.
  @discardableResult
  func handleDesktopKey(_ event: NSEvent) -> Bool {
    guard let key = event.workspaceCommandKey else { return false }
    // A delete waiting to be confirmed owns the next key: Return deletes,
    // anything else lets it go — and is swallowed, so a stray letter meant
    // for the prompt does not also act on the list behind it.
    if pendingTaskDeletionID != nil {
      if key == "enter" { confirmPendingTaskDeletion() } else { cancelPendingTaskDeletion() }
      return true
    }
    // Sequences are bare letters. Anything chorded — Shift included, so `⇧X`
    // is the way to run `x` without waiting — releases a held key first, so
    // the two run in the order they were pressed.
    guard event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else {
      if let held = desktopShortcutSequence.flush() { dispatchKey(held) }
      return dispatchKey(key)
    }
    let sequences = WorkspaceCommandCatalog.sequences(on: commandSurface)
    switch desktopShortcutSequence.advance(key, at: event.timestamp, sequences: sequences) {
    case .pending:
      releaseHeldKeyAfterTimeout(heldAt: event.timestamp)
      return true
    case .command(let sequence):
      dispatchKey(sequence)
      return true
    case .flush(let held):
      dispatchKey(held)
      return dispatchKey(key)
    case .flushAndHold(let held):
      dispatchKey(held)
      releaseHeldKeyAfterTimeout(heldAt: event.timestamp)
      return true
    case .pass:
      return dispatchKey(key)
    }
  }

  /// Runs what the key means on the surface on screen *now* — asked afresh
  /// each time, because a flushed key can change the surface for the key
  /// behind it (`l` entering a task, say).
  @discardableResult
  private func dispatchKey(_ key: String) -> Bool {
    let surface = commandSurface
    if let command = WorkspaceCommandCatalog.command(forKey: key, on: surface) {
      run(command.id, key: key)
      return true
    }
    return WorkspaceCommandCatalog.swallowsUnhandledKey(key, on: surface)
  }

  /// A key held for a sequence that never came still has to do its own job.
  /// The hold's timestamp identifies it, so a timer armed for an earlier hold
  /// cannot release a later one early.
  private func releaseHeldKeyAfterTimeout(heldAt time: TimeInterval) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(DesktopShortcutSequence.timeout))
      guard let self, let held = self.desktopShortcutSequence.expire(heldAt: time) else { return }
      self.dispatchKey(held)
    }
  }

  // MARK: - What the direction keys mean, per region

  /// ⌘N: below the selected task where a list reads top to bottom — the
  /// outline and the matrix's rows — and into the composer everywhere else.
  /// Return used to do this on the outline while it opened the card on the
  /// board and started it on Today; Return now opens the task everywhere.
  func addTaskBelowSelection() {
    if selectedTask != nil && (viewMode == .outline || viewMode == .matrix) {
      requestRelativeTaskComposerFocus()
    } else {
      requestTaskComposerFocus()
    }
  }

  /// Escape, which means "back out one step" from wherever the keyboard is.
  func dismissFromKeyboard() {
    // A draft row left open after clicking away is the first thing to go.
    if isDraftingTask { endTaskDraft(); return }
    switch keyboardFocusArea {
    case .sidebar:
      // Leaving a folder has to land somewhere. It used to fall back on
      // whichever list was still selected behind it; a folder scope has no
      // such list, so clearing it on its own would empty the pane.
      if selectedFolderID != nil { run(.goEverything) }
    case .inspector:
      // Back to the work, leaving the dock where it is. It used to close:
      // a pane that vanishes whenever you leave it is one you reopen all day.
      requestKeyboardFocus(.tasks)
    default:
      dismissKeyboardContext()
    }
  }

  func collapseSidebarCursor() {
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
  }

  func moveSidebarCursor(_ key: String) {
    switch CursorStep(key: key) {
    case .by(let offset): moveSidebarSelection(by: offset)
    case .first: moveSidebarSelectionToEnd(first: true)
    case .last: moveSidebarSelectionToEnd(first: false)
    case nil: break
    }
  }

  func moveDoneCursor(_ key: String) {
    switch CursorStep(key: key) {
    case .by(let offset): moveDoneCursor(by: offset)
    case .first: doneCursorID = completedTasks.first?.id
    case .last: doneCursorID = completedTasks.last?.id
    case nil: break
    }
  }

  func moveTimelineCursor(_ key: String) {
    let summaries = timelineSummaries
    switch CursorStep(key: key) {
    case .by(let offset): moveTimelineCursor(by: offset)
    case .first: timelineCursorID = summaries.first?.id
    case .last: timelineCursorID = summaries.last?.id
    case nil: break
    }
  }

  /// `⌥1`–`⌥4`, in the order the matrix is read: urgent and important first.
  func placeSelectionInQuadrant(_ key: String) {
    guard let task = selectedTask else { return }
    switch key.last {
    case "1": setMatrixPosition(.init(urgency: 1, importance: 1), for: task)
    case "2": setMatrixPosition(.init(urgency: 0, importance: 1), for: task)
    case "3": setMatrixPosition(.init(urgency: 1, importance: 0), for: task)
    case "4": setMatrixPosition(.init(urgency: 0, importance: 0), for: task)
    default: break
    }
  }

  func quickEdit(_ kind: WorkspaceTaskQuickEditKind) {
    guard let task = selectedTask else { return }
    presentOverlay(.quickEdit(WorkspaceTaskQuickEditRequest(task: task, kind: kind)))
  }

  /// The habit form, on the selected task: its habit if it has one, a new
  /// habit made from it if not. With no task (or a list) selected, a
  /// standalone habit.
  func presentHabitForm() {
    guard let store else { return }
    let task = selectedTask.flatMap { $0.isList ? nil : $0 }
    do {
      let context = try store.habitFormContext(forTaskId: task?.id)
      presentOverlay(.habit(WorkspaceHabitRequest(context: context)))
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// `ee`/F2: in the outline the title turns into a field in its own row,
  /// the way Checkvist edits; elsewhere the quick-edit overlay does the job.
  func editSelectedTaskTitle(caret: WorkspaceTitleCaret = .selectAll) {
    if keyboardFocusArea == .sidebar { beginRenamingSelection(); return }
    if viewMode == .outline, let task = selectedTask, outlineRows.contains(where: { $0.id == task.id }) {
      editingTaskTitleCaret = caret
      editingTaskTitleID = task.id
    } else {
      quickEdit(.title)
    }
  }

  /// Saves an in-row title edit. Trailing tokens are read the way the add
  /// field reads them — `45m`, `@fri` or `^fri`, `#tag`, `!1` — and set the
  /// estimate, due day, tags (added to the ones it has) and priority, all as
  /// one undo step with the new title.
  func commitTaskTitleEdit(_ task: WorkspaceTask, text: String) {
    editingTaskTitleID = nil
    let capture = TaskCapture.parse(text)
    guard !capture.title.isEmpty else { return }
    guard capture.title != task.title || capture.hasDetails else { return }
    editTaskValues(of: task) { values in
      values.title = capture.title
      if let dueAt = capture.dueAt { values.dueAt = dueAt; values.dueDate = nil }
      if let seconds = capture.estimateSeconds { values.estimateMinutes = String(seconds / 60) }
      if let priority = capture.priority { values.priority = priority }
      if !capture.tags.isEmpty {
        let existing = values.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        values.tags = (existing + capture.tags).joined(separator: ", ")
      }
    }
  }

  func cancelTaskTitleEdit() {
    editingTaskTitleID = nil
  }

  func editTaskValues(_ change: (inout TaskEditorValues) -> Void) {
    guard let task = selectedTask else { return }
    editTaskValues(of: task, change)
  }

  func editTaskValues(of task: WorkspaceTask, _ change: (inout TaskEditorValues) -> Void) {
    guard let store else { return }
    perform {
      var draft = TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: task.id))
      change(&draft.values)
      _ = try store.saveTaskEditor(draft)
      reloadOutline(refreshSidebar: task.isList)
      reloadDailies()
      reloadNextUp()
    }
  }

  func invalidateTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setStatus(task.status == .cancelled ? .open : .cancelled, for: task.id)
      reloadOutline(refreshSidebar: task.isList)
      reloadNextUp()
    }
  }

  func selectTaskAtEnd(first: Bool) {
    let rows = navigationRowIDs()
    selectedTaskID = first ? rows.first : rows.last
  }
}

/// Where a list-walking key moves a cursor. Shared by the sidebar, the
/// done rail and the timeline, whose catalogue rows list the same keys — the sidebar adds
/// `gg` and `⇧G`, the ends in Zed's vim project panel.
private enum CursorStep {
  case by(Int), first, last

  init?(key: String) {
    switch key {
    case "down", "j": self = .by(1)
    case "up", "k": self = .by(-1)
    case "pagedown": self = .by(8)
    case "pageup": self = .by(-8)
    case "home", "cmd+up", "gg": self = .first
    case "end", "cmd+down", "shift+g": self = .last
    default: return nil
    }
  }
}

/// Where an in-row title edit starts typing.
enum WorkspaceTitleCaret {
  case selectAll, start, end
}

extension WorkspaceViewModel {
  /// ⌥⌘← / ⌥⌘→ and ⌘{ / ⌘}, Zed's previous and next tab: the list above or
  /// below in the sidebar, folders opened through. From Today, Everything or
  /// a folder there is no current list, so it starts at either end.
  func selectAdjacentList(by offset: Int) {
    let ordered = listsInSidebarOrder
    guard !ordered.isEmpty else { return }
    let current = (isEverythingSelected || selectedFolderID != nil)
      ? nil : ordered.firstIndex { $0.id == selectedListID }
    let target: Int
    if let current {
      target = min(max(0, current + offset), ordered.count - 1)
      guard target != current else { return }
    } else {
      target = offset > 0 ? 0 : ordered.count - 1
    }
    selectList(ordered[target].id)
  }
}

extension WorkspaceViewModel {
  /// Records a move between lists for ⌃- / ⌃⇧- and for ⌘P's recent order.
  func noteListVisit(leaving previous: String?, arriving id: String) {
    guard previous != id else { return }
    if !isWalkingListHistory {
      if let previous { listBackStack.append(previous) }
      if listBackStack.count > 50 { listBackStack.removeFirst(listBackStack.count - 50) }
      listForwardStack.removeAll()
    }
    var recent = recentListIDs.filter { $0 != id }
    recent.insert(id, at: 0)
    recentListIDs = Array(recent.prefix(30))
    UserDefaults.standard.set(recentListIDs, forKey: "workspaceRecentListsV1")
  }

  /// Zed's `pane::GoBack`, for lists: the one you were in before this one.
  func goBackInListHistory() {
    walkListHistory(from: &listBackStack, to: &listForwardStack)
  }

  func goForwardInListHistory() {
    walkListHistory(from: &listForwardStack, to: &listBackStack)
  }

  private func walkListHistory(from source: inout [String], to destination: inout [String]) {
    // Lists deleted since are skipped rather than ending the walk.
    while let id = source.popLast() {
      guard lists.contains(where: { $0.id == id }) else { continue }
      if let current = selectedListID, !isMultiListScope { destination.append(current) }
      isWalkingListHistory = true
      selectList(id)
      isWalkingListHistory = false
      return
    }
  }
}
