import Foundation

/// Which part of the coordinate space the plot is currently drawing.
///
/// The grid was always the whole board, so a quadrant got a quarter of the
/// glass however much was in it — and `Do` is the one that fills up. Zooming is
/// a change of viewport rather than of data: the same coordinates, mapped
/// through a smaller window, so nothing about a task changes by looking at it
/// closer.
///
/// Held as centre-and-span rather than as a range because that is what the
/// mapping needs in both directions, and deriving it twice is how the drawing
/// and the drop handler come to disagree about where a point is.
public struct MatrixViewport: Equatable, Sendable {
  public let centre: (urgency: Double, importance: Double)
  /// Half the width of the window on each axis, in coordinate units.
  public let span: Double

  public init(centre: (urgency: Double, importance: Double), span: Double) {
    self.centre = centre
    self.span = span
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.centre == rhs.centre && lhs.span == rhs.span
  }

  /// The whole board. Spans by `MatrixGeometry.scale` rather than `extent`, so
  /// a dot at ±9 sits inside the edge instead of straddling it — the margin the
  /// unzoomed plot has always had.
  public static let full = MatrixViewport(centre: (0, 0), span: MatrixGeometry.scale)

  /// One box, filling the grid. Its centre is the middle of the quadrant and
  /// its span half the board's, so the same margin survives the zoom.
  public static func quadrant(_ quadrant: MatrixQuadrant) -> MatrixViewport {
    let half = MatrixGeometry.scale / 2
    let point = quadrant.representativeCoordinate
    return MatrixViewport(
      centre: (urgency: point.urgency > 0 ? half : -half,
               importance: point.importance > 0 ? half : -half),
      span: half)
  }

  public static func viewport(for quadrant: MatrixQuadrant?) -> MatrixViewport {
    quadrant.map(Self.quadrant) ?? .full
  }

  /// Where a coordinate sits, as an offset in points from the middle of the
  /// drawn square. Positive importance is *up*, so its offset is negated.
  public func offset(
    urgency: Double, importance: Double, plotSize: Double
  ) -> (x: Double, y: Double) {
    let half = plotSize / 2
    return (
      x: ((urgency - centre.urgency) / span) * half,
      y: -((importance - centre.importance) / span) * half
    )
  }

  /// The inverse, clamped to the window.
  public func coordinate(
    offsetX: Double, offsetY: Double, plotSize: Double
  ) -> (urgency: Double, importance: Double) {
    guard plotSize > 0 else { return (centre.urgency, centre.importance) }
    let half = plotSize / 2
    return (
      urgency: clamp(centre.urgency + (offsetX / half) * span, centre: centre.urgency),
      importance: clamp(centre.importance + (-offsetY / half) * span, centre: centre.importance)
    )
  }

  /// The coordinate a drop should commit.
  ///
  /// Snapped to whole steps — the axes are labelled in integers and a stored
  /// 4.37 reads as noise — kept on the viewport's own side of each axis, and
  /// never `(0, 0)`, which is the store's "unplaced" sentinel rather than a
  /// position. All three used to be the view's problem, and the view only knew
  /// about the last one: dropping into a zoomed `Do` could land on zero, which
  /// is the *Schedule* side of the line you were looking at.
  public func placement(
    offsetX: Double, offsetY: Double, plotSize: Double
  ) -> (urgency: Double, importance: Double) {
    let raw = coordinate(offsetX: offsetX, offsetY: offsetY, plotSize: plotSize)
    let point = (urgency: raw.urgency.rounded(), importance: raw.importance.rounded())
    guard point.urgency == 0, point.importance == 0 else { return point }
    // Nudged off the sentinel, along whichever direction this window has room
    // for: a zoomed `Eliminate` has to go negative, everything else positive.
    return (urgency: centre.urgency < 0 ? -1 : 1, importance: point.importance)
  }

  /// Zero is the *lower* side of an axis, the way `MatrixGeometry.quadrant`
  /// reads it. So a window sitting on the positive side starts at 1: a drop
  /// that clamped to zero would be committing a coordinate belonging to the
  /// quadrant next door.
  private func clamp(_ value: Double, centre middle: Double) -> Double {
    let lower = middle > 0 ? 1 : max(-MatrixGeometry.extent, middle - span)
    let upper = middle < 0 ? 0 : min(MatrixGeometry.extent, middle + span)
    return min(upper, max(lower, value))
  }
}
