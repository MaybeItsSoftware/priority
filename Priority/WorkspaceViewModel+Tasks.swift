import Foundation
import PriorityCore
import PriorityWorkspace

/// Creating, placing and classifying tasks: the outline's own writes, the
/// board's columns, and the matrix's coordinates. Split from
/// `WorkspaceViewModel.swift` for size — it is the same type, and these are
/// the methods a view calls when it wants a task to exist or to move.
@MainActor
extension WorkspaceViewModel {
  func createTask(named title: String) {
    if taskInsertionReference != nil { createRelativeTask(named: title); return }
    guard let store,
      let destinationID = isMultiListScope ? (folderScopeDestinationID ?? newTaskListID) : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return }
    perform {
      let parentID = isMultiListScope
        ? try visibleRootParentTaskID(for: destinationList, store: store) : scopeTaskID
      let task = try store.createTask(listId: destinationID, title: title, parentTaskId: parentID)
      selectedTaskID = task.id
      reloadOutline()
    }
  }

  private func createRelativeTask(named title: String) {
    guard let store, let reference = taskInsertionReference else { return }
    perform {
      let task = try store.createTask(listId: reference.listId, title: title,
        parentTaskId: taskInsertionIsChild ? reference.id : reference.parentTaskId,
        kanbanColumn: viewMode == .board ? column(for: reference)?.id : nil,
        adjacentTaskId: taskInsertionIsChild ? nil : reference.id, above: taskInsertionAbove)
      if taskInsertionIsChild { scopeTaskID = reference.id }
      selectedTaskID = task.id
      taskInsertionReference = task
      taskInsertionAbove = false
      taskInsertionIsChild = false
      reloadOutline()
    }
  }

  /// Creates work in the currently visible board scope. This differs from the
  /// outline only for a transparent imported root project (see
  /// `boardParentTaskID`), where a new card belongs alongside the visible
  /// children rather than appearing above them as a second wrapper.
  func createBoardTask(named title: String, in column: WorkspaceKanbanColumn? = nil, atTop: Bool = false) {
    if column == nil && taskInsertionReference != nil { createRelativeTask(named: title); return }
    guard let store,
      let destinationID = isMultiListScope ? (folderScopeDestinationID ?? newTaskListID) : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return }
    let column = column ?? boardColumns.first { $0.id == activeBoardColumnID }
    perform {
      let parentID = isMultiListScope
        ? try visibleRootParentTaskID(for: destinationList, store: store) : boardParentTaskID
      let task = try store.createTask(listId: destinationID, title: title, parentTaskId: parentID,
        kanbanColumn: column?.id, atTop: atTop)
      selectedTaskID = task.id
      reloadOutline()
    }
  }

  func createSubtask(named title: String, under parent: WorkspaceTask) {
    guard let store else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    perform {
      _ = try store.createTask(listId: parent.listId, title: trimmed, parentTaskId: parent.id)
      reloadOutline()
    }
  }

  func descendants(of task: WorkspaceTask) -> [TaskOutlineItem] {
    _ = taskContentRevision
    if let cached = boardDescendants[task.id] { return cached }
    if let cached = descendantCache[task.id] { return cached }
    guard let store else { return [] }
    let items = (try? store.outline(in: task.listId, parentTaskId: task.id)) ?? []
    descendantCache[task.id] = items
    return items
  }

  func boardParent(of task: WorkspaceTask) -> WorkspaceTask? {
    boardTaskParents[task.id]
  }

  var currentBoardScopeTitle: String {
    if isEverythingSelected { return "Everything" }
    if let folder = scopedFolder { return folder.name }
    return scopeTask?.title ?? selectedList?.name ?? "Board"
  }

  func tasks(in column: WorkspaceKanbanColumn) -> [WorkspaceTask] {
    boardTasksByColumn[column.id, default: []]
  }

  var todayTasks: [WorkspaceTask] {
    guard let today = boardColumns.first(where: { $0.id == "today" }) else { return [] }
    return tasks(in: today).filter { $0.status == .open }
  }

  func isTaskVisibleOnBoard(_ task: WorkspaceTask) -> Bool {
    boardVisibleTaskIDs.contains(task.id)
  }

  func column(for task: WorkspaceTask) -> WorkspaceKanbanColumn? {
    let id = boardTaskColumns[task.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
    return boardColumnsByID[id] ?? boardColumns.first
  }

  func rebuildBoardIndex() {
    boardColumnsByID = Dictionary(boardColumns.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
    let tasks = boardTasks + boardCrossColumnTasks
    boardVisibleTaskIDs = Set(tasks.map(\.id))
    boardTasksByColumn = Dictionary(grouping: tasks) { task in
      column(for: task)?.id ?? ""
    }
  }

  func moveTask(_ task: WorkspaceTask, toKanbanColumn column: WorkspaceKanbanColumn) {
    guard let store else { return }
    perform {
      try store.setKanbanColumn(column.id, for: task.id)
      reloadBoard()
    }
  }

  func placeTask(_ task: WorkspaceTask, before target: WorkspaceTask) {
    guard let store, task.id != target.id else { return }
    guard task.listId == target.listId, task.parentTaskId == target.parentTaskId else {
      errorMessage = "To reorder these cards, they must be siblings in the same project. Drag to a column or list to move them."
      return
    }
    perform {
      try store.moveTaskBefore(id: task.id, targetId: target.id, kanbanColumn: column(for: target)?.id)
      reloadBoard()
    }
  }

  func addKanbanColumn(named name: String) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    guard let store else { return }
    var columns = boardColumns
    let baseID = title.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let id = uniqueColumnID(base: baseID.isEmpty ? "column" : baseID, in: columns)
    columns.append(WorkspaceKanbanColumn(id: id, title: title))
    perform {
      try store.setKanbanBoardColumns(columns, for: boardConfigurationKey, label: "Add Board Column")
      reloadOutline()
    }
  }

  func removeKanbanColumn(_ column: WorkspaceKanbanColumn) {
    guard boardColumns.count > 1 else { return }
    let fallback = boardColumns.first { $0.id != column.id } ?? WorkspaceKanbanColumn.blitzitDefaults[0]
    guard let store else { return }
    let remaining = boardColumns.filter { $0.id != column.id }
    perform {
      try store.setKanbanBoardColumns(remaining, for: boardConfigurationKey,
        movingTaskIDs: tasks(in: column).map(\.id), toColumn: fallback.id, label: "Remove Board Column")
      reloadOutline()
    }
  }

  func matrixPosition(for task: WorkspaceTask) -> TaskMatrixPosition {
    matrixPositions[task.id] ?? TaskMatrixPosition(urgency: nil, importance: nil)
  }

  func setMatrixPosition(_ position: TaskMatrixPosition, for task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setMatrixPosition(position, for: task.id)
      reloadBoard()
    }
  }
}
