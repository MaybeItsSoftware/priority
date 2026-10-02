import Foundation
import Observation
import PriorityWorkspace

/// The root views. On iPhone these are the tabs; on iPad they head the sidebar.
enum RootTab: String, CaseIterable, Identifiable, Hashable {
  case today, lists, focus, review, search

  var id: String { rawValue }

  var title: String {
    switch self {
    case .today: "Today"
    case .lists: "Lists"
    case .focus: "Focus"
    case .review: "Review"
    case .search: "Search"
    }
  }

  var symbol: String {
    switch self {
    case .today: "sun.max"
    case .lists: "list.bullet.indent"
    case .focus: "scope"
    case .review: "chart.bar.xaxis"
    case .search: "magnifyingglass"
    }
  }
}

/// What a list screen shows: one list, a nested list inside one, a folder's
/// lists combined, or every active list.
enum ListScope: Hashable, Codable, Sendable {
  case everything
  case folder(String)
  case list(String)
  /// A task-backed list nested in `listID`, opened as a scope of its own.
  case nested(listID: String, taskID: String)

  var listID: String? {
    switch self {
    case .list(let id): id
    case .nested(let listID, _): listID
    case .everything, .folder: nil
    }
  }

  /// Whether the scope is one tree, where outline structure (indent, fold,
  /// reorder) means something. Combined scopes are flat lists of doable work.
  var isSingleTree: Bool { listID != nil }

  /// Board layouts are stored by this key, the desktop's own.
  var boardKey: String {
    switch self {
    case .everything: "everything/root"
    case .folder(let id): "folder:\(id)/root"
    case .list(let id): "\(id)/root"
    case .nested(let listID, let taskID): "\(listID)/\(taskID)"
    }
  }

  /// Folds and view modes are remembered per scope under this key.
  var storageKey: String {
    switch self {
    case .everything: "everything"
    case .folder(let id): "folder:\(id)"
    case .list(let id): "list:\(id)"
    case .nested(_, let taskID): "nested:\(taskID)"
    }
  }
}

/// The three projections of a list.
enum ListViewMode: String, CaseIterable, Identifiable {
  case outline, board, matrix

  var id: String { rawValue }

  var title: String {
    switch self {
    case .outline: "Outline"
    case .board: "Board"
    case .matrix: "Matrix"
    }
  }

  var symbol: String {
    switch self {
    case .outline: "list.bullet.indent"
    case .board: "rectangle.split.3x1"
    case .matrix: "square.grid.2x2"
    }
  }
}

/// A sidebar row on iPad.
enum SidebarItem: Hashable {
  case root(RootTab)
  case scope(ListScope)
}

/// Where the user is. One object, so the iPhone tabs, the iPad split view,
/// the keyboard shortcuts and the intents that open the app agree.
@MainActor
@Observable
final class AppNavigation {
  var tab: RootTab = .today
  /// The iPhone Lists tab's stack.
  var listPath: [ListScope] = []
  /// The iPad sidebar's selection.
  var sidebarSelection: SidebarItem? = .root(.today)
  /// The task the list, board or day has highlighted. On iPad the inspector
  /// column follows it.
  var selectedTaskID: String?
  /// The task whose inspector sheet is up (iPhone).
  var inspectedTaskID: String?
  var isQuickAddPresented = false
  /// Where quick add files the task when it was opened from a list or a
  /// task: nil means the Inbox.
  var quickAddListID: String?
  var quickAddParentTaskID: String?
  /// The task the move-to-list picker is up for.
  var movingTaskID: String?
  /// The create/rename alert the list tree has up.
  var namePrompt: NamePrompt?
  var pendingDeletion: PendingDeletion?
  var listSettingsID: String?
  /// A command for the outline on screen, from the toolbar or a hardware key.
  var outlineCommand: OutlineCommand?
  var isHistoryPresented = false
  var isSettingsPresented = false
  /// Bumped to ask the search field for the keyboard.
  var searchFocusRequest = 0

  var viewMode: ListViewMode {
    didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey) }
  }

  private static let viewModeKey = "listViewMode"

  init() {
    viewMode = ListViewMode(rawValue: UserDefaults.standard.string(forKey: Self.viewModeKey) ?? "") ?? .outline
  }

  /// The scope on screen, wherever it is shown.
  var currentScope: ListScope? {
    if case .scope(let scope) = sidebarSelection { return scope }
    return listPath.last
  }

  /// Opens a list scope, on whichever layout is showing.
  func open(_ scope: ListScope, isPad: Bool) {
    if isPad {
      sidebarSelection = .scope(scope)
    } else {
      tab = .lists
      listPath = [scope]
    }
    selectedTaskID = nil
  }

  func go(to tab: RootTab, isPad: Bool) {
    if isPad {
      if tab == .lists {
        if case .scope = sidebarSelection {} else { sidebarSelection = .scope(.everything) }
      } else {
        sidebarSelection = .root(tab)
      }
    } else {
      self.tab = tab
    }
  }

  /// Shows a task's details: the sheet on iPhone, the column on iPad.
  func inspect(_ taskID: String, isPad: Bool) {
    selectedTaskID = taskID
    if !isPad { inspectedTaskID = taskID }
  }
}
