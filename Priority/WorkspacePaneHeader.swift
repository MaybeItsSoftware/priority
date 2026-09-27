import PriorityCore
import SwiftUI

/// The band across the top of the main pane, whichever mode is in it.
///
/// There were four of these and two absences. Today set its own title at 20pt
/// semibold on an 18pt gutter; the outline used `.title2` on 20; Focus and the
/// timeline used a 10pt micro-label on 24; the board and the matrix had no
/// header at all, so ⌘2 and ⌘4 took the scope name off the screen entirely and
/// ⌘1 and ⌘3 put a differently-sized one back. Switching mode moved the content
/// down by a different amount each time and sometimes told you where you were
/// and sometimes did not.
///
/// One band, one gutter, one type size. What the band says is **where you are**
/// — the scope, and the way back out of it — because which *mode* you are in is
/// the toolbar strip's job and does not need saying twice.
struct WorkspacePaneHeader<Subtitle: View, Trailing: View>: View {
  @Environment(\.theme) private var theme

  let title: String
  @ViewBuilder var subtitle: Subtitle
  @ViewBuilder var trailing: Trailing

  init(
    title: String,
    @ViewBuilder subtitle: () -> Subtitle,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(theme.displayFont(size: Self.titleSize, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        subtitle
      }
      Spacer(minLength: theme.space.sm)
      trailing
    }
    .focusSurfaceBand()
  }

  /// The one figure. Big enough to read as the pane's name, small enough that
  /// the band does not become the loudest thing on a screen of tasks — the
  /// house style puts hierarchy in surface and position rather than in type
  /// size, and 22pt of scope name was arguing with that.
  static var titleSize: CGFloat { 17 }
}

extension WorkspacePaneHeader where Subtitle == EmptyView {
  init(title: String, @ViewBuilder trailing: () -> Trailing) {
    self.init(title: title, subtitle: { EmptyView() }, trailing: trailing)
  }
}

extension WorkspacePaneHeader where Subtitle == EmptyView, Trailing == EmptyView {
  init(title: String) {
    self.init(title: title, subtitle: { EmptyView() }, trailing: { EmptyView() })
  }
}

/// How many tasks the pane is showing, for the right-hand end of a header.
/// Monospaced digits so it does not reflow as the number changes.
struct WorkspacePaneCount: View {
  @Environment(\.theme) private var theme
  let count: Int
  var noun = "open"

  var body: some View {
    Text("\(count) \(noun)")
      .font(theme.monoFont(size: 10))
      .foregroundStyle(theme.dim)
      .monospacedDigit()
  }
}

/// The way out of a task you have opened as a list. It reads as a breadcrumb
/// because that is what it is: the thing you were looking at before this one.
struct WorkspacePaneScopeExit: View {
  @Environment(\.theme) private var theme
  let title: String
  let leave: () -> Void

  var body: some View {
    Button(action: leave) {
      HStack(spacing: 3) {
        Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
        Text(title).lineLimit(1).truncationMode(.middle)
      }
      .font(theme.bodyFont(size: 11))
      .foregroundStyle(theme.muted)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable()
    .commandHelp(.planLeaveTask, note: "Back to \(title)")
  }
}
