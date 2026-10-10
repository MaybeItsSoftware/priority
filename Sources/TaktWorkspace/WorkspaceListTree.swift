import Foundation
import TaktRustCore

/// One list's tasks, read once and then shaped as many ways as a screen needs.
///
/// The desktop used to ask the store for the same list three or four times per
/// keystroke — the outline, the board's direct children, the board's
/// descendants, the sidebar's nested lists and its count — each a query and a
/// decode of every row. Every one of those is a pure function of the list's
/// rows, so they live here and the store reads the rows once.
///
/// The store's own `outline(in:)`, `visibleOutline(in:)` and
/// `actionableTasks(in:)` are built on this type, so a view that shapes a tree
/// in memory cannot drift from what the store would have answered.
public struct WorkspaceListTree: Sendable, Equatable {
  public let listId: String
  /// Every task in the list, in sibling order (`sortOrder`, then `createdAt`).
  public let tasks: [WorkspaceTask]
  private let children: [String?: [WorkspaceTask]]

  public init(listId: String, tasks: [WorkspaceTask]) {
    self.listId = listId
    self.tasks = tasks
    self.children = Dictionary(grouping: tasks, by: \.parentTaskId)
  }

  /// Depth-first, in sibling order, starting beneath `parentTaskId`.
  public func outline(under parentTaskId: String? = nil) -> [TaskOutlineItem] {
    var result: [TaskOutlineItem] = []
    var visited = Set<String>()
    func append(_ parent: String?, depth: Int) {
      for task in children[parent, default: []] where visited.insert(task.id).inserted {
        result.append(TaskOutlineItem(task: task, depth: depth))
        append(task.id, depth: depth + 1)
      }
    }
    append(parentTaskId, depth: 0)
    return result
  }

  /// The outline without archived nested lists or anything beneath them.
  public func visibleOutline(under parentTaskId: String? = nil) -> [TaskOutlineItem] {
    Self.hidingArchivedLists(outline(under: parentTaskId))
  }

  /// A parent's direct children, in sibling order.
  public func children(of parentTaskId: String?) -> [WorkspaceTask] {
    children[parentTaskId, default: []]
  }

  /// The imported wrapper whose children stand in for the list's roots, when
  /// it is still the list's only root. Mirrors
  /// `WorkspaceStore.visibleRootParentTaskID(for:)`.
  public func visibleRootParentTaskID(registeredRootId: String?) -> String? {
    guard let registeredRootId else { return nil }
    let roots = children(of: nil)
    guard roots.count == 1, roots.first?.id == registeredRootId else { return nil }
    return registeredRootId
  }

  /// The open, doable tasks this list contributes to a combined scope.
  public func actionableTasks(visibleRootTaskId: String?) -> [WorkspaceTask] {
    let items = outline().map(\.task)
    let inactive = WorkspaceStore.inactiveContainerItems(items)
    return items.filter {
      !$0.isList && $0.id != visibleRootTaskId && !inactive.contains($0.id) && $0.status == .open
    }
  }

  static func hidingArchivedLists(_ items: [TaskOutlineItem]) -> [TaskOutlineItem] {
    var archivedDepth: Int?
    return items.filter { item in
      if let depth = archivedDepth, item.depth <= depth { archivedDepth = nil }
      if archivedDepth != nil { return false }
      if item.task.isList && item.task.archivedAt != nil { archivedDepth = item.depth; return false }
      return true
    }
  }
}

/// What the sidebar draws beneath its lists: the nested lists, the archived
/// ones the restore menu offers, and each list's task count.
public struct WorkspaceSidebarIndex: Sendable, Equatable {
  public var nestedLists: [TaskOutlineItem]
  public var archivedNestedLists: [WorkspaceTask]
  public var taskCounts: [String: Int]

  public init(nestedLists: [TaskOutlineItem], archivedNestedLists: [WorkspaceTask], taskCounts: [String: Int]) {
    self.nestedLists = nestedLists
    self.archivedNestedLists = archivedNestedLists
    self.taskCounts = taskCounts
  }

  /// Walks each list in the order given. A nested list's depth counts only the
  /// lists above it, not the tasks, and one beneath an archived list is hidden
  /// with it.
  public init(lists: [TaskList], trees: [String: WorkspaceListTree]) {
    var nested: [TaskOutlineItem] = []
    var archived: [WorkspaceTask] = []
    var counts: [String: Int] = [:]
    for list in lists {
      let items = trees[list.id]?.outline() ?? []
      counts[list.id] = items.count
      var ancestors: [TaskOutlineItem] = []
      for item in items {
        while let last = ancestors.last, last.depth >= item.depth { ancestors.removeLast() }
        if item.task.isList && item.id != list.visibleRootTaskId {
          if item.task.archivedAt != nil { archived.append(item.task) }
          if item.task.archivedAt == nil
            && !ancestors.contains(where: { $0.task.isList && $0.task.archivedAt != nil }) {
            let depth = ancestors.filter { $0.task.isList && $0.id != list.visibleRootTaskId }.count
            nested.append(TaskOutlineItem(task: item.task, depth: depth))
          }
        }
        ancestors.append(item)
      }
    }
    self.init(nestedLists: nested, archivedNestedLists: archived, taskCounts: counts)
  }
}

/// What a board draws beneath its cards: each card's whole subtree, and every
/// task's parent, from one walk of the lists' trees already in memory.
///
/// A subtree is keyed for every task *inside* a card's tree as well as for the
/// card itself. A subtask filed under a different column from its parent is
/// surfaced as a card of its own, and it used to find no entry here — so its
/// tree was read from the store once per card, inside the view body, instead
/// of coming out of the same pass as everyone else's.
public struct WorkspaceBoardTrees: Sendable, Equatable {
  /// Depth-first beneath each task, depths counted from the task's own
  /// children (0), archived nested lists and their contents left out.
  public var descendants: [String: [TaskOutlineItem]]
  public var parents: [String: WorkspaceTask]

  public init(cardIDs: Set<String>, trees: [WorkspaceListTree]) {
    var descendants: [String: [TaskOutlineItem]] = Dictionary(uniqueKeysWithValues: cardIDs.map { ($0, []) })
    var parents: [String: WorkspaceTask] = [:]
    for tree in trees {
      var ancestors: [TaskOutlineItem] = []
      for item in tree.visibleOutline() {
        while let last = ancestors.last, last.depth >= item.depth { ancestors.removeLast() }
        if let parent = ancestors.last { parents[item.id] = parent.task }
        // Keyed ancestors are closed downwards, so only the nearest one
        // decides whether this task sits inside a card's tree.
        let insideCard = ancestors.last.map { descendants[$0.id] != nil } ?? false
        if insideCard {
          for ancestor in ancestors where descendants[ancestor.id] != nil {
            descendants[ancestor.id, default: []].append(
              TaskOutlineItem(task: item.task, depth: item.depth - ancestor.depth - 1))
          }
        }
        if insideCard && descendants[item.id] == nil { descendants[item.id] = [] }
        ancestors.append(item)
      }
    }
    self.descendants = descendants
    self.parents = parents
  }
}

extension WorkspaceStore {
  /// One list's rows, read once.
  public func listTree(in listId: String) throws -> WorkspaceListTree {
    try listTree(in: listId, using: core)
  }

  func listTree(in listId: String, using handle: CoreWorkspace) throws -> WorkspaceListTree {
    WorkspaceListTree(
      listId: listId,
      tasks: try PackedTaskRows.decode(Self.mappingCoreErrors { try handle.tasksInListsPacked(listIds: [listId]) }))
  }

  /// Several lists' rows in one read transaction, so a combined scope sees one
  /// consistent moment rather than one per list.
  public func listTrees(in listIds: [String]) throws -> [String: WorkspaceListTree] {
    guard !listIds.isEmpty else { return [:] }
    // One query for every list rather than one each: the sidebar asks for
    // all of them on every reload. Rows arrive in each list's order, so
    // grouping keeps it.
    let ids = Array(Set(listIds))
    var grouped: [String: [WorkspaceTask]] = Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
    // The Rust core's `records::tasks_in_lists`, packed: rows arrive in each
    // list's order, so grouping keeps it.
    for task in try PackedTaskRows.decode(Self.mappingCoreErrors { try core.tasksInListsPacked(listIds: ids) }) {
      grouped[task.listId, default: []].append(task)
    }
    return Dictionary(uniqueKeysWithValues: grouped.map { id, tasks in
      (id, WorkspaceListTree(listId: id, tasks: tasks))
    })
  }

  /// The sidebar's index for `lists`, walked in the Rust core
  /// (`sidebar::sidebar_index`) so only the nested lists and the counts cross
  /// rather than every task. The same answer as
  /// `WorkspaceSidebarIndex(lists:trees:)` over every list's tree.
  public func sidebarIndex(lists: [TaskList]) throws -> WorkspaceSidebarIndex {
    guard !lists.isEmpty else { return WorkspaceSidebarIndex(nestedLists: [], archivedNestedLists: [], taskCounts: [:]) }
    let index = try Self.mappingCoreErrors { try core.sidebarIndex(listIds: lists.map(\.id)) }
    return WorkspaceSidebarIndex(
      nestedLists: index.nestedLists.map(TaskOutlineItem.init),
      archivedNestedLists: index.archivedNestedLists.map(WorkspaceTask.init),
      taskCounts: Dictionary(index.taskCounts.map { ($0.listId, Int($0.count)) }, uniquingKeysWith: { first, _ in first }))
  }

  public func tasks(ids: [String]) throws -> [String: WorkspaceTask] {
    guard !ids.isEmpty else { return [:] }
    let rows = try Self.mappingCoreErrors { try core.tasksById(ids: Array(Set(ids))) }
    return Dictionary(rows.map { ($0.id, WorkspaceTask($0)) }, uniquingKeysWith: { first, _ in first })
  }
}
