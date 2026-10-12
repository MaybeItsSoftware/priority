import Observation
import SwiftUI
import TaktCore

/// The line drawn between a subtask's row and its card in another column: a
/// hairline at rest, the accent while the selection or the pointer is on
/// either end.
///
/// The cards stack as they would with no links, and each end names the other
/// in words (`BoardLinks`), which still says where a line goes once one of
/// its ends has scrolled away. The lines are laid over and under the board
/// on top of that: each end measures itself into
/// `WorkspaceBoardLinkGeometry`, and `BoardLinkRoute` works out the paths
/// from the frames as they are, each in a lane of its own beside the rule it
/// turns on.
///
/// The ends used to report anchor preferences, which never reached the
/// overlay: a column and its card scroller reported anchors of their own with
/// `anchorPreference`, which *replaces* whatever the views inside it set
/// rather than merging with it, so every row's and heading's anchor was
/// dropped on the way up and the overlay only ever saw the columns.

/// One end of a link, by the subtask's id.
enum WorkspaceBoardLinkEnd: Hashable {
  /// The row, or the heading's label, on the parent's card that stands for
  /// the subtask.
  case source(String)
  /// The heading of the subtask's own card.
  case target(String)
}

/// Where the board's link ends are, held by the column strip rather than the
/// view model: it is layout, not state, and only the line overlay reads it.
///
/// Each end is measured in its own column's card stack, so scrolling a
/// column changes nothing here but the stack's origin — one value per column
/// rather than one per end. Every write rounds to half a point and is skipped
/// when nothing changed, so a layout pass that moves nothing invalidates
/// nothing.
///
/// It also works out the space each subtask card opens above itself so its
/// line runs flat (`BoardLinkNudge`), which the columns read. That is
/// settled once the layout has, after any change to where an end sits in
/// its column: never on a scroll, which moves only the stacks, and never
/// mid-pass, since every end a pass moves has reported by the time it runs.
@MainActor
@Observable
final class WorkspaceBoardLinkGeometry {
  /// The coordinate space of the column strip: the columns' content, inside
  /// the sideways scroller, so it moves with them.
  nonisolated static let boardSpace = "WorkspaceBoardLinkGeometry.board"

  /// A column's card stack, by the column's id.
  struct StackSpace: Hashable {
    let columnID: String
  }

  /// Each end's frame in its column's card stack.
  private(set) var ends: [WorkspaceBoardLinkEnd: CGRect] = [:]
  /// Each column's frame on the board, by id: the line turns on the rule
  /// beside it.
  private(set) var columns: [String: CGRect] = [:]
  /// Where each column's card stack starts on the board, by the column's id.
  /// It moves as the column scrolls.
  private(set) var stacks: [String: CGPoint] = [:]
  /// The part of each column the cards scroll in, on the board, by the
  /// column's id: a line is clipped to it, so one to a card scrolled out of
  /// sight stops at the band's edge rather than running over the headers.
  private(set) var bands: [String: CGRect] = [:]
  /// The space opened above each subtask card so its line runs flat, by
  /// its id. Only the columns read it.
  private(set) var nudges: [String: CGFloat] = [:]

  /// The board's links and columns, for settling the nudges.
  @ObservationIgnored private var links: [BoardLinks.Link] = []
  @ObservationIgnored private var columnIDs: [String] = []
  @ObservationIgnored private var settleScheduled = false
  /// Settles in a row that each changed something. A layout that keeps
  /// answering a nudge with a different one stops being nudged rather than
  /// shaking; a change to the links starts it again.
  @ObservationIgnored private var unsettledRuns = 0
  private static let maximumUnsettledRuns = 6

  func setEnds(_ ids: [WorkspaceBoardLinkEnd], _ rect: CGRect) {
    let rect = Self.rounded(rect)
    var changed = false
    for id in ids where ends[id] != rect {
      ends[id] = rect
      changed = true
    }
    if changed { scheduleSettle() }
  }

  func setColumn(_ id: String, frame: CGRect) {
    let frame = Self.rounded(frame)
    if columns[id] != frame { columns[id] = frame }
  }

  func setStack(_ id: String, origin: CGPoint) {
    let origin = CGPoint(x: Self.half(origin.x), y: Self.half(origin.y))
    if stacks[id] != origin { stacks[id] = origin }
  }

  func setBand(_ id: String, frame: CGRect) {
    let frame = Self.rounded(frame)
    guard bands[id] != frame else { return }
    let moved = bands[id]?.minY != frame.minY
    bands[id] = frame
    if moved { scheduleSettle() }
  }

  /// Takes the board's links and columns, and forgets the ends of links it
  /// no longer has. An end whose view has only scrolled out of a lazy stack
  /// keeps its frame: the stack keeps its place too, so the frame is still
  /// where the end would be.
  func setLayout(_ links: BoardLinks, columnIDs: [String]) {
    let stale = ends.keys.filter { end in
      switch end {
      case .source(let id), .target(let id): links.link(forChild: id) == nil
      }
    }
    for end in stale { ends[end] = nil }
    self.links = links.byChild.values.sorted { $0.childID < $1.childID }
    self.columnIDs = columnIDs
    unsettledRuns = 0
    scheduleSettle()
  }

  /// Settles the nudges once the layout pass under way has reported every
  /// end it moved.
  private func scheduleSettle() {
    guard !settleScheduled else { return }
    settleScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      settleScheduled = false
      settle()
    }
  }

  private func settle() {
    let current = nudges.mapValues(Double.init)
    let measured = links.map { link in
      BoardLinkNudge.End(
        childID: link.childID, sourceColumn: link.sourceColumn, childColumn: link.childColumn,
        sourceY: unscrolledMidY(of: .source(link.childID), inColumn: link.sourceColumn),
        targetY: unscrolledMidY(of: .target(link.childID), inColumn: link.childColumn))
    }
    let next = BoardLinkNudge.offsets(for: measured, current: current, cap: WorkspaceBoardMetrics.linkNudgeCap)
    guard next != current else {
      unsettledRuns = 0
      return
    }
    unsettledRuns += 1
    guard unsettledRuns <= Self.maximumUnsettledRuns else { return }
    nudges = next.mapValues { CGFloat($0) }
  }

  /// An end's middle as it would be on the board if no column were
  /// scrolled: its height in its stack, from the top of its column's band.
  private func unscrolledMidY(of end: WorkspaceBoardLinkEnd, inColumn column: Int) -> Double? {
    guard columnIDs.indices.contains(column), let rect = ends[end], let band = bands[columnIDs[column]] else {
      return nil
    }
    return Double(band.minY + rect.midY)
  }

  /// An end's frame on the board, once it and its column's stack are known.
  func boardFrame(of end: WorkspaceBoardLinkEnd, inColumn columnID: String) -> CGRect? {
    guard let rect = ends[end], let origin = stacks[columnID] else { return nil }
    return rect.offsetBy(dx: origin.x, dy: origin.y)
  }

  private static func half(_ value: CGFloat) -> CGFloat {
    (value * 2).rounded() / 2
  }

  private static func rounded(_ rect: CGRect) -> CGRect {
    CGRect(x: half(rect.minX), y: half(rect.minY), width: half(rect.width), height: half(rect.height))
  }
}

extension View {
  /// Measures this view as the ends in `ids` — a heading's label stands for
  /// several — in `columnID`'s card stack.
  func boardLinkEnds(
    _ ids: [WorkspaceBoardLinkEnd], inColumn columnID: String, geometry: WorkspaceBoardLinkGeometry?
  ) -> some View {
    onGeometryChange(for: WorkspaceBoardLinkMeasure.self) { proxy in
      WorkspaceBoardLinkMeasure(
        ids: ids,
        rect: ids.isEmpty
          ? .zero : proxy.frame(in: .named(WorkspaceBoardLinkGeometry.StackSpace(columnID: columnID))))
    } action: { measure in
      guard !measure.ids.isEmpty else { return }
      geometry?.setEnds(measure.ids, measure.rect)
    }
  }
}

/// What an end measures: which ends it is, as well as where, so an end that
/// becomes one without moving still reports.
struct WorkspaceBoardLinkMeasure: Equatable {
  let ids: [WorkspaceBoardLinkEnd]
  let rect: CGRect
}

/// The links' lines, in one of the two layers they are drawn in.
///
/// Every link has a line. At rest it is a dashed hairline in the dim text's
/// colour, so it never reads as a card's or a column's rule; lit, it is the
/// accent, solid and half as heavy again, over everything. A resting line
/// that crosses a column on its way runs beneath that column's cards, which
/// are opaque, so it reads as passing under them rather than scribbling over
/// cards that have nothing to do with it; over its own two columns it is
/// drawn on top, so it still runs unbroken from the row's mark to the card.
struct WorkspaceBoardLinkLines: View {
  /// Which of the board's two line layers this is.
  enum Layer {
    /// Behind the columns: resting lines that cross a column.
    case beneath
    /// Over the columns: resting lines over their own two columns, and lit
    /// ones.
    case above
  }

  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let layer: Layer
  let geometry: WorkspaceBoardLinkGeometry
  /// Every link on the board, in a stable order.
  let links: [BoardLinks.Link]
  /// The lit ones, by subtask id.
  let lit: Set<String>
  /// The board's column ids, left to right, for finding a link's columns.
  let columnIDs: [String]
  /// The space between two columns, which a line turns in.
  let gutter: CGFloat

  /// One link's path, once both of its ends and its column are measured.
  private struct Line: Identifiable {
    let id: String
    let path: BoardLinkRoute.Path
    /// Whether it crosses a column on its way, rather than running to the
    /// next one.
    let crosses: Bool
    /// Its two columns, with the gutter either side: where a crossing line
    /// is drawn over the cards.
    let ends: [CGRect]
  }

  var body: some View {
    GeometryReader { proxy in
      let lines = lines()
      let resting = lines.filter { line in !lit.contains(line.id) && (layer == .above || line.crosses) }
      let lighted = layer == .above ? lines.filter { lit.contains($0.id) } : []
      ZStack(alignment: .topLeading) {
        ForEach(resting) { line in
          WorkspaceBoardLinkShape(path: line.path)
            .stroke(
              theme.dim,
              style: StrokeStyle(
                lineWidth: theme.hairline, lineCap: .butt, lineJoin: .round, dash: WorkspaceBoardMetrics.linkRestingDash))
            .mask {
              if layer == .above && line.crosses {
                Path { $0.addRects(line.ends) }
              } else {
                Rectangle()
              }
            }
        }
        ForEach(lighted) { line in
          WorkspaceBoardLinkShape(path: line.path)
            .stroke(theme.primary, style: StrokeStyle(lineWidth: litWidth, lineCap: .round, lineJoin: .round))
            .transition(.opacity)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .clipShape(band(height: proxy.size.height))
      // A fade in and out as the selection or the pointer reaches an end,
      // collapsed rather than removed under Reduce Motion.
      .animation(
        .easeOut(duration: reduceMotion ? 0.01 : WorkspaceMotion.duration), value: lighted.map(\.id))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// The house hairline, half as heavy again: it is the one line on the
  /// board that crosses cards, and at a bare hairline it read as their rules.
  private var litWidth: CGFloat {
    min(max(theme.hairline * 1.5, 1), 1.5)
  }

  private func lines() -> [Line] {
    let inset = Double(theme.space.xxs)
    let radius = Double(WorkspaceBoardMetrics.linkCornerRadius)
    // Every measured link's ends on the board, for its lane and its path.
    let ends: [(link: BoardLinks.Link, source: CGRect, target: CGRect, column: CGRect)] = links.compactMap { link in
      guard columnIDs.indices.contains(link.sourceColumn), columnIDs.indices.contains(link.childColumn),
        let source = geometry.boardFrame(of: .source(link.childID), inColumn: columnIDs[link.sourceColumn]),
        let target = geometry.boardFrame(of: .target(link.childID), inColumn: columnIDs[link.childColumn]),
        let column = geometry.columns[columnIDs[link.sourceColumn]]
      else { return nil }
      return (link, source, target, column)
    }
    let half = gutter / 2
    let lanes = BoardLinkRoute.lanes(
      for: ends.map {
        BoardLinkRoute.LaneRequest(
          id: $0.link.childID, sourceColumn: $0.link.sourceColumn, pointsForward: $0.link.pointsForward,
          sourceY: Double($0.source.midY), targetY: Double($0.target.midY))
      },
      spacing: WorkspaceBoardMetrics.linkLaneSpacing,
      width: WorkspaceBoardMetrics.linkLaneWidth(theme))
    return ends.map { end in
      let rail = Double(gutter) / 2 + (lanes[end.link.childID] ?? 0)
      let path = BoardLinkRoute.path(
        from: Self.rect(end.source), to: Self.rect(end.target), sourceColumn: Self.rect(end.column),
        pointsForward: end.link.pointsForward, inset: inset, rail: rail, radius: radius)
      let ends = [end.column, geometry.columns[columnIDs[end.link.childColumn]]].compactMap { frame in
        frame.map { CGRect(x: $0.minX - half, y: $0.minY, width: $0.width + 2 * half, height: $0.height) }
      }
      return Line(
        id: end.link.childID, path: path, crosses: abs(end.link.childColumn - end.link.sourceColumn) > 1, ends: ends)
    }
  }

  /// The band the columns' cards scroll in, the board's width across: the
  /// line may cross a column whose band is not measured, so only the band's
  /// top and bottom come from the columns that are.
  private func band(height: CGFloat) -> WorkspaceBoardLinkBand {
    let bands = geometry.bands.values
    guard let top = bands.map(\.minY).min(), let bottom = bands.map(\.maxY).max(), bottom > top else {
      return WorkspaceBoardLinkBand(top: 0, bottom: 0)
    }
    return WorkspaceBoardLinkBand(top: max(top, 0), bottom: max(height - bottom, 0))
  }

  private static func rect(_ rect: CGRect) -> BoardLinkRoute.Rect {
    BoardLinkRoute.Rect(
      minX: Double(rect.minX), minY: Double(rect.minY), maxX: Double(rect.maxX), maxY: Double(rect.maxY))
  }
}

/// The board's height between `top` and `bottom` of it, its width across:
/// the band a line is clipped to.
private struct WorkspaceBoardLinkBand: Shape {
  let top: CGFloat
  let bottom: CGFloat

  func path(in rect: CGRect) -> Path {
    Path(CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: max(rect.height - top - bottom, 0)))
  }
}

/// A route's corners joined by straight legs and rounded where they turn.
private struct WorkspaceBoardLinkShape: Shape {
  let path: BoardLinkRoute.Path

  func path(in rect: CGRect) -> Path {
    var drawn = Path()
    let points = path.points.map { CGPoint(x: $0.x, y: $0.y) }
    guard let first = points.first else { return drawn }
    drawn.move(to: first)
    for index in points.indices.dropFirst() {
      let radius = path.radii[index]
      if radius > 0, index + 1 < points.count {
        drawn.addArc(tangent1End: points[index], tangent2End: points[index + 1], radius: radius)
      } else {
        drawn.addLine(to: points[index])
      }
    }
    return drawn
  }
}
