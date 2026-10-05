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

  /// The furthest the *facts* move a task from what it inherited.
  ///
  /// Two units on a scale of nine: enough to separate a pile visibly, small
  /// enough that the goal's own position is still what you read first.
  public static let reach: Double = 2

  /// How far a task may be nudged off its fact-derived point to break a tie.
  ///
  /// Exactly half the spacing between fact levels, so scatter fills a cell and
  /// never reaches into the next one — a task can never be drawn as more urgent
  /// than one that is genuinely due sooner. Within a cell the arrangement means
  /// nothing, and that is the point: those tasks are tied on every fact the app
  /// has, and forty of them spread across a square you can click is a better
  /// answer than forty stacked on a dot labelled `40`.
  public static let scatter: Double = 0.5

  /// How far along each axis a task's own facts push it, plus the tie-break.
  ///
  /// The fact terms are whole steps. That was not true at first, and the plot
  /// showed it: the levels were half-steps drawn from a fixed handful, so every
  /// task landed on one of a few dozen points and the result read as a lattice
  /// — regular in a way nothing about the data is. Whole steps for the meaning,
  /// a continuous nudge for the ties.
  public static func drift(
    dueDate: Date?,
    priorityRank: Int?,
    taskId: Int,
    now: Date,
    calendar: Calendar = .current
  ) -> (urgency: Double, importance: Double) {
    let jitter = tieBreak(taskId: taskId)
    return (
      urgency: urgencyDrift(dueDate: dueDate, now: now, calendar: calendar) + jitter.urgency,
      importance: importanceDrift(priorityRank: priorityRank) + jitter.importance
    )
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

  /// Sooner is more urgent, and no due date at all is the least urgent of the
  /// lot — an unscheduled task under an urgent goal is exactly the one worth
  /// seeing sit below its siblings.
  private static func urgencyDrift(dueDate: Date?, now: Date, calendar: Calendar) -> Double {
    guard let dueDate else { return -reach }
    let today = calendar.startOfDay(for: now)
    let due = calendar.startOfDay(for: dueDate)
    guard let days = calendar.dateComponents([.day], from: today, to: due).day else { return 0 }
    switch days {
    case ..<0: return reach
    case 0...2: return 1
    case 3...14: return 0
    default: return -1
    }
  }

  /// Rank 1 is the most important thing in its scope, rank 9 the least, and an
  /// unranked task has not been argued about at all — so it sits below every
  /// task that has.
  private static func importanceDrift(priorityRank: Int?) -> Double {
    guard let priorityRank else { return -reach }
    switch min(max(priorityRank, 1), 9) {
    case 1, 2: return reach
    case 3, 4: return 1
    case 5, 6: return 0
    default: return -1
    }
  }

  /// A stable pseudo-random offset in `-scatter ..< scatter` on each axis.
  ///
  /// Mixed by hand rather than through `Hasher`, whose seed changes every
  /// launch — dots that jumped to new positions each time the app opened would
  /// read as the data having changed. Same id, same point, forever.
  private static func tieBreak(taskId: Int) -> (urgency: Double, importance: Double) {
    var state = UInt64(bitPattern: Int64(taskId)) &+ 0x9E37_79B9_7F4A_7C15
    func next() -> Double {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      z = z ^ (z >> 31)
      // Top 53 bits into 0..<1, then onto -scatter ..< scatter.
      let unit = Double(z >> 11) / Double(1 << 53)
      return (unit * 2 - 1) * scatter
    }
    return (urgency: next(), importance: next())
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
