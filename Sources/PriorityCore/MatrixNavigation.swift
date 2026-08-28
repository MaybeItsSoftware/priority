import Foundation

/// Which way an arrow key moves across the plot.
public enum MatrixDirection: Sendable, CaseIterable {
  case up
  case down
  case left
  case right
}

/// Walking the matrix by keyboard.
///
/// The plot was a mouse-only surface: dots could be hovered, tapped and
/// dragged, and nothing about it answered to a key. The arrow keys underneath
/// were still walking the hidden task list, which moved the selection to a dot
/// somewhere unrelated — motion with no relationship to the thing on screen.
public enum MatrixNavigation {

  /// The cluster an arrow key should land on.
  ///
  /// The rule is "the next distinct level on this axis, breaking ties by the
  /// other one", not a cone or a nearest-neighbour search. Both of those leave
  /// dots that no sequence of presses can reach — a dot alone in a corner is
  /// outside every cone from everywhere else. Stepping one level at a time
  /// means repeated presses walk every distinct row or column, so the whole
  /// plot is reachable, and the order never depends on how far apart two dots
  /// happen to be drawn.
  ///
  /// `current` is the coordinate the selection sits on, which for an inherited
  /// task is its ancestor's. Passing `nil` — nothing selected, or a selection
  /// with no place on the plot — enters at the dot nearest the origin rather
  /// than refusing to move.
  public static func target<Task: VisibilityTask>(
    from current: (urgency: Double, importance: Double)?,
    direction: MatrixDirection,
    in clusters: [MatrixCluster<Task>]
  ) -> MatrixCluster<Task>? {
    guard !clusters.isEmpty else { return nil }
    guard let current else { return entryPoint(in: clusters) }

    let from = axes(of: current, direction: direction)
    var best: (cluster: MatrixCluster<Task>, primary: Double, secondary: Double)?
    for cluster in clusters {
      let to = axes(
        of: (urgency: cluster.urgency, importance: cluster.importance), direction: direction)
      let step = to.primary - from.primary
      guard step > 0 else { continue }
      let drift = abs(to.secondary - from.secondary)
      // Ties keep the earlier cluster, so the plot's own order settles them
      // rather than floating-point luck.
      if let current = best, (current.primary, current.secondary) <= (step, drift) { continue }
      best = (cluster, step, drift)
    }
    return best?.cluster
  }

  /// Where the keyboard joins the plot when the selection is not on it: the dot
  /// closest to the middle, which is the one the eye starts from.
  public static func entryPoint<Task: VisibilityTask>(
    in clusters: [MatrixCluster<Task>]
  ) -> MatrixCluster<Task>? {
    clusters.min { lhs, rhs in
      let left = lhs.urgency * lhs.urgency + lhs.importance * lhs.importance
      let right = rhs.urgency * rhs.urgency + rhs.importance * rhs.importance
      return left < right
    }
  }

  /// The next task to triage after one has just been placed.
  ///
  /// Searched forward from the task just placed and wrapping once. Wrapping
  /// matters: placements land tasks anywhere in the order, so a strict forward
  /// search would strand the ones above the cursor and the pass would look
  /// finished while the drawer still had entries in it.
  ///
  /// `unplaced` is the drawer's own list, not a fresh judgement about what
  /// counts as placed — the two used to disagree. The drawer treats a
  /// coordinate inherited from an ancestor as placed, which is the point of
  /// inheritance; this searched for tasks with no coordinate *of their own*,
  /// so the drawer would say two and the placement keys would walk you through
  /// two hundred.
  ///
  /// The task just placed is normally absent from `unplaced` by the time this
  /// is asked, so position comes from `order` — the full list, in the order it
  /// is displayed in — rather than from the unplaced list itself.
  public static func nextUnplaced<Task: VisibilityTask>(
    after taskId: Int,
    unplaced: [Task],
    order: [Int]
  ) -> Task? {
    guard !unplaced.isEmpty else { return nil }
    let rank = Dictionary(
      order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    // No position to search from — the placed task is not in the list at all —
    // so start at the top rather than refusing to move.
    guard let from = rank[taskId] else { return unplaced.first }
    return unplaced.first { rank[$0.id].map { $0 > from } ?? false } ?? unplaced.first
  }

  /// The pair of axes as "along" and "across", with `up` and `right` positive,
  /// so one comparison serves all four directions.
  private static func axes(
    of coordinate: (urgency: Double, importance: Double),
    direction: MatrixDirection
  ) -> (primary: Double, secondary: Double) {
    switch direction {
    case .up: return (coordinate.importance, coordinate.urgency)
    case .down: return (-coordinate.importance, coordinate.urgency)
    case .right: return (coordinate.urgency, coordinate.importance)
    case .left: return (-coordinate.urgency, coordinate.importance)
    }
  }
}
