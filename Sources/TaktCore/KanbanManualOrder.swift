import Foundation

/// The per-column manual ordering overlay: which task sits where inside a
/// column, independently of the column's natural sort.
///
/// This existed before as two inline blocks in `KanbanManager` — one applying a
/// saved order, one swapping a pair for the keyboard nudge — and the mouse
/// could reach neither. A drag drops a card *between* two others, which is an
/// insertion, not a swap, so the arithmetic that decides where it lands is
/// worth having in one tested place rather than inline in a drop closure.
///
/// Everything here is index arithmetic over task IDs. It takes the column's
/// currently *visible* order as its input, so a manual order is always anchored
/// to what the user could actually see when they moved the card.
public enum KanbanManualOrder {

  /// The order that results from moving `taskId` so it sits immediately before
  /// whatever is currently at `visibleIndex`.
  ///
  /// `visibleIndex` is expressed against `visible` as the user sees it — that
  /// is, *before* the dragged card is lifted out. Removing the card first
  /// shifts everything after it down one, so a downward move inside the same
  /// column has to compensate; a move in from another column has nothing to
  /// compensate for. Getting this wrong is the classic off-by-one where
  /// dragging a card down one slot appears to do nothing.
  ///
  /// Passing `visible.count` appends, which is what a drop on a column's empty
  /// space means.
  public static func movingTask(
    _ taskId: Int,
    toPositionBefore visibleIndex: Int,
    inVisibleOrder visible: [Int]
  ) -> [Int] {
    let sourceIndex = visible.firstIndex(of: taskId)
    var order = visible
    if let sourceIndex {
      order.remove(at: sourceIndex)
    }
    var target = visibleIndex
    if let sourceIndex, sourceIndex < visibleIndex {
      target -= 1
    }
    order.insert(taskId, at: max(0, min(order.count, target)))
    return order
  }

  /// The order that results from nudging `taskId` one slot up (`-1`) or down
  /// (`+1`). `nil` when the task isn't in the column, or when the nudge would
  /// run off either end — the caller should do nothing rather than clamp, so a
  /// held key at the top of a column doesn't keep rewriting an identical order.
  public static func nudgingTask(
    _ taskId: Int,
    direction: Int,
    inVisibleOrder visible: [Int]
  ) -> [Int]? {
    guard direction == -1 || direction == 1 else { return nil }
    guard let index = visible.firstIndex(of: taskId) else { return nil }
    let destination = index + direction
    guard visible.indices.contains(destination) else { return nil }
    var order = visible
    order.swapAt(index, destination)
    return order
  }

  /// Applies a saved order to a naturally-sorted column. Tasks named in
  /// `order` lead, in that order; everything else keeps the natural sort it
  /// arrived with, behind them.
  ///
  /// Generic over the ID projection so the caller doesn't have to map its
  /// tasks to IDs and back just to sort them.
  public static func apply<Element>(
    _ order: [Int],
    to elements: [Element],
    id: (Element) -> Int
  ) -> [Element] {
    guard !order.isEmpty else { return elements }
    var rankById: [Int: Int] = [:]
    for (index, taskId) in order.enumerated() { rankById[taskId] = index }
    var ranked: [Element] = []
    var unranked: [Element] = []
    for element in elements {
      if rankById[id(element)] != nil {
        ranked.append(element)
      } else {
        unranked.append(element)
      }
    }
    ranked.sort { (rankById[id($0)] ?? .max) < (rankById[id($1)] ?? .max) }
    return ranked + unranked
  }

  /// Drops `removed` from every column's order, returning `nil` when nothing
  /// changed so the caller can skip a write. A column left with no entries is
  /// removed outright rather than left as an empty array.
  public static func removing(
    taskIds removed: Set<Int>,
    from orders: [String: [Int]]
  ) -> [String: [Int]]? {
    guard !removed.isEmpty else { return nil }
    var updated = orders
    var changed = false
    for (key, ids) in orders {
      let filtered = ids.filter { !removed.contains($0) }
      guard filtered.count != ids.count else { continue }
      changed = true
      if filtered.isEmpty {
        updated.removeValue(forKey: key)
      } else {
        updated[key] = filtered
      }
    }
    return changed ? updated : nil
  }
}
