import PriorityCore
import SwiftUI

/// One way of drawing "this is the thing you have selected", and one way of
/// drawing "and this is where the keyboard is".
///
/// Before this there were six. The outline row filled at 0.14, the board card
/// and the move sheet at 0.17, search at 0.18, the palette at 0.16, and the
/// sidebar at 0.13 — all of them `Color.accentColor` rather than the theme's,
/// and no two agreeing on what selection looks like. Worse, only the sidebar
/// drew the *second* fact: five surfaces out of six could not tell you whether
/// the row you were looking at would answer the arrow keys.
///
/// That second fact is the one a keyboard-first app cannot leave out. It is why
/// an editor gives the active pane a border and the others none — the question
/// "will this respond to me" has to be answerable without pressing anything.
///
/// The figures are the sidebar's, because they were the only pair that had been
/// tuned against each other rather than each chosen alone.
enum WorkspaceSelection {
  /// Selected *and* under the keyboard. The loudest state on screen.
  static let activeFill = 0.24
  /// Selected, but the keyboard is elsewhere — the list stays open behind the
  /// task surface, the task stays chosen behind the inspector.
  static let restingFill = 0.13
  /// Under the keyboard without being the selection. Reachable wherever a
  /// cursor can stand on a row that selects nothing, as it can in the sidebar
  /// on Focus and the timeline.
  static let cursorFill = 0.12
}

/// The house selection treatment.
///
/// `hasKeyboard` is whether the keyboard is on **this row** — the region is
/// focused *and* this is the row the arrows would move from. For most surfaces
/// the cursor and the selection are the same object, so it is simply "does my
/// region have focus"; in the sidebar they come apart, which is what the
/// keyboard-without-selection state is for.
struct WorkspaceSelectionBackground: View {
  @Environment(\.theme) private var theme
  var isSelected = false
  var hasKeyboard = false
  var radius: CGFloat?

  private var fill: Double {
    if isSelected { return hasKeyboard ? WorkspaceSelection.activeFill : WorkspaceSelection.restingFill }
    return hasKeyboard ? WorkspaceSelection.cursorFill : 0
  }

  /// A hairline in the focus colour while the keyboard is on the row, and
  /// nothing otherwise — the way an editor's project panel marks its cursor.
  /// A resting selection used to carry a primary edge too and the keyboard a
  /// two-point ring, which drew every selected row as a box inside the pane;
  /// the fill is what says "selected", the line only "and the keys land here".
  private var border: Color { hasKeyboard ? theme.focusRing : .clear }

  /// The row radius rather than the control one: a selection is the line
  /// being chosen, full width of its pane, not a button inside it. Zero in
  /// the built-ins, so the band and its keyboard hairline are square like
  /// Zed's project panel; a theme can round them again.
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius ?? theme.rowRadius, style: .continuous)
    shape
      .fill(theme.color(.primary, opacity: fill))
      .overlay(
        shape.strokeBorder(border, lineWidth: theme.hairline)
      )
  }
}

extension View {
  /// The treatment as a modifier, for the majority of call sites that want it
  /// behind a row they are already building.
  func workspaceSelection(
    isSelected: Bool,
    hasKeyboard: Bool,
    radius: CGFloat? = nil
  ) -> some View {
    background(
      WorkspaceSelectionBackground(
        isSelected: isSelected,
        hasKeyboard: hasKeyboard,
        radius: radius
      )
    )
  }
}

/// The geometry a tree's rows share — the sidebar's and the outline's — so a
/// nested list and a subtask step in by the same amount and hang their glyphs
/// in the same column.
enum WorkspaceRowMetrics {
  /// The icon column. Wide enough for the widest symbol the rows draw at body
  /// size, so names line up whichever glyph precedes them.
  static let iconWidth: CGFloat = 18

  /// One indent step: the icon column plus the gap after it, so a child's
  /// glyph sits under its parent's name and a guide hung from the parent's
  /// glyph runs clear of the child's.
  static func indent(_ theme: Theme) -> CGFloat { iconWidth + theme.space.sm }
}

/// Indent guides: a hairline down the row at each ancestor's depth, the way
/// an editor's project panel draws its tree.
///
/// Indentation alone stops saying *whose* child a row is once the parent has
/// scrolled away or two branches sit at nearly the same depth; a line under
/// each ancestor's glyph keeps the branch visible. Drawn as a background of
/// the row rather than of the list, so it scrolls, animates and disappears
/// with the rows it belongs to — and because rows are laid edge to edge with
/// no gap between them, one row's guide meets the next one's and the lines
/// read as continuous.
struct WorkspaceIndentGuides: View {
  @Environment(\.theme) private var theme
  /// How many ancestors the row has — one guide each.
  let depth: Int
  /// The x of the outermost guide, measured from the row's leading edge.
  let origin: CGFloat
  /// The distance between one depth and the next.
  let step: CGFloat

  var body: some View {
    let colour = theme.border
    let width = theme.hairline
    Canvas { context, size in
      for level in 0..<max(depth, 0) {
        let x = (origin + CGFloat(level) * step).rounded(.down)
        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(colour))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

extension View {
  /// Guides behind a row at `depth`. Apply it inside the row's selection, so
  /// the guides sit in front of the fill and a chosen row keeps them, the way
  /// Zed's does.
  func workspaceIndentGuides(depth: Int, origin: CGFloat, step: CGFloat) -> some View {
    background {
      if depth > 0 {
        WorkspaceIndentGuides(depth: depth, origin: origin, step: step)
      }
    }
  }
}
