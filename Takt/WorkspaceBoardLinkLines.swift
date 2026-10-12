import Observation
import SwiftUI
import TaktCore
import os

/// The line drawn between a subtask's row and its card in another column,
/// while the selection or the pointer is on either end.
///
/// The cards stack as they would with no links, and each end names the other
/// in words (`BoardLinks`). The line is laid over the board on top of that:
/// each end measures itself into `WorkspaceBoardLinkGeometry`, and
/// `BoardLinkRoute` works out the path from the frames as they are.
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

  func setEnds(_ ids: [WorkspaceBoardLinkEnd], _ rect: CGRect) {
    let rect = Self.rounded(rect)
    for id in ids where ends[id] != rect { ends[id] = rect }
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
    if bands[id] != frame { bands[id] = frame }
  }

  /// Forgets the ends of links the board no longer has. An end whose view
  /// has only scrolled out of a lazy stack keeps its frame: the stack keeps
  /// its place too, so the frame is still where the end would be.
  func retain(_ links: BoardLinks) {
    let stale = ends.keys.filter { end in
      switch end {
      case .source(let id), .target(let id): links.link(forChild: id) == nil
      }
    }
    for end in stale { ends[end] = nil }
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

/// The lit links' lines, drawn over the column strip.
struct WorkspaceBoardLinkLines: View {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let geometry: WorkspaceBoardLinkGeometry
  let links: [BoardLinks.Link]
  /// The board's column ids, left to right, for finding a link's columns.
  let columnIDs: [String]

  /// One link's path, once both of its ends and its column are measured.
  private struct Line: Identifiable {
    let id: String
    let path: BoardLinkRoute.Path
  }

  var body: some View {
    GeometryReader { proxy in
      let lines = lines()
      ZStack(alignment: .topLeading) {
        ForEach(lines) { line in
          WorkspaceBoardLinkShape(path: line.path)
            .stroke(theme.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .transition(.opacity)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .clipShape(band(height: proxy.size.height))
      // A fade in and out as the selection or the pointer reaches an end,
      // collapsed rather than removed under Reduce Motion.
      .animation(
        .easeOut(duration: reduceMotion ? 0.01 : WorkspaceMotion.duration), value: lines.map(\.id))
      // MARK: Temporary BoardLinkLines diagnostics — remove once confirmed.
      .onChange(of: links.map(\.childID), initial: true) { _, lit in
        Self.logLit(lit, drawn: Set(lines.map(\.id)))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// The house hairline, half as heavy again: it is the one line on the
  /// board that crosses cards, and at a bare hairline it read as their rules.
  private var lineWidth: CGFloat {
    min(max(theme.hairline * 1.5, 1), 1.5)
  }

  private func lines() -> [Line] {
    let inset = Double(theme.space.xxs)
    let rail = Double(theme.hairline) / 2
    let radius = Double(WorkspaceBoardMetrics.linkCornerRadius)
    return links.compactMap { link in
      guard columnIDs.indices.contains(link.sourceColumn), columnIDs.indices.contains(link.childColumn),
        let source = geometry.boardFrame(of: .source(link.childID), inColumn: columnIDs[link.sourceColumn]),
        let target = geometry.boardFrame(of: .target(link.childID), inColumn: columnIDs[link.childColumn]),
        let column = geometry.columns[columnIDs[link.sourceColumn]]
      else { return nil }
      let path = BoardLinkRoute.path(
        from: Self.rect(source), to: Self.rect(target), sourceColumn: Self.rect(column),
        pointsForward: link.pointsForward, inset: inset, rail: rail, radius: radius)
      return Line(id: link.childID, path: path)
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

// MARK: - Temporary BoardLinkLines diagnostics
//
// Logs, whenever the lit links change, how many there are, how many drew a
// line and which did not, so the installed app can show whether the ends are
// being measured: `log stream --level info --predicate 'subsystem ==
// "uk.co.maybeitssoftware.takt" && category == "BoardLinkLines"'`. To be
// removed once the lines are confirmed on screen.
extension WorkspaceBoardLinkLines {
  private static let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "BoardLinkLines")

  fileprivate static func logLit(_ lit: [String], drawn: Set<String>) {
    guard !lit.isEmpty else { return }
    let missing = lit.filter { !drawn.contains($0) }
    logger.notice(
      "lit=\(lit.count, privacy: .public) drawn=\(drawn.count, privacy: .public) missing=\(missing, privacy: .public)")
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
