import SwiftUI
import TaktCore

/// The line drawn between a subtask's row and its card in another column,
/// while the selection or the pointer is on either end.
///
/// The cards stack as they would with no links, and each end names the other
/// in words (`BoardLinks`). The line is laid over the board on top of that:
/// each lit end reports its frame as an anchor, the strip collects them, and
/// `BoardLinkRoute` works out the path from the frames as they are. Nothing
/// it draws is measured or fed back into a card, so it cannot move one.
///
/// Only the lit links report frames, so a board with no selection on a link
/// has no anchors to collect and draws nothing.

/// What a frame reported to the line overlay belongs to.
enum WorkspaceBoardLinkAnchor: Hashable {
  /// The row, or the heading's label, on the parent's card that stands for
  /// the subtask, by the subtask's id.
  case source(String)
  /// The heading of the subtask's own card, by its id.
  case target(String)
  /// A column, by its id: the line turns on the rule beside it.
  case column(String)
  /// A column's scrolling cards, by the column's id: the line is clipped to
  /// them, so one to a card scrolled out of sight stops at the column's edge
  /// rather than running over its header.
  case cards(String)
}

struct WorkspaceBoardLinkAnchorKey: PreferenceKey {
  static var defaultValue: [WorkspaceBoardLinkAnchor: Anchor<CGRect>] { [:] }

  static func reduce(
    value: inout [WorkspaceBoardLinkAnchor: Anchor<CGRect>],
    nextValue: () -> [WorkspaceBoardLinkAnchor: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { first, _ in first }
  }
}

extension View {
  /// Reports this view's frame to the line overlay as `anchor`, while
  /// `active`; nothing otherwise.
  func boardLinkAnchor(_ anchor: WorkspaceBoardLinkAnchor, active: Bool) -> some View {
    anchorPreference(key: WorkspaceBoardLinkAnchorKey.self, value: .bounds) { active ? [anchor: $0] : [:] }
  }

  /// Reports this view's frame as the source end of every link in `ids`
  /// that is lit — a heading's label stands for several.
  func boardLinkSources(_ ids: [String], lit: Set<String>) -> some View {
    anchorPreference(key: WorkspaceBoardLinkAnchorKey.self, value: .bounds) { anchor in
      var anchors: [WorkspaceBoardLinkAnchor: Anchor<CGRect>] = [:]
      for id in ids where lit.contains(id) { anchors[.source(id)] = anchor }
      return anchors
    }
  }
}

/// The lit links' lines, drawn over the column strip.
struct WorkspaceBoardLinkLines: View {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let links: [BoardLinks.Link]
  /// The board's column ids, left to right, for finding a link's columns.
  let columnIDs: [String]
  let anchors: [WorkspaceBoardLinkAnchor: Anchor<CGRect>]

  /// One link's path, once both of its ends and its column are on screen.
  private struct Line: Identifiable {
    let id: String
    let path: BoardLinkRoute.Path
  }

  var body: some View {
    GeometryReader { proxy in
      let lines = lines(in: proxy)
      ZStack(alignment: .topLeading) {
        ForEach(lines) { line in
          WorkspaceBoardLinkShape(path: line.path)
            .stroke(theme.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .transition(.opacity)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      .mask(alignment: .topLeading) { clip(in: proxy) }
      // A fade in and out as the selection or the pointer reaches an end,
      // collapsed rather than removed under Reduce Motion.
      .animation(
        .easeOut(duration: reduceMotion ? 0.01 : WorkspaceMotion.duration), value: lines.map(\.id))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// The house hairline, half as heavy again: it is the one line on the
  /// board that crosses cards, and at a bare hairline it read as their rules.
  private var lineWidth: CGFloat {
    min(max(theme.hairline * 1.5, 1), 1.5)
  }

  private func lines(in proxy: GeometryProxy) -> [Line] {
    let inset = Double(theme.space.xxs)
    let rail = Double(theme.hairline) / 2
    let radius = Double(WorkspaceBoardMetrics.linkCornerRadius)
    return links.compactMap { link in
      guard columnIDs.indices.contains(link.sourceColumn),
        let source = anchors[.source(link.childID)],
        let target = anchors[.target(link.childID)],
        let column = anchors[.column(columnIDs[link.sourceColumn])]
      else { return nil }
      let path = BoardLinkRoute.path(
        from: Self.rect(proxy[source]), to: Self.rect(proxy[target]), sourceColumn: Self.rect(proxy[column]),
        pointsForward: link.pointsForward, inset: inset, rail: rail, radius: radius)
      return Line(id: link.childID, path: path)
    }
  }

  /// The band the columns' cards scroll in, the board's width across: the
  /// line may cross a column whose cards did not report, so only the band's
  /// top and bottom come from the columns that did.
  @ViewBuilder private func clip(in proxy: GeometryProxy) -> some View {
    let bands = anchors.compactMap { key, anchor -> CGRect? in
      if case .cards = key { return proxy[anchor] }
      return nil
    }
    if let top = bands.map(\.minY).min(), let bottom = bands.map(\.maxY).max(), bottom > top {
      Rectangle()
        .frame(width: proxy.size.width, height: bottom - top)
        .offset(y: top)
    } else {
      Rectangle()
    }
  }

  private static func rect(_ rect: CGRect) -> BoardLinkRoute.Rect {
    BoardLinkRoute.Rect(
      minX: Double(rect.minX), minY: Double(rect.minY), maxX: Double(rect.maxX), maxY: Double(rect.maxY))
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
