import Foundation
import PriorityCore
import PriorityWorkspace

/// Walking the sidebar.
///
/// The arrow keys used to move over a hand-kept list of "navigation targets"
/// that named Everything, the lists and the folders. Two things were wrong
/// with it. Focus and the timeline sit at the top of the sidebar and were not
/// in it, so arrowing up from Everything stopped dead at two rows you can
/// plainly see; and a pinned nested list is drawn twice, under its parent and
/// again in the pinned strip, so `firstIndex(of:)` on the list's id always
/// found the first copy and the cursor could not be moved off it.
///
/// `WorkspaceSidebarOutline` now produces the order, from the same inputs the
/// view draws from, and gives every row an id of its own. This extension is
/// only the join: model state in, a row out, the row applied.
@MainActor
extension WorkspaceViewModel {
  /// Every row in the sidebar, in the order they are drawn.
  var sidebarRows: [WorkspaceSidebarRow] {
    WorkspaceSidebarOutline.rows(
      inbox: inboxList.map { SidebarListDescriptor(id: $0.id, folderID: $0.folderId) },
      lists: lists.filter { $0.systemRole != .inbox }
        .map { SidebarListDescriptor(id: $0.id, folderID: $0.folderId) },
      folders: folders.map { SidebarFolderDescriptor(id: $0.id, parentFolderID: $0.parentFolderId) },
      nestedLists: nestedLists.map {
        SidebarNestedListDescriptor(
          id: $0.task.id,
          listID: $0.task.listId,
          depth: $0.depth,
          isPromoted: $0.task.isPromoted == true && $0.task.status == .open)
      },
      expandedFolderIDs: expandedFolderIDs)
  }

  /// The row the cursor is on.
  ///
  /// The stored id is preferred, so standing on Focus survives a reload. When
  /// it no longer names a row — a list was archived, a folder collapsed under
  /// you — the selection is asked instead, which is the row the rest of the
  /// window already agrees you are on.
  var sidebarCursorRow: WorkspaceSidebarRow? {
    let rows = sidebarRows
    if let sidebarCursorID, let row = rows.first(where: { $0.id == sidebarCursorID }) { return row }
    return WorkspaceSidebarOutline.rowMatching(
      subjectID: selectedFolderID ?? currentSidebarID,
      isEverything: selectedFolderID == nil && isEverythingSelected,
      in: rows)
  }

  /// Whether this row is the one the keyboard is standing on.
  ///
  /// Deliberately not the same question as `isCurrentSidebarRow`, which asks
  /// which list is *open*. They are usually the same row and usually should
  /// be; they come apart on Focus and the timeline, where the cursor has to
  /// be able to sit without the main pane changing under it.
  func isSidebarCursorRow(_ rowID: String) -> Bool {
    sidebarCursorRow?.id == rowID
  }

  /// The `.id` the cursor's row is drawn under, so the list can scroll to it.
  ///
  /// `nil` for Focus and the timeline, which sit above the scroll view and
  /// are always on screen — there is nothing to scroll them into.
  var sidebarCursorScrollID: String? {
    guard let row = sidebarCursorRow else { return nil }
    switch row.kind {
    case .focus, .timeline: return nil
    case .everything: return "priority:everything"
    case .list(let id), .folder(let id): return id
    case .nestedList(let id): return row.id.hasPrefix("pinned:") ? "promoted:\(id)" : id
    }
  }

  func moveSidebarSelection(by offset: Int) {
    let rows = sidebarRows
    guard !rows.isEmpty else { return }
    guard let next = WorkspaceSidebarOutline.row(after: sidebarCursorRow?.id, by: offset, in: rows)
    else { return }
    applySidebarCursor(next)
  }

  /// Puts the cursor on the first row — Focus, unless the sidebar is somehow
  /// empty. `Home` in the sidebar used to mean "select Everything", which was
  /// the top row at the time and no longer is.
  func moveSidebarSelectionToEnd(first: Bool) {
    let rows = sidebarRows
    guard let row = first ? rows.first : rows.last else { return }
    applySidebarCursor(row)
  }

  /// Moves the cursor and makes the row's selection true.
  ///
  /// Focus and the timeline select nothing: they are buttons that happen to
  /// live in the sidebar, and arrowing onto one must not close the list you
  /// were reading. Everything else selects as a click on it would.
  func applySidebarCursor(_ row: WorkspaceSidebarRow) {
    switch row.kind {
    case .focus, .timeline:
      break
    case .everything:
      selectedFolderID = nil
      selectEverything()
    case .list(let id):
      selectedFolderID = nil
      selectList(id)
    case .nestedList(let id):
      selectedFolderID = nil
      if let task = nestedLists.first(where: { $0.task.id == id })?.task { selectNestedList(task) }
    case .folder(let id):
      if let folder = folders.first(where: { $0.id == id }) { selectFolder(folder) }
    }
    // Last, because the selection calls above clear the cursor — that is how
    // a click puts it back under the row you clicked.
    sidebarCursorID = row.id
  }

  /// What Return and → do on the row you are standing on.
  ///
  /// Every row answers now. Focus and the timeline open their screens, a
  /// folder toggles or expands, and everything else hands the keyboard to the
  /// task surface — which is what a list row has always done.
  func activateSidebarCursor(expandOnly: Bool) {
    guard let row = sidebarCursorRow else { return enterTaskSurfaceFromSidebar() }
    switch row.kind {
    case .focus:
      run(.goFocus)
    case .timeline:
      run(.goTimeline)
    case .folder(let id):
      guard let folder = folders.first(where: { $0.id == id }) else { return }
      if expandOnly { setFolderExpanded(folder, expanded: true) } else { toggleFolderExpansion(folder) }
    case .everything, .list, .nestedList:
      enterTaskSurfaceFromSidebar()
    }
  }
}

@MainActor
extension WorkspaceViewModel {
  /// Reorders whatever the cursor is on.
  ///
  /// ⌘↑/↓ in the sidebar used to reorder a folder or a list and silently do
  /// nothing on a nested list, which is the row type you are most likely to
  /// have a lot of. A nested list is a task, so it reorders the way a task
  /// does; the key does not need to know that, and now does not.
  ///
  /// Focus and the timeline are fixed rows and say so by refusing, rather
  /// than by appearing to work.
  @discardableResult
  func reorderSidebarCursor(by offset: Int) -> Bool {
    guard let row = sidebarCursorRow else { return false }
    switch row.kind {
    case .focus, .timeline, .everything:
      return false
    case .folder(let id):
      guard let folder = folders.first(where: { $0.id == id }) else { return false }
      moveFolderWithinSiblings(folder, by: offset)
    case .list(let id):
      guard let list = lists.first(where: { $0.id == id }) else { return false }
      moveListWithinFolder(list, by: offset)
    case .nestedList(let id):
      guard let task = nestedLists.first(where: { $0.task.id == id })?.task else { return false }
      moveTaskWithinSiblings(task, by: offset)
    }
    return true
  }
}
