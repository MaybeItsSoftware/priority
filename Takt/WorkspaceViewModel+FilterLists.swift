import Foundation
import TaktCore
import TaktWorkspace

/// What the filter list sheet is editing: a new filter list, or one of yours.
struct WorkspaceFilterListEditorRequest: Identifiable {
  let id = UUID()
  /// Nil for a new filter list.
  let existing: WorkspaceFilterList?
}

/// Filter lists on the desktop: saved rule sets over every task, drawn as a
/// narrowing of Everything.
///
/// A filter list is not somewhere tasks live, so it is not a scope of its own
/// kind. It is Everything with a question asked of each task — the core
/// answers it (`core/src/filter_lists.rs`) and hands back Everything's board
/// with only the matches as cards — so the board, the outline and the matrix,
/// the per-task list badges and the destination for new tasks all come from
/// Everything unchanged. `selectedFilterListID` is only ever set while
/// `isEverythingSelected` is.
@MainActor
extension WorkspaceViewModel {
  /// The sidebar row id of a filter list.
  nonisolated static func filterListSidebarID(_ id: String) -> String { "filter:\(id)" }

  /// The filter list in scope, if Everything is narrowed to one.
  var selectedFilterList: WorkspaceFilterList? {
    guard isEverythingSelected, let selectedFilterListID else { return nil }
    return filterLists.first { $0.id == selectedFilterListID }
  }

  /// Whether the pane leaves finished tasks out. A filter list that asks for
  /// finished work shows it whatever the toggle says: hiding it would empty
  /// the list it was made to show.
  var scopeHidesCompletedTasks: Bool {
    guard let filter = selectedFilterList else { return hidesCompletedTasks }
    return filter.definition.hidesCompleted(whenToggled: hidesCompletedTasks)
  }

  /// Puts a filter list in scope and draws it. The mode follows
  /// Everything's: the board unless you are already in one that can show
  /// where a task came from.
  func selectFilterList(_ filter: WorkspaceFilterList) {
    sidebarCursorID = nil
    taskEditor.flush()
    if let selectedListID { newTaskListID = selectedListID }
    enterEverythingScope(filterListID: filter.id)
    switchScope("Select filter list") {
      if viewMode == .today { viewMode = .board }
      reloadOutline(refreshSidebar: false)
    }
  }

  func requestNewFilterList() {
    filterListEditor = WorkspaceFilterListEditorRequest(existing: nil)
  }

  func requestEditFilterList(_ filter: WorkspaceFilterList) {
    filterListEditor = WorkspaceFilterListEditorRequest(existing: filter)
  }

  /// Edits the filter list in scope, or starts a new one when none is.
  func editSelectedFilterListOrCreate() {
    if let filter = selectedFilterList {
      requestEditFilterList(filter)
    } else {
      requestNewFilterList()
    }
  }

  /// Saves the sheet: creates a filter list and opens it, or updates one.
  /// Throws what the core refused, for the sheet to show.
  @discardableResult
  func saveFilterList(
    _ request: WorkspaceFilterListEditorRequest, name: String, icon: String?,
    definition: WorkspaceFilterDefinition
  ) throws -> WorkspaceFilterList {
    guard let store, let workspace else { throw WorkspaceStoreError.missingFilterList }
    let saved: WorkspaceFilterList
    if let existing = request.existing {
      saved = try store.updateFilterList(
        existing.id, name: name, icon: icon, colorHex: existing.colorHex, definition: definition, now: Date())
    } else {
      saved = try store.createFilterList(
        in: workspace.id, name: name, icon: icon, colorHex: nil, definition: definition, now: Date())
    }
    perform { try load() }
    if request.existing == nil || selectedFilterListID == saved.id {
      selectFilterList(saved)
    }
    return saved
  }

  /// Deletes a filter list. Nothing is lost but the question — no task
  /// lived in it — and it is one undo step, so it asks no confirmation.
  func deleteFilterList(_ filter: WorkspaceFilterList) {
    guard let store else { return }
    let wasSelected = selectedFilterListID == filter.id
    perform {
      try store.deleteFilterList(filter.id)
      try load()
    }
    if wasSelected { selectEverything() }
  }

  func renameFilterList(_ filter: WorkspaceFilterList, to name: String) {
    guard let store else { return }
    perform {
      try store.renameFilterList(filter.id, to: name, now: Date())
      try load()
    }
  }

  /// Moves a filter list to `index` among yours.
  func moveFilterList(_ filter: WorkspaceFilterList, to index: Int) {
    guard let store, index >= 0, index < filterLists.count else { return }
    perform {
      try store.moveFilterList(filter.id, to: index, now: Date())
      try load()
    }
  }

  /// Gives a filter list another icon, keeping its name and rules.
  func setIcon(_ symbol: String, for filter: WorkspaceFilterList) {
    guard let store, filter.icon != symbol else { return }
    perform {
      _ = try store.updateFilterList(
        filter.id, name: filter.name, icon: symbol, colorHex: filter.colorHex, definition: filter.definition,
        now: Date())
      try load()
    }
  }
}

extension WorkspaceFilterList {
  /// The icons a filter list can wear: the filter's own glyph first, then
  /// what the questions people ask most often look like.
  static let iconOptions: [(symbol: String, label: String)] = [
    (defaultIcon, "Filter"), ("sun.max", "Today"), ("calendar", "Calendar"),
    ("clock", "Soon"), ("exclamationmark.circle", "Urgent"), ("flag", "Flagged"),
    ("tag", "Tag"), ("star", "Starred"), ("bolt", "Quick"), ("hourglass", "Waiting"),
    ("checkmark.circle", "Done"), ("briefcase", "Work"), ("house", "Home"),
    ("person.2", "People"), ("lightbulb", "Ideas"), ("tray.full", "Everything"),
  ]
}
