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
  /// The edge of a resting selection: present but quiet, because the focus
  /// ring is reserved for the keyboard.
  static let restingBorder = 0.55
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

  private var border: Color {
    if hasKeyboard { return theme.focusRing }
    return isSelected ? theme.color(.primary, opacity: WorkspaceSelection.restingBorder) : .clear
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius ?? theme.controlRadius, style: .continuous)
    shape
      .fill(theme.color(.primary, opacity: fill))
      .overlay(
        shape.strokeBorder(border, lineWidth: hasKeyboard ? theme.focusRingWidth : theme.hairline)
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
