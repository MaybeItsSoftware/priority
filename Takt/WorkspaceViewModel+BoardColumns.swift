import Foundation
import TaktCore
import TaktWorkspace

/// A board column's rules sheet: which column, and the rules it opens with.
struct WorkspaceBoardColumnRulesRequest: Identifiable {
  let id = UUID()
  let columnID: String
  let title: String
  let rules: WorkspaceFilterDefinition?
}

/// Editing the board's columns: adding one beside another, renaming, moving,
/// deleting with somewhere for its tasks to go, a column's rules, and the
/// workspace's default columns.
///
/// Every edit goes through the core (`board_columns.rs`), which keeps each
/// board's layout — a list's, an entered card's, Everything's — and the
/// default a board without one follows. A board following its list's or the
/// default columns gets a layout of its own on its first edit.
extension WorkspaceViewModel {
  /// The layout an edit saves: the board's columns, the ones an entered card
  /// hides included, plus any drawn only because a card here is filed in it.
  var editableBoardColumns: [WorkspaceKanbanColumn] {
    let layout = boardColumnRead?.layout ?? boardColumns
    return layout + boardColumns.filter { column in !layout.contains { $0.id == column.id } }
  }

  /// Where the board's columns come from, for the header menu.
  var boardColumnSource: WorkspaceBoardColumns.Source { boardColumnRead?.source ?? .builtin }

  /// The column the palette's column commands act on: the one the keyboard
  /// is in, else the first.
  var commandBoardColumn: WorkspaceKanbanColumn? {
    activeBoardColumnID.flatMap { id in boardColumns.first { $0.id == id } }
  }

  // MARK: - Adding

  /// Asks for a column's name, to add it beside `anchorID` — or last.
  func requestNewBoardColumn(beside anchorID: String? = nil, after: Bool = true) {
    pendingColumnInsertion = anchorID.map { (anchorID: $0, after: after) }
    presentOverlay(.newBoardColumn)
  }

  func addKanbanColumn(named name: String) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let insertion = pendingColumnInsertion
    pendingColumnInsertion = nil
    guard !title.isEmpty, store != nil else { return }
    var columns = editableBoardColumns
    let id = WorkspaceKanbanColumn.newID(title: title, among: columns)
    let column = WorkspaceKanbanColumn(id: id, title: title)
    if let insertion, let index = columns.firstIndex(where: { $0.id == insertion.anchorID }) {
      columns.insert(column, at: insertion.after ? index + 1 : index)
    } else {
      columns.append(column)
    }
    saveBoardColumns(columns, label: "Add Board Column")
    focusedBoardColumnID = id
  }

  // MARK: - Renaming and moving

  func requestRenameBoardColumn(_ column: WorkspaceKanbanColumn) {
    presentOverlay(.renameBoardColumn(column.id))
  }

  func renameKanbanColumn(_ columnID: String, to name: String) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var columns = editableBoardColumns
    guard !title.isEmpty, let index = columns.firstIndex(where: { $0.id == columnID }),
      columns[index].title != title
    else { return }
    columns[index].title = title
    saveBoardColumns(columns, label: "Rename Board Column")
  }

  /// Moves a column past its neighbour on screen. A column an entered card
  /// hides is stepped over, since nothing on screen says it is there.
  func moveKanbanColumn(_ columnID: String, by offset: Int) {
    guard let visibleIndex = boardColumns.firstIndex(where: { $0.id == columnID }) else { return }
    let neighbourIndex = visibleIndex + offset
    guard boardColumns.indices.contains(neighbourIndex) else { return }
    let neighbourID = boardColumns[neighbourIndex].id
    var columns = editableBoardColumns
    guard let from = columns.firstIndex(where: { $0.id == columnID }) else { return }
    let moving = columns.remove(at: from)
    guard let neighbour = columns.firstIndex(where: { $0.id == neighbourID }) else { return }
    columns.insert(moving, at: offset > 0 ? neighbour + 1 : neighbour)
    saveBoardColumns(columns, label: "Move Board Column")
  }

  func canMoveKanbanColumn(_ columnID: String, by offset: Int) -> Bool {
    guard let index = boardColumns.firstIndex(where: { $0.id == columnID }) else { return false }
    return boardColumns.indices.contains(index + offset)
  }

  // MARK: - Deleting

  /// Asks where the column's tasks go, then deletes it.
  func requestDeleteBoardColumn(_ column: WorkspaceKanbanColumn) {
    guard editableBoardColumns.count > 1 else {
      errorMessage = "A board keeps at least one column."
      return
    }
    presentOverlay(.deleteBoardColumn(column.id))
  }

  /// Whether deleting the column leaves its tasks where they are: a rule
  /// column holds nothing filed in it, and Today and Waiting on mean
  /// something beyond the board — their tasks stay planned or waiting.
  func boardColumnKeepsTasksWhenDeleted(_ column: WorkspaceKanbanColumn) -> Bool {
    column.isRuleColumn || column.isBuiltIn
  }

  /// Where a deleted column's tasks can go: the other columns that take
  /// filed tasks, on screen first.
  func boardColumnDeletionTargets(for columnID: String) -> [WorkspaceKanbanColumn] {
    editableBoardColumns.filter { $0.id != columnID && !$0.isRuleColumn }
  }

  /// Deletes a column as one undo step, its filed tasks moving to `target`.
  func deleteKanbanColumn(_ columnID: String, movingTasksTo target: String?) {
    guard let store else { return }
    let key = boardConfigurationKey
    let listIDs = boardScopeListIDs
    let inLayout = boardColumnRead?.layout.contains { $0.id == columnID } ?? false
    let drawnHere = boardColumnsByID[columnID].map { tasks(in: $0).map(\.id) } ?? []
    perform {
      if inLayout {
        try store.deleteBoardColumn(key: key, listIDs: listIDs, columnID: columnID, toColumn: target)
      } else {
        // A column drawn only because a card is filed in it: there is no
        // layout entry to delete, so its cards are refiled.
        try store.setKanbanColumn(target, for: drawnHere)
      }
      if focusedBoardColumnID == columnID { focusedBoardColumnID = target }
      reloadOutline()
    }
  }

  // MARK: - Rules

  func requestEditBoardColumnRules(_ column: WorkspaceKanbanColumn) {
    boardColumnRulesEditor = WorkspaceBoardColumnRulesRequest(
      columnID: column.id, title: column.title, rules: column.rules)
  }

  /// Gives a column rules, or with nil makes it an ordinary column again.
  func setBoardColumnRules(_ columnID: String, rules: WorkspaceFilterDefinition?) throws {
    guard let store else { return }
    var columns = editableBoardColumns
    guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
    let tidy = try rules.map { try $0.validated() }
    columns[index].rules = tidy.flatMap { $0.rules.isEmpty ? nil : $0 }
    try store.setKanbanBoardColumns(
      columns, for: boardConfigurationKey, label: columns[index].rules == nil ? "Clear Column Rules" : "Edit Column Rules")
    reloadOutline()
  }

  // MARK: - Defaults

  /// Makes this board's columns the ones every board without its own uses.
  func makeBoardColumnsDefault() {
    guard let store else { return }
    let key = boardConfigurationKey
    perform {
      try store.makeDefaultBoardColumns(key: key)
      reloadOutline()
    }
  }

  /// Drops this board's own columns, so it follows its list's or the default.
  func resetBoardColumnsToDefault() {
    guard let store, boardColumnSource == .own else { return }
    let key = boardConfigurationKey
    perform {
      try store.resetBoardColumns(key: key)
      reloadOutline()
    }
  }

  private func saveBoardColumns(_ columns: [WorkspaceKanbanColumn], label: String) {
    guard let store else { return }
    let key = boardConfigurationKey
    perform {
      try store.setKanbanBoardColumns(columns, for: key, label: label)
      reloadOutline()
    }
  }
}
