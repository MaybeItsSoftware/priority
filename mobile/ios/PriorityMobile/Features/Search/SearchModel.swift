import Foundation
import Observation
import PriorityWorkspace

/// Full-text search over the workspace, through the store's FTS index.
///
/// Typing is debounced by the screen; each read runs off the main actor, and
/// a slower answer to an older query never replaces a newer one.
@MainActor
@Observable
final class SearchModel {
  var query = ""
  var includesCompleted = UserDefaults.standard.bool(forKey: "searchIncludesCompleted") {
    didSet { UserDefaults.standard.set(includesCompleted, forKey: "searchIncludesCompleted") }
  }
  private(set) var results: [TaskSearchResult] = []
  /// The query the current results answer, so "no matches" is only shown
  /// once the search for what is typed has actually come back.
  private(set) var searchedQuery = ""
  @ObservationIgnored private var generation = 0

  /// What the screen's `.task(id:)` is keyed on: the text, the toggle, and
  /// the workspace revision, so a write re-runs the search.
  struct Key: Hashable {
    let query: String
    let includesCompleted: Bool
    let revision: Int
  }

  func key(revision: Int) -> Key {
    Key(query: query, includesCompleted: includesCompleted, revision: revision)
  }

  var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  func search(store: WorkspaceStore, workspaceID: String) async {
    generation &+= 1
    let mine = generation
    let query = trimmedQuery
    let includes = includesCompleted
    guard !query.isEmpty else {
      results = []
      searchedQuery = ""
      return
    }
    let found = await Task.detached(priority: .userInitiated) {
      (try? store.searchTasks(in: workspaceID, matching: query, includingCompleted: includes)) ?? []
    }.value
    guard mine == generation else { return }
    if results != found { results = found }
    searchedQuery = query
  }
}
