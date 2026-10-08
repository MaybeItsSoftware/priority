import TaktCore
import TaktWorkspace
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

  /// A hairline in the focus colour only for a cursor that is not on the
  /// selection — the sidebar's, standing on a row that selects nothing — where
  /// the fill alone could not tell it from a resting selection. A selected row
  /// says "and the keys land here" with the stronger fill: a square band with
  /// its own hairline, flush against a pane that already draws a focus border,
  /// read as a box jammed inside a box.
  private var border: Color { hasKeyboard && !isSelected ? theme.focusRing : .clear }

  /// The whole of the row, edge to edge and square unless a caller asks for
  /// a radius: the band is the row's area, so it shows exactly what a click
  /// or a key will act on. It used to be a rounded band inset from the row,
  /// which left a margin of row around it that looked unselected.
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius ?? 0, style: .continuous)
    shape
      .fill(theme.color(.primary, opacity: fill))
      .overlay(
        shape.strokeBorder(border, lineWidth: theme.hairline)
      )
      .animation(WorkspaceMotion.quick, value: fill)
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

/// What stands in a task row's glyph column.
///
/// A ticked task shows its check until it lingers out. An open one shows
/// nothing at the top level and `└` beneath a parent, so the column says how
/// a row hangs rather than repeating an empty box down the page; the circle
/// comes back under the pointer, where it is a button to tick. A list keeps
/// its icon, since opening it is what the glyph does.
struct WorkspaceTaskMarker: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var isHovered = false
  let task: WorkspaceTask
  var isSubtask = false

  var body: some View {
    Group {
      if task.isList {
        Image(systemName: model.itemSymbol(for: task)).foregroundStyle(theme.muted)
      } else if task.status != .open {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
      } else if isHovered {
        Image(systemName: "circle").foregroundStyle(theme.muted)
      } else if isSubtask {
        Text("└").font(theme.monoCaptionFont).foregroundStyle(theme.dim)
      } else {
        // Held at the circle's size, so the row's height and the hover
        // target are the same whichever mark shows.
        Image(systemName: "circle").hidden()
      }
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
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

  /// A row's text, cut to `lineLimit` lines while the row is one of many and
  /// shown whole once it is the selected one: the row grows to fit rather than
  /// hiding the end of the title the cursor is on.
  ///
  /// The vertical `fixedSize` is what makes it wrap: inside a stack that
  /// offers it one line's height, text with no limit still clips.
  func expandsWhenSelected(
    _ isSelected: Bool, lineLimit: Int = 1, truncation: Text.TruncationMode = .tail
  ) -> some View {
    self
      .lineLimit(isSelected ? nil : lineLimit)
      .truncationMode(truncation)
      .fixedSize(horizontal: false, vertical: isSelected)
  }
}
