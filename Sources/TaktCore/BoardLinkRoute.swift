/// The path the board draws between a subtask's row and its card in another
/// column: a hairline at rest, the accent while either end is selected or
/// under the pointer.
///
/// The cards stack as they would with no links (`BoardLinks`), give or take
/// the small nudge `BoardLinkNudge` allows, so the line cannot always run
/// straight across as the old levelled hairline did. It leaves the row
/// sideways, turns in the gutter between the source column and the next —
/// in a lane of its own when others turn there too (`lanes(for:)`) — runs
/// down it to the card's height, and turns again into the card:
///
///     row ──╮
///           │
///           ╰──── card
///
/// A line that crosses an intermediate column does so at the card's height,
/// beneath that column's cards while at rest and over them while lit, rather
/// than threading round them. Nothing here moves a card: the line is drawn
/// from where the cards already are.
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
  ///     half the gutter between columns puts it on the rule, and its lane
  ///     (`lanes(for:)`) moves it off.
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

// MARK: - Lanes

extension BoardLinkRoute {
  /// A link that turns in a gutter, as its lane is worked out.
  public struct LaneRequest: Equatable, Sendable {
    public let id: String
    /// The column the link leaves: it turns in the gutter after it when it
    /// points forward, before it when it points back.
    public let sourceColumn: Int
    public let pointsForward: Bool
    /// The height it leaves its row at, and arrives at its card at.
    public let sourceY: Double
    public let targetY: Double

    public init(id: String, sourceColumn: Int, pointsForward: Bool, sourceY: Double, targetY: Double) {
      self.id = id
      self.sourceColumn = sourceColumn
      self.pointsForward = pointsForward
      self.sourceY = sourceY
      self.targetY = targetY
    }
  }

  /// How far each link's turn sits from the middle of its gutter, along its
  /// own direction — positive is further from the column it leaves — so that
  /// several links turning in one gutter each run down a lane of their own
  /// rather than along one another.
  ///
  /// A link that runs straight across turns nowhere and needs no lane. The
  /// others leaving one column the same way are spread `spacing` apart and
  /// centred on the middle, closer together when that would take them wider
  /// than `width`. They are ordered so that two whose spans overlap cross
  /// only where they must: of two falling links, the one leaving higher
  /// turns further out, so the lower one's way out passes inside it and its
  /// way in passes beneath; of two rising links, the one leaving lower does.
  /// Falling links take the outer lanes, rising ones the inner.
  ///
  /// A link missing from the answer turns on the middle.
  public static func lanes(for requests: [LaneRequest], spacing: Double, width: Double) -> [String: Double] {
    struct Gutter: Hashable {
      let column: Int
      let forward: Bool
    }
    var groups: [Gutter: [LaneRequest]] = [:]
    for request in requests where abs(request.targetY - request.sourceY) >= straightTolerance {
      groups[Gutter(column: request.sourceColumn, forward: request.pointsForward), default: []].append(request)
    }
    var offsets: [String: Double] = [:]
    for group in groups.values where group.count > 1 {
      let falling = group.filter { $0.targetY > $0.sourceY }
        .sorted { ($0.sourceY, $0.id) < ($1.sourceY, $1.id) }
      let rising = group.filter { $0.targetY < $0.sourceY }
        .sorted { ($1.sourceY, $0.id) < ($0.sourceY, $1.id) }
      let ordered = falling + rising
      let gap = min(spacing, max(width, 0) / Double(ordered.count - 1))
      let middle = Double(ordered.count - 1) / 2
      for (slot, request) in ordered.enumerated() {
        offsets[request.id] = (middle - Double(slot)) * gap
      }
    }
    return offsets
  }
}
