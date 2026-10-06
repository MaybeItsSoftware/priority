import Foundation
import TaktWorkspace

/// The title bar's add field: where a typed task lands, and what the field
/// says about it before you press Return.
///
/// There is one field for the whole window, in the title bar, rather than a
/// composer at the foot of each pane. The foot of the window is the status
/// bar's; a composer sitting on it made the bottom edge two strips deep, and
/// Today, the matrix, focus and the timeline had no composer at all, so `a`
/// there focused a field that was not on screen.
///
/// Where it lands, in order:
/// - beside or inside the task `a`/`A`/`O` was pressed on, when it was;
/// - wherever quick capture has been steered to, while it is running;
/// - the list on screen — inside the opened task, if one is open — or, in a
///   folder, the folder's chosen list;
/// - otherwise the inbox. Everything is not a list, so a task typed there is
///   a thought to file later, which is what the inbox is for.
///
/// On Today, the last two also put the task in the Today column, the way the
/// day's own field did before the title bar took its job, and make it due
/// today unless the text names another day: adding to Today means doing it
/// today, and a due date says so everywhere else too — the phone, the CLI.
@MainActor
extension WorkspaceViewModel {
  func submitAddField(named title: String) {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if isQuickCaptureActive && taskInsertionReference == nil {
      submitQuickCapture(named: title)
    } else if taskInsertionReference == nil && addsToScopedList && viewMode == .today {
      // Today's own field put what you typed on today, in the list on
      // screen. The title bar does the same while Today is up, so losing that
      // field lost nothing: a task added here is on the day you are reading.
      createBoardTask(named: title, in: todayColumn)
    } else if taskInsertionReference != nil || addsToScopedList {
      if viewMode == .board { createBoardTask(named: title) } else { createTask(named: title) }
    } else {
      createInboxTask(named: title)
    }
  }

  /// Escape in the field: forget the text's destination as well as the text,
  /// and hand the keyboard back to the tasks it came from.
  func cancelAddField() {
    taskInsertionReference = nil
    if isQuickCaptureActive { cancelQuickCapture() }
    requestKeyboardFocus(.tasks)
  }

  /// What the field names as its destination, in the few words it has room
  /// for.
  var addFieldDestinationTitle: String {
    // On Today the task lands on today as well as in a list, and the field
    // says both, so Return on Today is no more of a guess than anywhere else.
    if viewMode == .today && taskInsertionReference == nil && !isQuickCaptureActive {
      return "Today · \(addFieldListTitle)"
    }
    return addFieldListTitle
  }

  /// The list half of the destination: where the task will be filed.
  private var addFieldListTitle: String {
    if let reference = taskInsertionReference {
      let placement = taskInsertionIsChild ? "Inside" : taskInsertionAbove ? "Above" : "Below"
      return "\(placement) \(reference.title)"
    }
    if isQuickCaptureActive { return quickCaptureDestination?.path ?? addFieldInbox?.name ?? "Inbox" }
    if addsToScopedList {
      if let folderList = folderScopeDestinationID.flatMap({ id in lists.first { $0.id == id } }),
        selectedFolderID != nil {
        return folderList.name
      }
      return scopeTask?.title ?? selectedList?.name ?? "Inbox"
    }
    return addFieldInbox?.name ?? "Inbox"
  }

  /// Whether the pane on screen is one list (or one folder of lists) that a
  /// new task can belong to.
  private var addsToScopedList: Bool {
    if selectedFolderID != nil { return folderScopeDestinationID != nil }
    return !isEverythingSelected && selectedList != nil
  }

  /// The due date a task added from Today's field takes when its text names
  /// none: the start of today. Nil anywhere else, and for `a`/`A`/`O`, which
  /// place a task beside another rather than on the day.
  var addedTodayDueAt: Date? {
    guard viewMode == .today, taskInsertionReference == nil, !isQuickCaptureActive else { return nil }
    return Calendar.current.startOfDay(for: .now)
  }

  /// The board column that puts a task on today — the one Today's own field
  /// used to file into.
  private var todayColumn: WorkspaceKanbanColumn? { boardColumns.first { $0.id == "today" } }

  /// The inbox, or the first list when there is somehow no inbox, so the
  /// field never refuses a task it could have filed somewhere.
  private var addFieldInbox: TaskList? { inboxList ?? lists.first }

  private func createInboxTask(named title: String) {
    guard let store, let inbox = addFieldInbox else { return }
    // On the board, into the column you are on, the way the board's own
    // composer did — Everything's board includes the inbox's tasks. On Today,
    // into the Today column, so it is on the day you added it from.
    let column: WorkspaceKanbanColumn? = switch viewMode {
    case .board: boardColumns.first { $0.id == activeBoardColumnID }
    case .today: todayColumn
    case .outline, .matrix: nil
    }
    perform {
      let parentID = try visibleRootParentTaskID(for: inbox, store: store)
      let task = try store.createTask(
        capturing: title, listId: inbox.id, parentTaskId: parentID, kanbanColumn: column?.id,
        defaultDueAt: addedTodayDueAt)
      // Selected only where it will be on screen to be selected.
      if isEverythingSelected || selectedListID == inbox.id { selectedTaskID = task.id }
      reloadOutline()
    }
  }
}
