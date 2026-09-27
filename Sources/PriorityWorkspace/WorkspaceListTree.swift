import Foundation
import GRDB

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

extension WorkspaceStore {
  /// One list's rows, read once.
  public func listTree(in listId: String) throws -> WorkspaceListTree {
    try database.read { db in try Self.listTree(db, listId: listId) }
  }

  /// Several lists' rows in one read transaction, so a combined scope sees one
  /// consistent moment rather than one per list.
  public func listTrees(in listIds: [String]) throws -> [String: WorkspaceListTree] {
    guard !listIds.isEmpty else { return [:] }
    return try database.read { db in
      var result: [String: WorkspaceListTree] = [:]
      for id in Set(listIds) { result[id] = try Self.listTree(db, listId: id) }
      return result
    }
  }

  /// Tasks by id, in one read. Missing ids are simply absent.
  public func tasks(ids: [String]) throws -> [String: WorkspaceTask] {
    guard !ids.isEmpty else { return [:] }
    return try database.read { db in
      var result: [String: WorkspaceTask] = [:]
      let unique = Array(Set(ids))
      for start in stride(from: 0, to: unique.count, by: 500) {
        let chunk = Array(unique[start..<min(start + 500, unique.count)])
        for task in try WorkspaceTask.filter(chunk.contains(Column("id"))).fetchAll(db) {
          result[task.id] = task
        }
      }
      return result
    }
  }

  static func listTree(_ db: Database, listId: String) throws -> WorkspaceListTree {
    let tasks = try WorkspaceTask.filter(Column("listId") == listId)
      .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
    return WorkspaceListTree(listId: listId, tasks: tasks)
  }
}
