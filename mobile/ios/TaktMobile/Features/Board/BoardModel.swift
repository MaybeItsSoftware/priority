import Foundation
import Observation
import TaktCore
import TaktWorkspace

/// One card on the board. A value, so a column redraws only the cards whose
/// content changed.
struct BoardCard: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let status: TaskStatus
  let isList: Bool
  let isPromoted: Bool
  let listID: String
  let parentID: String?
  let dueAt: Date?
  let estimateSeconds: Int?
  let isPlanned: Bool
  /// The list's name, in a combined scope.
  let listName: String?
  /// For a subtask filed in a different column from its parent's card: the
  /// parent's title, so the card says where it hangs from.
  let parentTitle: String?
  /// Every level beneath the card, depths from the card's own children (0).
  let subtasks: [TaskOutlineItem]

  var menuContext: TaskMenuContext {
    TaskMenuContext(
      taskID: id, title: title, status: status, isList: isList, isPromoted: isPromoted, isPlanned: isPlanned,
      allowsStructure: false)
  }
}

/// What the board reads for a scope: its columns and the cards in each.
struct BoardSnapshot: Equatable, Sendable {
  var columns: [WorkspaceKanbanColumn] = WorkspaceKanbanColumn.blitzitDefaults
  /// Cards by column id, in sibling order. Every column in `columns` has an
  /// entry, possibly empty.
  var cards: [String: [BoardCard]] = [:]
  /// Matrix placement for every card on the board, read in the same batch.
  var positions: [String: TaskMatrixPosition] = [:]

  var allCards: [BoardCard] { columns.flatMap { cards[$0.id] ?? [] } }

  func column(ofCard id: String) -> WorkspaceKanbanColumn? {
    columns.first { column in cards[column.id]?.contains { $0.id == id } == true }
  }

  /// Reads the board for a scope, the way the Mac does: one `scopeRead`
  /// shaped by `WorkspaceScopeShaping.board`, so a combined scope's cards and
  /// trees are walked in the Rust core (`board::combined_board`) and only the
  /// rows the board draws cross. A list's visible top level (or a nested
  /// list's children) are the cards; a combined scope shows its actionable
  /// tasks. A subtask nobody filed follows its parent's column; one filed
  /// elsewhere shows as a card of its own there. Safe off the main actor.
  static func load(
    store: WorkspaceStore, workspaceID: String, scope: ListScope, structure: WorkspaceStructure,
    hidesCompleted: Bool, now: Date = .now
  ) throws -> BoardSnapshot {
    var options = WorkspaceScopeShapeOptions(
      scopeTaskID: nil, registeredRootTaskID: nil, hidesCompletedTasks: hidesCompleted)
    let open = structure.lists.filter { $0.completedAt == nil }.map(\.id)
    let read: WorkspaceScopeRead
    let cutoff = hidesCompleted ? now : nil
    switch scope {
    case .everything:
      read = try store.scopeRead(.combined(open), hidingCompletedBefore: cutoff)
    case .folder(let folderID):
      let openIDs = Set(open)
      read = try store.scopeRead(
        .combined(structure.listIDs(inFolder: folderID).filter { openIDs.contains($0) }),
        hidingCompletedBefore: cutoff)
    case .list(let listID):
      options.registeredRootTaskID = structure.list(listID)?.visibleRootTaskId
      read = try store.scopeRead(.list(listID), hidingCompletedBefore: cutoff)
    case .nested(let listID, let taskID):
      options.scopeTaskID = taskID
      read = try store.scopeRead(.list(listID), hidingCompletedBefore: cutoff)
    }
    // The phone hides a finished task at once rather than letting it linger.
    let board = WorkspaceScopeShaping.board(read, options: options, now: .distantFuture).board
    let filed = board.columns
    let tasksByID = Dictionary(board.treeTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let cardIDs = Set(board.cards.map(\.id))

    var snapshot = BoardSnapshot()
    snapshot.columns = try resolvedColumns(
      store: store, scope: scope, structure: structure, usedColumnIDs: Set(filed.values))
    snapshot.positions = board.positions
    let fallbackID = WorkspaceKanbanColumn.blitzitDefaults[0].id
    let columnIDs = Set(snapshot.columns.map(\.id))
    let firstColumn = snapshot.columns.first?.id ?? fallbackID
    let listNames = scope.isSingleTree
      ? [:] : Dictionary(structure.lists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    for column in snapshot.columns { snapshot.cards[column.id] = [] }
    for task in board.cards + board.crossColumnTasks {
      let wanted = filed[task.id] ?? fallbackID
      let column = columnIDs.contains(wanted) ? wanted : firstColumn
      let isCross = !cardIDs.contains(task.id)
      snapshot.cards[column, default: []].append(BoardCard(
        id: task.id, title: task.title, status: task.status, isList: task.isList,
        isPromoted: task.isPromoted == true, listID: task.listId, parentID: task.parentTaskId, dueAt: task.dueAt,
        estimateSeconds: task.estimateSeconds, isPlanned: filed[task.id] == NextUpSelector.todayColumnID,
        listName: listNames[task.listId],
        parentTitle: isCross ? board.parents[task.id].flatMap { tasksByID[$0]?.title } : nil,
        subtasks: board.descendants[task.id] ?? []))
    }
    return snapshot
  }

  /// The scope's own layout, plus any column a card here is filed under that
  /// the layout does not list — so nothing filed elsewhere disappears.
  static func resolvedColumns(
    store: WorkspaceStore, scope: ListScope, structure: WorkspaceStructure, usedColumnIDs: Set<String>
  ) throws -> [WorkspaceKanbanColumn] {
    let configurations = try store.kanbanBoardConfigurations(legacy: [:], currentKey: scope.boardKey)
    func decode(_ key: String) -> [WorkspaceKanbanColumn]? {
      configurations[key].flatMap { try? JSONDecoder().decode([WorkspaceKanbanColumn].self, from: $0) }
    }
    var columns = decode(scope.boardKey).flatMap { $0.isEmpty ? nil : $0 } ?? WorkspaceKanbanColumn.blitzitDefaults
    let extras: [WorkspaceKanbanColumn]
    if scope == .everything {
      extras = structure.lists.flatMap { decode("\($0.id)/root") ?? [] }
    } else {
      extras = (decode("everything/root") ?? []) + WorkspaceKanbanColumn.blitzitDefaults
    }
    for column in extras where usedColumnIDs.contains(column.id) && !columns.contains(where: { $0.id == column.id }) {
      columns.append(column)
    }
    return columns
  }
}

/// A board for one scope: its snapshot, its folds, and its column edits.
@MainActor
@Observable
final class BoardModel {
  let scope: ListScope
  private(set) var snapshot = BoardSnapshot()
  private(set) var isLoaded = false
  /// The column whose inline add field is open.
  var composingColumnID: String?
  var composerText = ""

  /// Shared with the outline: a branch folded in one view stays folded in
  /// the other, as on the Mac.
  var folded: Set<String> {
    didSet {
      guard folded != oldValue else { return }
      UserDefaults.standard.set(Array(folded).sorted(), forKey: foldKey)
    }
  }

  @ObservationIgnored private var generation = 0
  private var foldKey: String { "outlineFolds.\(scope.storageKey)" }

  /// How many subtask rows a card draws before "+N more", as on the Mac.
  static let visibleSubtaskRows = 12

  init(scope: ListScope) {
    self.scope = scope
    folded = Set(UserDefaults.standard.stringArray(forKey: "outlineFolds.\(scope.storageKey)") ?? [])
  }

  func load(_ model: WorkspaceModel) async {
    generation &+= 1
    let mine = generation
    let store = model.store
    let workspaceID = model.workspace.id
    let structure = model.structure
    let scope = scope
    let hides = UserDefaults.standard.bool(forKey: "outlineHidesCompleted")
    let result = await Task.detached(priority: .userInitiated) {
      try? BoardSnapshot.load(
        store: store, workspaceID: workspaceID, scope: scope, structure: structure, hidesCompleted: hides)
    }.value
    guard mine == generation, let result else { return }
    if snapshot != result { snapshot = result }
    isLoaded = true
  }

  var columns: [WorkspaceKanbanColumn] { snapshot.columns }

  func cards(in columnID: String) -> [BoardCard] { snapshot.cards[columnID] ?? [] }

  // MARK: - Folding

  /// The subtask rows a card draws: none while it is folded, none beneath a
  /// folded subtask.
  func subtaskRows(of card: BoardCard) -> [TaskOutlineItem] {
    guard !folded.contains(card.id) else { return [] }
    return TaskOutlineFolding.visible(card.subtasks, folded: folded)
  }

  func subtaskParentIDs(of card: BoardCard) -> Set<String> {
    TaskOutlineFolding.parentIDs(card.subtasks)
  }

  func toggleFold(_ id: String) {
    if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
  }

  // MARK: - Moving cards

  func move(_ cardID: String, toColumn columnID: String, model: WorkspaceModel) {
    guard snapshot.column(ofCard: cardID)?.id != columnID else { return }
    if model.perform({ try $0.setKanbanColumn(columnID, for: cardID) }) {
      applyOptimisticMove(cardID, to: columnID, before: nil)
    }
  }

  /// A drop on a card: before it when they are siblings, otherwise just into
  /// its column — cards from different projects cannot be ordered together.
  func move(_ cardID: String, before targetID: String, model: WorkspaceModel) {
    guard cardID != targetID, let column = snapshot.column(ofCard: targetID) else { return }
    let card = snapshot.allCards.first { $0.id == cardID }
    let target = snapshot.allCards.first { $0.id == targetID }
    if let card, let target, card.listID == target.listID, card.parentID == target.parentID {
      if model.perform({ try $0.moveTaskBefore(id: cardID, targetId: targetID, kanbanColumn: column.id) }) {
        applyOptimisticMove(cardID, to: column.id, before: targetID)
      }
    } else {
      move(cardID, toColumn: column.id, model: model)
    }
  }

  func moveToAdjacentColumn(_ cardID: String, by offset: Int, model: WorkspaceModel) {
    guard let current = snapshot.column(ofCard: cardID),
      let index = columns.firstIndex(where: { $0.id == current.id })
    else { return }
    let destination = min(max(0, index + offset), columns.count - 1)
    guard destination != index else { return }
    move(cardID, toColumn: columns[destination].id, model: model)
  }

  /// Moves the card in the snapshot straight away, so a drop lands where it
  /// was dropped rather than snapping back until the re-read arrives.
  private func applyOptimisticMove(_ cardID: String, to columnID: String, before targetID: String?) {
    var cards = snapshot.cards
    var moved: BoardCard?
    for key in cards.keys {
      if let index = cards[key]?.firstIndex(where: { $0.id == cardID }) {
        moved = cards[key]?.remove(at: index)
      }
    }
    guard let moved else { return }
    var destination = cards[columnID] ?? []
    if let targetID, let index = destination.firstIndex(where: { $0.id == targetID }) {
      destination.insert(moved, at: index)
    } else {
      destination.append(moved)
    }
    cards[columnID] = destination
    snapshot.cards = cards
  }

  // MARK: - Columns

  @discardableResult
  func addColumn(named name: String, model: WorkspaceModel) -> WorkspaceKanbanColumn? {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    let base = title.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let column = WorkspaceKanbanColumn(id: Self.uniqueColumnID(base: base.isEmpty ? "column" : base, in: columns), title: title)
    let updated = columns + [column]
    guard model.perform({ try $0.setKanbanBoardColumns(updated, for: scope.boardKey, label: "Add Board Column") })
    else { return nil }
    snapshot.columns = updated
    snapshot.cards[column.id] = []
    return column
  }

  func renameColumn(_ columnID: String, to name: String, model: WorkspaceModel) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    let updated = columns.map { $0.id == columnID ? WorkspaceKanbanColumn(id: $0.id, title: title) : $0 }
    guard updated != columns else { return }
    if model.perform({ try $0.setKanbanBoardColumns(updated, for: scope.boardKey, label: "Rename Board Column") }) {
      snapshot.columns = updated
    }
  }

  /// Removes a column, moving its cards into the first remaining column in
  /// the same undo step. The last column cannot go.
  func removeColumn(_ columnID: String, model: WorkspaceModel) {
    guard columns.count > 1 else { return }
    let remaining = columns.filter { $0.id != columnID }
    guard let fallback = remaining.first else { return }
    let moving = cards(in: columnID).map(\.id)
    model.perform {
      try $0.setKanbanBoardColumns(
        remaining, for: scope.boardKey, movingTaskIDs: moving, toColumn: fallback.id, label: "Remove Board Column")
    }
  }

  /// Moves a column one place left or right.
  func moveColumn(_ columnID: String, by offset: Int, model: WorkspaceModel) {
    guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
    let destination = index + offset
    guard columns.indices.contains(destination) else { return }
    var updated = columns
    updated.swapAt(index, destination)
    if model.perform({ try $0.setKanbanBoardColumns(updated, for: scope.boardKey, label: "Move Board Column") }) {
      snapshot.columns = updated
    }
  }

  static func uniqueColumnID(base: String, in columns: [WorkspaceKanbanColumn]) -> String {
    guard columns.contains(where: { $0.id == base }) else { return base }
    var counter = 2
    while columns.contains(where: { $0.id == "\(base)-\(counter)" }) { counter += 1 }
    return "\(base)-\(counter)"
  }

  // MARK: - Adding cards

  /// Files a card in a column. In a combined scope it lands in the Inbox.
  @discardableResult
  func addCard(_ text: String, toColumn columnID: String, model: WorkspaceModel) -> WorkspaceTask? {
    let parent: String?
    let listID: String?
    switch scope {
    case .list(let id):
      listID = id
      parent = model.structure.list(id)?.visibleRootTaskId.flatMap { root in
        (try? model.store.listTree(in: id))?.visibleRootParentTaskID(registeredRootId: root)
      }
    case .nested(let id, let taskID):
      listID = id
      parent = taskID
    case .everything, .folder:
      listID = model.inbox?.id
      parent = nil
    }
    guard let listID else { return nil }
    return model.createTask(text, listID: listID, parentTaskID: parent, kanbanColumn: columnID)
  }
}
