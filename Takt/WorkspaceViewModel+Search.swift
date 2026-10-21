import Foundation
import TaktWorkspace

/// Searching the workspace. Split from `WorkspaceViewModel.swift` — the same
/// type — because the query, its results, and where a result leads are a
/// self-contained piece of state the rest of the workspace does not read.
@MainActor
extension WorkspaceViewModel {
  func presentSearch() {
    searchQuery = ""
    searchResults = []
    selectedSearchResultID = nil
    presentOverlay(.search)
  }

  /// Re-runs the query. Called from the query and filter bindings rather than
  /// on a timer: the search is a local index read, so there is nothing to
  /// debounce away.
  func refreshSearchResults() {
    guard let store, let workspace else {
      searchResults = []
      return
    }
    do {
      searchResults = try store.searchTasks(
        in: workspace.id, matching: searchQuery, includingCompleted: searchIncludesCompleted)
      // Keep the highlight on the same task while the list narrows around it.
      if selectedSearchResultID == nil || !searchResults.contains(where: { $0.id == selectedSearchResultID }) {
        selectedSearchResultID = searchResults.first?.id
      }
    } catch {
      searchResults = []
      errorMessage = error.localizedDescription
    }
  }

  /// A query answered without touching the sheet's own state.
  ///
  /// The summoned focus panel is a second window, and it can be up while the
  /// search sheet is open behind it. Sharing `searchQuery` between them would
  /// mean one wipes the other's results as you type.
  func searchResults(matching query: String, includingCompleted: Bool = false) -> [TaskSearchResult] {
    guard let store, let workspace else { return [] }
    return (try? store.searchTasks(
      in: workspace.id, matching: query, includingCompleted: includingCompleted)) ?? []
  }

  func moveSearchSelection(by offset: Int) {
    guard !searchResults.isEmpty else { return }
    let current = searchResults.firstIndex { $0.id == selectedSearchResultID } ?? 0
    let next = min(max(0, current + offset), searchResults.count - 1)
    selectedSearchResultID = searchResults[next].id
  }

  /// Goes to a result, in the mode you searched from.
  func reveal(_ result: TaskSearchResult) {
    dismissOverlay(restoringFocus: false)
    showInPlace(result.task)
  }

  /// `go`: the list the task belongs to, opened with the task selected.
  /// Unlike `showInPlace`, which leaves a task where it already shows, this
  /// always leaves Today, a filter list, Everything or a folder for the list.
  func goToTaskList(_ task: WorkspaceTask) {
    let isInItsList = task.listId == selectedListID && !isEverythingSelected
      && selectedFilterListID == nil && selectedFolderID == nil && viewMode != .today
    if !isInItsList { selectList(task.listId) }
    showInPlace(task)
  }

  /// Selects a task without changing the kind of view you are in, so a search
  /// from the board lands on the board.
  ///
  /// It used to switch to the outline every time, on the grounds that a board
  /// shows one level and a hit can be at any depth. But a board draws a card's
  /// subtasks on the card, and a jump that throws away the mode you chose is a
  /// jump you have to undo. So, in order: where you already are, if the task
  /// is on screen; its list, in the same mode; the level it sits at, on a
  /// board or matrix that only draws the top; and only then the outline, which
  /// can show anything — Today, say, for a task not planned for the day.
  ///
  /// - Parameters:
  ///   - fallsBackToOutline: false to leave the mode alone even when the task
  ///     cannot be drawn in it, selecting it all the same, as undo does.
  ///   - takesKeyboard: false to leave the keyboard where it is.
  ///   - revealsHidden: false to leave "hide completed", "hide buried" and
  ///     the folds alone — they are kept across launches, and undo has no
  ///     business changing them — selecting the task even if they hide it.
  func showInPlace(
    _ task: WorkspaceTask, fallsBackToOutline: Bool = true, takesKeyboard: Bool = true, revealsHidden: Bool = true
  ) {
    // Something ticked off is invisible in a view that hides completions.
    if revealsHidden, task.status != .open { hidesCompletedTasks = false }
    // And something buried, or under a buried task, in one hiding them.
    if revealsHidden, hidesLaterTasks, let store {
      var chain = [task.id]
      var parentID = task.parentTaskId
      while let id = parentID, !chain.contains(id) {
        chain.append(id)
        parentID = self.task(withID: id)?.parentTaskId
      }
      let now = Date()
      if let starts = try? store.boardMetadata(for: chain).starts, starts.values.contains(where: { $0 > now }) {
        hidesLaterTasks = false
      }
    }
    if revealsHidden { unfoldAncestors(of: task) }
    if !isShowing(task.id) {
      let mode = viewMode
      batchingRefreshes {
        if task.listId != selectedListID || isEverythingSelected { selectList(task.listId) }
        scopeTaskID = nil
        // Today has nothing to go back to in another list; the list's own
        // mode, as choosing it in the sidebar would give, is the answer there.
        if mode != .today { viewMode = mode }
        reloadOutline(refreshSidebar: false)
      }
      if revealsHidden { unfoldAncestors(of: task) }
    }
    if !isShowing(task.id), viewMode != .outline, let parent = task.parentTaskId {
      batchingRefreshes {
        scopeTaskID = parent
        reloadOutline(refreshSidebar: false)
      }
    }
    if fallsBackToOutline, !isShowing(task.id) {
      batchingRefreshes {
        scopeTaskID = nil
        viewMode = .outline
        reloadOutline(refreshSidebar: false)
      }
      unfoldAncestors(of: task)
    }
    selectedTaskID = task.id
    if takesKeyboard { requestKeyboardFocus(.tasks) }
  }

  /// Whether the task is drawn in the pane as it is now: a row the keys walk,
  /// or on the board a subtask row on one of its cards.
  func isShowing(_ id: String) -> Bool {
    if visibleNavigationTasks.contains(where: { $0.id == id }) { return true }
    return viewMode == .board && boardCardID(owning: id) != nil
  }
}
