import Foundation
import Observation

@MainActor
@Observable final class NavigationState {
  @ObservationIgnored private let cacheInvalidationBus: CacheInvalidationBus

  /// Called when the user moves: a different parent, a different row, or the
  /// popover opening or closing.
  ///
  /// Exists for the completion celebration, which is the one piece of the app
  /// that cares about being interrupted. A celebration is awaited *before* the
  /// close request goes out, so a user who fires one and immediately arrows
  /// away has to be able to call it off — otherwise the close lands a fifth of
  /// a second later against a row they are no longer looking at. The signal is
  /// a closure rather than an observation because it has to fire on the
  /// transition, not on the next redraw.
  @ObservationIgnored var onNavigationChanged: (() -> Void)?

  var currentParentId: Int = 0 {
    didSet {
      cacheInvalidationBus.invalidate()
      notifyIfMoved(from: oldValue, to: currentParentId)
    }
  }
  var currentSiblingIndex: Int = 0 {
    didSet { notifyIfMoved(from: oldValue, to: currentSiblingIndex) }
  }
  /// The Matrix view's own selection.
  ///
  /// The plot needs one of its own for the same reason the kanban board does:
  /// `visibleTasks` is deliberately empty in both, since neither renders the
  /// task list, and `currentTask` reads an index into that list. So the matrix
  /// had no selected task at all — every dot drew unselected, `md` answered
  /// "No task selected", and the arrow keys moved something nothing was
  /// reading.
  ///
  /// A task id rather than an index, and separate from `currentParentId`,
  /// because the alternative — routing matrix selection through
  /// `navigate(to:)` — writes the scope as a side effect. Selecting a task two
  /// levels down would re-scope the plot to its parent and change which dots
  /// are on screen, which is not what picking one of them means.
  var matrixSelectedTaskId: Int? {
    didSet { notifyIfMoved(from: oldValue, to: matrixSelectedTaskId) }
  }
  var rootScopeFocusLevel: Int = 0
  var isPopoverVisible: Bool = false {
    didSet { notifyIfMoved(from: oldValue, to: isPopoverVisible) }
  }

  init(cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus()) {
    self.cacheInvalidationBus = cacheInvalidationBus
  }

  /// Only on a real transition. `didSet` fires on every write, including the
  /// idempotent ones the view layer makes constantly (a tap that re-selects the
  /// already-selected row, a scope restore that assigns the same parent), and
  /// treating those as movement would cancel a celebration the user never
  /// interrupted.
  private func notifyIfMoved<Value: Equatable>(from oldValue: Value, to newValue: Value) {
    guard oldValue != newValue else { return }
    onNavigationChanged?()
  }
}
