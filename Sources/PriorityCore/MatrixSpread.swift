import Foundation

/// Where an *inherited* task sits inside its goal's point.
///
/// Inheritance is what makes placing tasks affordable — seven goals classify two
/// hundred descendants — but it hands every descendant the same coordinate
/// *exactly*, so the plot drew them as one dot and could say nothing about any
/// of them that it did not already say about their goal. Scoped to a single
/// goal there was one dot on the whole grid, and the arrow keys had nowhere to
/// go.
///
/// So a task that inherited its place drifts off it, by facts it already
/// carries: how soon it is due, and where it sits in the priority queue. No
/// extra placement work, and nothing invented — the drift is a reading of the
/// task's own data, which is why it is drawn hollow like any inherited
/// coordinate.
public enum MatrixSpread {

  /// The furthest a derived offset moves a task from what it inherited.
  ///
  /// Two units on a scale of nine: enough to separate a pile visibly, small
  /// enough that the goal's own position is still what you read first. The
  /// coordinate stays an answer about the goal, refined — not replaced.
  public static let reach: Double = 2

  /// How far along each axis a task's own facts push it.
  public static func drift(
    dueDate: Date?,
    priorityRank: Int?,
    now: Date,
    calendar: Calendar = .current
  ) -> (urgency: Double, importance: Double) {
    (urgency: urgencyDrift(dueDate: dueDate, now: now, calendar: calendar),
     importance: importanceDrift(priorityRank: priorityRank))
  }

  /// The inherited coordinate with the drift applied.
  ///
  /// The result never crosses an axis. Which quadrant a goal belongs in is a
  /// judgement somebody made; a derived offset is allowed to order tasks inside
  /// it and not to overturn it — a task drifting out of `Do` into `Delegate`
  /// would be the plot inventing an opinion.
  public static func spread(
    base: (urgency: Double, importance: Double),
    drift: (urgency: Double, importance: Double)
  ) -> (urgency: Double, importance: Double) {
    (urgency: bounded(base: base.urgency, drift: drift.urgency),
     importance: bounded(base: base.importance, drift: drift.importance))
  }

  /// Sooner is more urgent, and no due date at all is less urgent than the goal
  /// nominally is — an unscheduled task under an urgent goal is exactly the one
  /// worth seeing sitting below its siblings.
  private static func urgencyDrift(dueDate: Date?, now: Date, calendar: Calendar) -> Double {
    guard let dueDate else { return -1 }
    let today = calendar.startOfDay(for: now)
    let due = calendar.startOfDay(for: dueDate)
    guard let days = calendar.dateComponents([.day], from: today, to: due).day else { return 0 }
    switch days {
    case ..<0: return reach
    case 0: return 1.5
    case 1...2: return 1
    case 3...7: return 0.5
    default: return 0
    }
  }

  /// Rank 1 is the most important thing in its scope, rank 9 the least, and an
  /// unranked task has not been argued about at all — so it sits below every
  /// task that has.
  private static func importanceDrift(priorityRank: Int?) -> Double {
    guard let priorityRank else { return -1 }
    let rank = Double(min(max(priorityRank, 1), 9))
    return reach - (rank - 1) / 8 * (reach - 0.5)
  }

  /// Zero counts as the lower side of an axis, the way `MatrixGeometry.quadrant`
  /// reads it, so a goal sitting exactly on one cannot be drifted off it into a
  /// quadrant it was never put in.
  private static func bounded(base: Double, drift: Double) -> Double {
    let raw = base + drift
    if base > 0 { return MatrixGeometry.clamp(max(0.5, raw)) }
    if base < 0 { return MatrixGeometry.clamp(min(-0.5, raw)) }
    return MatrixGeometry.clamp(min(0, raw))
  }
}
