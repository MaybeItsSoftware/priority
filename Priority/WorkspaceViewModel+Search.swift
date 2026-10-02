import Foundation
import PriorityWorkspace

/// Searching the workspace. Split from `WorkspaceViewModel.swift` — the same
/// type — because the query, its results, and where a result leads are a
/// self-contained piece of state the rest of the workspace does not read.
@MainActor
extension WorkspaceViewModel {
  func presentSearch() {
    leaveFullPaneScreens()
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

  /// Goes to a result: its list, in a view that can actually show it.
  ///
  /// The outline rather than the board, because a board shows one level of one
  /// parent and a hit can be at any depth — landing on a view where the task
  /// is not visible would be a worse answer than not searching at all.
  func reveal(_ result: TaskSearchResult) {
    dismissOverlay(restoringFocus: false)
    batchingRefreshes {
      if result.list.id != selectedListID || isEverythingSelected {
        selectList(result.list.id)
      }
      scopeTaskID = nil
      viewMode = .outline
      reloadOutline(refreshSidebar: false)
    }
    unfoldAncestors(of: result.task)
    selectedTaskID = result.task.id
    requestKeyboardFocus(.tasks)
  }
}
