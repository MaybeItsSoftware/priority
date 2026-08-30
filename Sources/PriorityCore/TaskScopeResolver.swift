import Foundation

/// Whether a view shows only the scope's direct children, or everything beneath
/// it.
///
/// The two answers a task view can give to "what am I looking at". Naming them
/// is the point: the app had five views giving four different answers, two of
/// them implemented privately in their own files, and no view said which it had
/// picked. Same `h`/`l` keys, different meaning per tab, no indication.
public enum TaskScopeMode: String, Codable, Sendable, CaseIterable {
  /// Only tasks whose parent *is* the scope.
  case strictlyParented
  /// Every descendant of the scope, at any depth.
  case wholeSubtree

  /// Named for what the view contains rather than for where you are standing.
  /// "This level" and "Everything below" described the *scope*, which is the
  /// one thing already visible — the breadcrumb beside the chip says where you
  /// are. What was missing was which of the two sets you were being shown.
  public var title: String {
    switch self {
    case .strictlyParented: return "Direct children"
    case .wholeSubtree: return "All descendants"
    }
  }
}

/// The single implementation of "which tasks does this scope cover".
///
/// Before this, `TaskVisibilityEngine` had one rule for Due and Tags, a
/// different one for Priority (which ignored the scope entirely and returned
/// the whole list), `KanbanManager` had a third written by hand against
/// `ds.tasks`, and the matrix view had a fourth inline in its body. The toggle
/// meant to control all of it — `showChildrenInMenus` — was honoured by three
/// of the five.
///
/// The All view is deliberately *not* a caller. It is the navigator: the view
/// you drill through to set the scope that everything else then reads. A
/// navigator that flattened its own subtree would have nothing left to
/// navigate.
public enum TaskScopeResolver {

  public static func mode(showChildrenInMenus: Bool) -> TaskScopeMode {
    showChildrenInMenus ? .wholeSubtree : .strictlyParented
  }

  /// The tasks `parentId` covers under `mode`.
  ///
  /// `currentLevelTasks` is passed rather than derived because the caller has
  /// already computed it — and, at the root, it is the caller's notion of "top
  /// level" rather than something recoverable from a parent ID of zero.
  public static func scoped<Task: VisibilityTask>(
    _ tasks: [Task],
    currentLevelTasks: [Task],
    parentId: Int,
    mode: TaskScopeMode,
    isDescendant: (Task, Int) -> Bool
  ) -> [Task] {
    switch mode {
    case .strictlyParented:
      return currentLevelTasks
    case .wholeSubtree:
      return tasks.filter { isDescendant($0, parentId) }
    }
  }

  /// What the header should say, so a view never leaves you guessing which of
  /// the two answers it gave. `parentTitle` is nil at the root.
  ///
  /// Drag makes this load-bearing rather than cosmetic: dropping a card into a
  /// view whose scope you cannot see is how a task goes missing.
  public static func scopeLabel(mode: TaskScopeMode, parentTitle: String?) -> String {
    guard let parentTitle, !parentTitle.isEmpty else {
      return mode == .wholeSubtree ? "All tasks" : "Top level"
    }
    return mode == .wholeSubtree ? "\(parentTitle) — everything below" : parentTitle
  }
}
