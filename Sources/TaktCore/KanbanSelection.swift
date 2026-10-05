import Foundation

/// Where the board's selection sits, and where it moves to.
///
/// The other half of `KanbanManager`. `KanbanFilter` decides which column a
/// task lands in; this decides which card is selected and which column has
/// focus once it has. It was index arithmetic threaded through `dataSource`
/// reads — `nextKanbanTask`, `previousKanbanTask`, `clampKanbanSelection`,
/// `resolvedFocusedColumnIndex` — so none of it could be reached from a test.
///
/// Everything here works on a *grid*: one array of task ids per column, in
/// display order. That is deliberately all it needs. It means the rules do not
/// depend on `CheckvistTask`, on the column definitions, or on how the board
/// filtered and sorted itself to get there — and it means the caller builds the
/// grid once per operation rather than re-filtering every column inside every
/// comparison, which is what the manager used to do.
public enum KanbanSelection {

  /// The three values that move together. `siblingIndex` is the row within the
  /// focused column, kept in step with `selectedTaskId` because the scope
  /// navigation and the list view both read it.
  public struct Placement: Equatable {
    public var focusedColumnIndex: Int
    public var selectedTaskId: Int?
    public var siblingIndex: Int

    public init(focusedColumnIndex: Int, selectedTaskId: Int?, siblingIndex: Int) {
      self.focusedColumnIndex = focusedColumnIndex
      self.selectedTaskId = selectedTaskId
      self.siblingIndex = siblingIndex
    }
  }

  // MARK: - Locating

  /// The column and row holding `taskId`, searching in column order.
  public static func locate(_ taskId: Int, in grid: [[Int]]) -> (column: Int, row: Int)? {
    for (column, ids) in grid.enumerated() {
      if let row = ids.firstIndex(of: taskId) { return (column, row) }
    }
    return nil
  }

  /// The column that actually holds the selection, which is not necessarily the
  /// one with focus — a task can be moved out from under the focused column by
  /// an edit elsewhere. Falls back to `fallback` when nothing is selected or the
  /// selection is no longer on the board.
  public static func resolvedFocusedColumnIndex(
    selectedTaskId: Int?,
    in grid: [[Int]],
    fallback: Int
  ) -> Int {
    guard let selectedTaskId else { return fallback }
    return locate(selectedTaskId, in: grid)?.column ?? fallback
  }

  // MARK: - Moving

  /// Sideways. `direction` is +1 for visual right; the board is displayed
  /// reversed, so that is a *lower* array index. Returns `nil` — meaning "do
  /// not move" — at either end, rather than clamping, so the caller leaves the
  /// existing selection alone.
  public static func focusColumn(
    from focusedColumnIndex: Int,
    direction: Int,
    in grid: [[Int]]
  ) -> Placement? {
    let next = focusedColumnIndex - direction
    guard grid.indices.contains(next) else { return nil }
    // Selection follows focus to the top of the new column, and clears if that
    // column is empty.
    return Placement(
      focusedColumnIndex: next, selectedTaskId: grid[next].first, siblingIndex: 0)
  }

  /// Down one card. Clamps at the bottom rather than wrapping or spilling into
  /// the next column.
  public static func next(
    from placement: Placement,
    in grid: [[Int]]
  ) -> Placement? {
    move(from: placement, in: grid, step: 1)
  }

  /// Up one card, clamping at the top.
  public static func previous(
    from placement: Placement,
    in grid: [[Int]]
  ) -> Placement? {
    move(from: placement, in: grid, step: -1)
  }

  private static func move(
    from placement: Placement,
    in grid: [[Int]],
    step: Int
  ) -> Placement? {
    let column = resolvedFocusedColumnIndex(
      selectedTaskId: placement.selectedTaskId, in: grid,
      fallback: placement.focusedColumnIndex)
    guard grid.indices.contains(column) else { return nil }
    let ids = grid[column]
    guard !ids.isEmpty else { return nil }

    // With nothing selected, moving down starts above the first card and moving
    // up starts below the last, so one press lands on an end rather than
    // skipping past it.
    let current =
      placement.selectedTaskId.flatMap { ids.firstIndex(of: $0) }
      ?? (step > 0 ? -1 : ids.count)
    let row = min(max(current + step, 0), ids.count - 1)
    return Placement(focusedColumnIndex: column, selectedTaskId: ids[row], siblingIndex: row)
  }

  /// Whether UP should leave the column entirely instead of moving within it.
  /// An empty or out-of-range column counts as "at the top" so the key still
  /// does something.
  public static func isAtTopOfFocusedColumn(
    _ placement: Placement,
    in grid: [[Int]]
  ) -> Bool {
    let column = resolvedFocusedColumnIndex(
      selectedTaskId: placement.selectedTaskId, in: grid,
      fallback: placement.focusedColumnIndex)
    guard grid.indices.contains(column), let first = grid[column].first else { return true }
    return placement.selectedTaskId == nil || placement.selectedTaskId == first
  }

  // MARK: - Repairing

  /// Re-validates the selection after a mutation. A selection that is still on
  /// the board anywhere is left exactly as it is — including its focus and row,
  /// which may be stale but are the caller's to refresh.
  ///
  /// Otherwise the selection is stale (completed, deleted, filtered out) and we
  /// pick the nearest card in the focused column by *row*, so removing a card
  /// leaves the selection where the eye already is rather than jumping.
  public static func clamp(_ placement: Placement, in grid: [[Int]]) -> Placement {
    if let selected = placement.selectedTaskId, locate(selected, in: grid) != nil {
      return placement
    }
    guard grid.indices.contains(placement.focusedColumnIndex) else {
      return Placement(
        focusedColumnIndex: placement.focusedColumnIndex, selectedTaskId: nil, siblingIndex: 0)
    }
    let ids = grid[placement.focusedColumnIndex]
    guard !ids.isEmpty else {
      return Placement(
        focusedColumnIndex: placement.focusedColumnIndex, selectedTaskId: nil, siblingIndex: 0)
    }
    let row = min(max(placement.siblingIndex, 0), ids.count - 1)
    return Placement(
      focusedColumnIndex: placement.focusedColumnIndex, selectedTaskId: ids[row], siblingIndex: row)
  }

  /// The first card on the board, scanning columns in order. Used when the
  /// scope changes and the previous selection has no meaning in the new one.
  /// Returns a placement with no selection when the board is empty — the board
  /// is still shown, just with nothing on it.
  public static func firstAvailable(in grid: [[Int]], fallbackColumnIndex: Int = 0) -> Placement {
    for (column, ids) in grid.enumerated() {
      if let first = ids.first {
        return Placement(focusedColumnIndex: column, selectedTaskId: first, siblingIndex: 0)
      }
    }
    return Placement(
      focusedColumnIndex: fallbackColumnIndex, selectedTaskId: nil, siblingIndex: 0)
  }

  /// Selects `taskId` if it is on the board, so popping out of a scope lands on
  /// the task just left. Falls back to the first available card.
  public static func select(
    _ taskId: Int?,
    in grid: [[Int]],
    fallbackColumnIndex: Int = 0
  ) -> Placement {
    if let taskId, let found = locate(taskId, in: grid) {
      return Placement(
        focusedColumnIndex: found.column, selectedTaskId: taskId, siblingIndex: found.row)
    }
    return firstAvailable(in: grid, fallbackColumnIndex: fallbackColumnIndex)
  }
}
