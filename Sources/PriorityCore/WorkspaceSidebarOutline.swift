import Foundation

/// What a sidebar row is.
///
/// `focus` and `timeline` are rows like any other here, which is the point.
/// On screen they are a card and a button sitting above the list rather than
/// inside it, and because the keyboard walked the list alone they were the two
/// things in the sidebar the arrows could not reach — visible, clickable, and
/// unreachable without the mouse or a shortcut you had to already know.
public enum WorkspaceSidebarRowKind: Equatable, Hashable, Sendable {
  case focus
  case timeline
  case everything
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
    case .focus, .timeline, .everything: nil
    case .list(let id), .nestedList(let id), .folder(let id): id
    }
  }

  /// Whether landing here changes which list is on screen. The focus and
  /// timeline rows do not — they are things to open, not places to be.
  public var selectsAList: Bool {
    switch kind {
    case .focus, .timeline: false
    case .everything, .list, .nestedList, .folder: true
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
    var result: [WorkspaceSidebarRow] = [
      WorkspaceSidebarRow(id: "row:focus", kind: .focus, depth: 0),
      WorkspaceSidebarRow(id: "row:timeline", kind: .timeline, depth: 0),
      WorkspaceSidebarRow(id: "row:everything", kind: .everything, depth: 0),
    ]
    var visitedFolders = Set<String>()

    func appendList(_ list: SidebarListDescriptor, depth: Int) {
      result.append(
        WorkspaceSidebarRow(id: "list:\(list.id)", kind: .list(list.id), depth: depth))
      for nested in nestedLists where nested.listID == list.id {
        result.append(
          WorkspaceSidebarRow(
            id: "nested:\(list.id):\(nested.id)",
            kind: .nestedList(nested.id),
            depth: depth + 1 + nested.depth))
      }
    }

    func appendFolder(_ folder: SidebarFolderDescriptor, depth: Int) {
      guard visitedFolders.insert(folder.id).inserted else { return }
      result.append(
        WorkspaceSidebarRow(id: "folder:\(folder.id)", kind: .folder(folder.id), depth: depth))
      guard expandedFolderIDs.contains(folder.id) else { return }
      for list in lists where list.folderID == folder.id {
        appendList(list, depth: depth + 1)
      }
      for child in folders where child.parentFolderID == folder.id {
        appendFolder(child, depth: depth + 1)
      }
    }

    if let inbox { appendList(inbox, depth: 0) }
    // The pinned shortcuts, which are the same tasks again — drawn at the top
    // because that is what pinning them was for.
    for nested in nestedLists where nested.isPromoted {
      result.append(
        WorkspaceSidebarRow(id: "pinned:\(nested.id)", kind: .nestedList(nested.id), depth: 0))
    }
    for folder in folders where folder.parentFolderID == nil {
      appendFolder(folder, depth: 0)
    }
    for list in lists where list.folderID == nil {
      appendList(list, depth: 0)
    }
    return result
  }

  /// The row after `id`, `offset` steps away, stopping at either end rather
  /// than wrapping — wrapping in a list you are reading turns a held arrow key
  /// into a loop you have to notice to escape.
  public static func row(
    after id: String?, by offset: Int, in rows: [WorkspaceSidebarRow]
  ) -> WorkspaceSidebarRow? {
    guard !rows.isEmpty else { return nil }
    guard let id, let index = rows.firstIndex(where: { $0.id == id }) else {
      return offset < 0 ? rows.last : rows.first
    }
    return rows[min(max(0, index + offset), rows.count - 1)]
  }

  /// The row currently under the cursor, given what the workspace has
  /// selected. Used when the cursor has no stored row yet — on launch, or
  /// after a click, which selects a list without going through the arrows.
  public static func rowMatching(
    subjectID: String?, isEverything: Bool, in rows: [WorkspaceSidebarRow]
  ) -> WorkspaceSidebarRow? {
    if isEverything { return rows.first { $0.kind == .everything } }
    guard let subjectID else { return nil }
    return rows.first { $0.subjectID == subjectID }
  }
}
