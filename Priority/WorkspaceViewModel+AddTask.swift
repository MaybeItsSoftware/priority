import Foundation
import PriorityWorkspace

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
@MainActor
extension WorkspaceViewModel {
  func submitAddField(named title: String) {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if isQuickCaptureActive && taskInsertionReference == nil {
      submitQuickCapture(named: title)
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

  /// The inbox, or the first list when there is somehow no inbox, so the
  /// field never refuses a task it could have filed somewhere.
  private var addFieldInbox: TaskList? { inboxList ?? lists.first }

  private func createInboxTask(named title: String) {
    guard let store, let inbox = addFieldInbox else { return }
    // On the board, into the column you are on, the way the board's own
    // composer did — Everything's board includes the inbox's tasks.
    let column = viewMode == .board ? boardColumns.first { $0.id == activeBoardColumnID } : nil
    perform {
      let parentID = try visibleRootParentTaskID(for: inbox, store: store)
      let task = try store.createTask(
        listId: inbox.id, title: title, parentTaskId: parentID, kanbanColumn: column?.id)
      // Selected only where it will be on screen to be selected.
      if isEverythingSelected || selectedListID == inbox.id { selectedTaskID = task.id }
      reloadOutline()
    }
  }
}
