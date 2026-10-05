import Foundation

/// Which of the four Eisenhower boxes a coordinate falls in.
///
/// Exists as a type rather than a pair of sign checks because two separate
/// features need to name a quadrant: the matrix, to label and colour it, and
/// the kanban board, whose columns can be defined by one.
public enum MatrixQuadrant: String, Codable, CaseIterable, Identifiable, Sendable {
  /// Urgent and important.
  case doNow
  /// Important, not urgent.
  case schedule
  /// Urgent, not important.
  case delegate
  /// Neither.
  case eliminate

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .doNow: return "Do"
    case .schedule: return "Schedule"
    case .delegate: return "Delegate"
    case .eliminate: return "Eliminate"
    }
  }

  /// The coordinate a whole-quadrant placement lands on — the middle of the
  /// box, so a card dropped by quadrant rather than by point sits somewhere
  /// honest rather than pinned to a corner.
  public var representativeCoordinate: (urgency: Double, importance: Double) {
    switch self {
    case .doNow: return (5, 5)
    case .schedule: return (-5, 5)
    case .delegate: return (5, -5)
    case .eliminate: return (-5, -5)
    }
  }

  /// Spelled the way the command palette and the CLI accept them. `do` is a
  /// Swift keyword, hence `doNow` for the case and `do` for the word.
  public var commandWords: [String] {
    switch self {
    case .doNow: return ["do", "do-now", "donow"]
    case .schedule: return ["schedule", "plan"]
    case .delegate: return ["delegate"]
    case .eliminate: return ["eliminate", "drop", "bin"]
    }
  }

  public static func named(_ word: String) -> MatrixQuadrant? {
    let normalized = word.trimmingCharacters(in: .whitespaces).lowercased()
    return allCases.first { $0.commandWords.contains(normalized) }
  }
}

/// The mapping between an Eisenhower coordinate and a point on the plotted
/// square, in both directions.
///
/// Lifted out of `EisenhowerMatrixView`, which inlined the forward half and had
/// no reverse half at all — which is precisely why the matrix could only ever
/// be read, never written by pointing at it. Dragging a dot needs
/// point-to-coordinate; drawing one needs coordinate-to-point; and a round trip
/// through both has to land where it started, which is the thing worth testing.
public enum MatrixGeometry {

  /// Coordinates run -9...9 on both axes.
  public static let extent: Double = 9

  /// The plotted square is scaled by 10 rather than by `extent`, which leaves
  /// a tenth of the half-width as margin so a dot at ±9 sits inside the edge
  /// instead of straddling it.
  public static let scale: Double = 10

  /// Where a coordinate sits, as an offset in points from the centre of the
  /// square. Positive urgency is right; positive importance is *up*, so its
  /// offset is negated for a downward-growing view coordinate space.
  public static func offset(
    urgency: Double, importance: Double, plotSize: Double
  ) -> (x: Double, y: Double) {
    let half = plotSize / 2
    return (x: (urgency / scale) * half, y: -(importance / scale) * half)
  }

  /// The inverse: the coordinate an offset from the centre represents, clamped
  /// to the legal range so a drop outside the square still lands on the board
  /// rather than off the scale.
  public static func coordinate(
    offsetX: Double, offsetY: Double, plotSize: Double
  ) -> (urgency: Double, importance: Double) {
    guard plotSize > 0 else { return (0, 0) }
    let half = plotSize / 2
    let urgency = (offsetX / half) * scale
    let importance = -(offsetY / half) * scale
    return (clamp(urgency), clamp(importance))
  }

  /// Rounded to whole steps, which is what a drag should commit — the axes are
  /// labelled in integers and a stored 4.37 reads as noise.
  public static func snappedCoordinate(
    offsetX: Double, offsetY: Double, plotSize: Double
  ) -> (urgency: Double, importance: Double) {
    let raw = coordinate(offsetX: offsetX, offsetY: offsetY, plotSize: plotSize)
    return (raw.urgency.rounded(), raw.importance.rounded())
  }

  public static func clamp(_ value: Double) -> Double {
    min(extent, max(-extent, value))
  }

  /// Zero on an axis is the dividing line, not a side. A coordinate sitting
  /// exactly on it is treated as the *lower* side — a task with zero urgency
  /// is not urgent — so every coordinate has exactly one quadrant.
  public static func quadrant(urgency: Double, importance: Double) -> MatrixQuadrant {
    switch (urgency > 0, importance > 0) {
    case (true, true): return .doNow
    case (false, true): return .schedule
    case (true, false): return .delegate
    case (false, false): return .eliminate
    }
  }

  /// Whether a coordinate counts as placed at all. `(0, 0)` is the unset
  /// sentinel — the store drops it on save — so it is the one coordinate that
  /// belongs to no quadrant and draws no dot.
  public static func isPlaced(urgency: Double, importance: Double) -> Bool {
    urgency != 0 || importance != 0
  }
}
