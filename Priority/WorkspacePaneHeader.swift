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
    // The subtitle sits on the title's baseline rather than under it. Stacked,
    // it made the band a line taller in the modes that carry one (Today, the
    // matrix, Focus, the timeline) than in those that do not (the board and the
    // outline until a task is opened as a list), so ⌘1→⌘2 still moved the
    // content down.
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
      // The theme's title role, deliberately only a step above body: the house
      // style puts hierarchy in surface and position, and a scope name at
      // 17–22pt was arguing with a screen of tasks.
      Text(title)
        .font(theme.titleFont)
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
      subtitle
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .lineLimit(1)
      Spacer(minLength: theme.space.sm)
      trailing
    }
    // Tall enough for the tallest trailing control, so the band is one height
    // whichever mode is in it rather than growing to fit what a mode carries.
    .frame(minHeight: theme.space.xl)
    .padding(.horizontal, FocusSurfaceMetrics.gutter)
    .padding(.vertical, theme.space.sm)
  }
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
      .font(theme.monoFont(size: theme.type.microLabel.size))
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
      HStack(spacing: theme.space.xxs) {
        Image(systemName: "chevron.left")
        Text(title).lineLimit(1).truncationMode(.middle)
      }
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable()
    .commandHelp(.planLeaveTask, note: "Back to \(title)")
  }
}

/// A named group of controls in the inspector.
///
/// The inspector was one flat run of about twenty-five controls with two
/// hand-rolled eyebrows in it ("NOTES", "LINKS", both at `caption2` rather than
/// the micro-label's 10pt with tracking) and no grouping anywhere else, so
/// finding the estimate field meant reading every label on the way down.
struct InspectorSection<Content: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      MicroLabel(title)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A sheet's own title, and optionally the thing it is about.
///
/// Seven sheets set this themselves: five at `.title3.weight(.semibold)`, the
/// conditions editor at plain `.title2`, and the add-list popover at
/// `.headline`. A sheet is the most modal thing in the app and the least
/// forgiving place to be guessing at hierarchy.
struct SheetTitle: View {
  @Environment(\.theme) private var theme
  let title: String
  var subject: String?

  init(_ title: String, subject: String? = nil) {
    self.title = title
    self.subject = subject
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      Text(title)
        .font(theme.titleFont)
        .foregroundStyle(theme.ink)
      if let subject {
        Text(subject)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .lineLimit(2)
          .truncationMode(.tail)
          .help(subject)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
