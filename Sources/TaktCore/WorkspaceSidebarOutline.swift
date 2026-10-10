import Foundation
import TaktRustCore

/// What a sidebar row is.
///
/// Every row is a place to be. Focus and the timeline used to be rows here
/// too, duplicating the mode strip; they are reached from there, the palette
/// and ⌘8/⌘9, and the sidebar is only lists again.
public enum WorkspaceSidebarRowKind: Equatable, Hashable, Sendable {
  case everything
  /// The day, from every list. A place like the others, beside Everything
  /// and the inbox, rather than only a segment of the mode strip.
  case today
  case list(String)
  /// A list nested inside a task, addressed by the task's id.
  case nestedList(String)
  case folder(String)
}

public struct WorkspaceSidebarRow: Identifiable, Equatable, Hashable, Sendable {
  /// Unique per *row*, not per thing.
  ///
  /// A pinned nested list is drawn twice — once in the shortcuts at the top,
  /// once in place under its list — and identifying both by the task's id made
  /// the cursor unable to get past the second copy: looking up "where am I"
  /// found the first occurrence every time, so a press moved back to just
  /// after the pinned row instead of onward. Two rows, two ids.
  public let id: String
  public let kind: WorkspaceSidebarRowKind
  /// Indentation, for the caller that draws it. Zero for the top-level rows.
  public let depth: Int

  public init(id: String, kind: WorkspaceSidebarRowKind, depth: Int) {
    self.id = id
    self.kind = kind
    self.depth = depth
  }

  /// The thing this row points at, which two rows can share.
  public var subjectID: String? {
    switch kind {
    case .everything, .today: nil
    case .list(let id), .nestedList(let id), .folder(let id): id
    }
  }
}

public struct SidebarListDescriptor: Equatable, Sendable {
  public let id: String
  public let folderID: String?

  public init(id: String, folderID: String?) {
    self.id = id
    self.folderID = folderID
  }
}

public struct SidebarNestedListDescriptor: Equatable, Sendable {
  /// The task's id — a nested list *is* a task.
  public let id: String
  public let listID: String
  public let depth: Int
  public let isPromoted: Bool

  public init(id: String, listID: String, depth: Int, isPromoted: Bool) {
    self.id = id
    self.listID = listID
    self.depth = depth
    self.isPromoted = isPromoted
  }
}

public struct SidebarFolderDescriptor: Equatable, Sendable {
  public let id: String
  public let parentFolderID: String?

  public init(id: String, parentFolderID: String?) {
    self.id = id
    self.parentFolderID = parentFolderID
  }
}

/// The sidebar, top to bottom, as one list.
///
/// There were two statements of this order: the view that drew it and a
/// `sidebarNavigationTargets` beside it whose doc comment promised it
/// "mirrors the visible sidebar order". A promise in a comment is the same
/// arrangement that had the settings pane telling people `u` was undo. This is
/// the order; the view and the arrow keys both read it.
public enum WorkspaceSidebarOutline {

  public static func rows(
    inbox: SidebarListDescriptor?,
    lists: [SidebarListDescriptor],
    folders: [SidebarFolderDescriptor],
    nestedLists: [SidebarNestedListDescriptor],
    expandedFolderIDs: Set<String>
  ) -> [WorkspaceSidebarRow] {
    // The order is the Rust core's (`sidebar::outline`), which Android calls
    // too: Today first, as the screen the day starts on, then Everything, the
    // inbox, the pinned shortcuts, the folders and the loose lists. A row
    // crosses back as its kind and an index into what was passed, three
    // integers, and its id is spelled here from strings already held.
    let rows = sidebarOutlineRows(
      inboxId: inbox?.id, lists: lists.map(\.core), folders: folders.map(\.core),
      nestedLists: nestedLists.map(\.core), expandedFolderIds: Array(expandedFolderIDs), includeToday: true)
    return rows.compactMap { row -> WorkspaceSidebarRow? in
      let index = Int(row.subject)
      let depth = Int(row.depth)
      switch row.kind {
      case .today:
        return WorkspaceSidebarRow(id: "row:today", kind: .today, depth: depth)
      case .everything:
        return WorkspaceSidebarRow(id: "row:everything", kind: .everything, depth: depth)
      case .inbox:
        guard let inbox else { return nil }
        return WorkspaceSidebarRow(id: "list:\(inbox.id)", kind: .list(inbox.id), depth: depth)
      case .list:
        let id = lists[index].id
        return WorkspaceSidebarRow(id: "list:\(id)", kind: .list(id), depth: depth)
      case .nestedList:
        let nested = nestedLists[index]
        return WorkspaceSidebarRow(
          id: "nested:\(nested.listID):\(nested.id)", kind: .nestedList(nested.id), depth: depth)
      case .pinnedNestedList:
        // The same task again, drawn at the top because that is what pinning
        // it was for.
        let id = nestedLists[index].id
        return WorkspaceSidebarRow(id: "pinned:\(id)", kind: .nestedList(id), depth: depth)
      case .folder:
        let id = folders[index].id
        return WorkspaceSidebarRow(id: "folder:\(id)", kind: .folder(id), depth: depth)
      }
    }
  }

  /// The row after `id`, `offset` steps away. A single step wraps from one end
  /// to the other; a longer jump stops at the end (see `CursorStepping`).
  public static func row(
    after id: String?, by offset: Int, in rows: [WorkspaceSidebarRow]
  ) -> WorkspaceSidebarRow? {
    guard !rows.isEmpty else { return nil }
    guard let id, let index = rows.firstIndex(where: { $0.id == id }) else {
      return offset < 0 ? rows.last : rows.first
    }
    return rows[CursorStepping.index(from: index, by: offset, count: rows.count)]
  }

  /// The row currently under the cursor, given what the workspace has
  /// selected. Used when the cursor has no stored row yet — on launch, or
  /// after a click, which selects a list without going through the arrows.
  public static func rowMatching(
    subjectID: String?, isEverything: Bool, isToday: Bool = false, in rows: [WorkspaceSidebarRow]
  ) -> WorkspaceSidebarRow? {
    if isToday { return rows.first { $0.kind == .today } }
    if isEverything { return rows.first { $0.kind == .everything } }
    guard let subjectID else { return nil }
    return rows.first { $0.subjectID == subjectID }
  }
}

extension WorkspaceSidebarOutline {
  /// Every list inside a folder, including the ones inside its sub-folders.
  ///
  /// A folder is a place lists are kept, so being in one means being in all of
  /// them — the same relationship Everything has to the whole workspace, one
  /// level down. Sub-folders are included because a folder you have collapsed
  /// is still a folder you are inside; a scope that changed depending on which
  /// triangles happened to be open would be a scope you could not predict.
  ///
  /// Order follows the sidebar: this folder's own lists first, then each
  /// sub-folder's, so the combined view reads in the order the tree does.
  /// A malformed parent chain terminates rather than hangs. The Rust core's
  /// `sidebar_list_ids_in_folder`.
  public static func listIDs(
    inFolder folderID: String,
    folders: [SidebarFolderDescriptor],
    lists: [SidebarListDescriptor]
  ) -> [String] {
    sidebarListIdsInFolder(folderId: folderID, folders: folders.map(\.core), lists: lists.map(\.core))
  }
}

extension SidebarListDescriptor {
  var core: SidebarList { SidebarList(id: id, folderId: folderID) }
}

extension SidebarFolderDescriptor {
  var core: SidebarFolder { SidebarFolder(id: id, parentFolderId: parentFolderID) }
}

extension SidebarNestedListDescriptor {
  var core: SidebarNestedList {
    SidebarNestedList(id: id, listId: listID, depth: UInt32(max(depth, 0)), isPromoted: isPromoted)
  }
}
