/// The path the board draws between a subtask's row and its card in another
/// column, while either end is selected or under the pointer.
///
/// The cards stack as they would with no links (`BoardLinks`), so the line
/// cannot run straight across as the old levelled hairline did. It leaves the
/// row sideways, turns into the rule between the source column and the next,
/// runs along that rule to the card's height, and turns again into the card:
///
///     row ──╮
///           │
///           ╰──── card
///
/// Only one selection's links are drawn at a time, so a line that crosses an
/// intermediate column does so at the card's height straight over whatever is
/// there, rather than threading round it. Nothing here moves a card: the
/// line is drawn over the board from where the cards already are.
///
/// Pure geometry in plain doubles, so it is tested without the app; the
/// board turns the points into a path.
public enum BoardLinkRoute {
  /// A point on the board, in the overlay's coordinate space.
  public struct Point: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  /// A measured frame: a row, a card's heading, a column.
  public struct Rect: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
      self.minX = minX
      self.minY = minY
      self.maxX = maxX
      self.maxY = maxY
    }

    public var midY: Double { (minY + maxY) / 2 }
  }

  /// The line between two ends, as corner points and the radius each corner
  /// is rounded to.
  public struct Path: Equatable, Sendable {
    public let points: [Point]
    /// One per point; zero at the two ends and wherever a corner has no room.
    public let radii: [Double]

    public init(points: [Point], radii: [Double]) {
      self.points = points
      self.radii = radii
    }
  }

  /// Rises or falls smaller than this are drawn as a straight line: a
  /// half-point jog with two rounded corners reads as a smudge.
  public static let straightTolerance = 0.5

  /// The route from a subtask's row (or the label on its parent's card that
  /// stands for it) to the subtask's card.
  ///
  /// - Parameters:
  ///   - source: the row, or the heading's label, on the parent's card.
  ///   - target: the subtask card's heading.
  ///   - sourceColumn: the parent card's column.
  ///   - pointsForward: whether the subtask's column is to the right.
  ///   - inset: the space left between the line's ends and the two frames.
  ///   - rail: how far past the source column's edge the line runs along —
  ///     half the rule between columns puts it on the rule.
  ///   - radius: the corners' radius, before any is shrunk to fit.
  public static func path(
    from source: Rect, to target: Rect, sourceColumn: Rect, pointsForward: Bool,
    inset: Double, rail: Double, radius: Double
  ) -> Path {
    let points = points(
      from: source, to: target, sourceColumn: sourceColumn, pointsForward: pointsForward, inset: inset, rail: rail)
    return Path(points: points, radii: radii(points, radius: radius))
  }

  /// The corner points of the route: out of the source sideways, along the
  /// rule beside its column, and into the target at its height.
  static func points(
    from source: Rect, to target: Rect, sourceColumn: Rect, pointsForward: Bool, inset: Double, rail: Double
  ) -> [Point] {
    // Everything is worked out as if the link ran left to right, then
    // mirrored back for one that runs the other way.
    let sign: Double = pointsForward ? 1 : -1
    let startX = pointsForward ? source.maxX + inset : source.minX - inset
    let edgeX = pointsForward ? sourceColumn.maxX + rail : sourceColumn.minX - rail
    let endX = pointsForward ? target.minX - inset : target.maxX + inset
    // Never doubling back: a label that runs past its column's edge, or a
    // target closer than the rule, keeps the line going the one way.
    let railX = sign * max(sign * edgeX, sign * startX)
    let finishX = sign * max(sign * endX, sign * railX)
    let start = Point(x: startX, y: source.midY)
    if abs(target.midY - source.midY) < straightTolerance {
      return [start, Point(x: finishX, y: source.midY)]
    }
    return [
      start,
      Point(x: railX, y: source.midY),
      Point(x: railX, y: target.midY),
      Point(x: finishX, y: target.midY),
    ]
  }

  /// Each corner's radius, shrunk until it fits: a corner may take all of a
  /// leg that ends at the start or finish, and half of one it shares with
  /// another corner.
  static func radii(_ points: [Point], radius: Double) -> [Double] {
    guard points.count > 2 else { return Array(repeating: 0, count: points.count) }
    func length(_ from: Int, _ to: Int) -> Double {
      abs(points[to].x - points[from].x) + abs(points[to].y - points[from].y)
    }
    let last = points.count - 1
    var radii = Array(repeating: 0.0, count: points.count)
    for index in 1..<last {
      let before = length(index - 1, index) / (index - 1 == 0 ? 1 : 2)
      let after = length(index, index + 1) / (index + 1 == last ? 1 : 2)
      radii[index] = max(0, min(radius, before, after))
    }
    return radii
  }
}
