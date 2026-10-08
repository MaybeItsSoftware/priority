import TaktCore
import SwiftUI

/// The band across the top of the main pane, whichever mode is in it: where
/// you are on the left, a count or a few icon buttons on the right. Drawn on
/// `WorkspaceHeaderBand`, the band the sidebar and the dock share.
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
  /// When set, the title is a switcher: clicking it opens the list finder,
  /// the way Zed's title bar opens its project picker from the project name.
  var switchesList = false
  @ViewBuilder var subtitle: Subtitle
  @ViewBuilder var trailing: Trailing

  init(
    title: String,
    switchesList: Bool = false,
    @ViewBuilder subtitle: () -> Subtitle,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.switchesList = switchesList
    self.subtitle = subtitle()
    self.trailing = trailing()
  }

  var body: some View {
    WorkspaceHeaderBand {
      // The subtitle sits on the title's baseline rather than under it. Stacked,
      // it made the band a line taller in the modes that carry one (Today, the
      // matrix, Focus, the timeline) than in those that do not (the board and the
      // outline until a task is opened as a list), so ⌘1→⌘2 still moved the
      // content down.
      HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
        // The theme's title role, deliberately only a step above body: the
        // house style puts hierarchy in surface and position, and a scope name
        // at 17–22pt was arguing with a screen of tasks.
        Group {
          if switchesList {
            WorkspaceListSwitcherTitle(title: title)
          } else {
            Text(title)
              .font(theme.titleFont)
              .foregroundStyle(theme.ink)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .layoutPriority(1)
        subtitle
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .lineLimit(1)
      }
      Spacer(minLength: theme.space.sm)
      // Held to its own size: a trailing control that grew with the pane
      // would push the band past its one fixed height.
      HStack(spacing: theme.space.xs) {
        trailing
      }
      .lineLimit(1)
      .fixedSize()
    }
  }
}

/// The pane title as a way to the list finder: the name, a small chevron, and
/// the hover fill every header control has. ⌘P and `gl` were the only ways
/// in, and nothing on the screen said so.
private struct WorkspaceListSwitcherTitle: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let title: String
  @State private var isHovered = false

  var body: some View {
    Button { model.presentOverlay(.listNavigator) } label: {
      HStack(spacing: theme.space.xxs) {
        Text(title)
          .font(theme.titleFont)
          .foregroundStyle(theme.ink)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.down")
          .font(theme.captionFont)
          .foregroundStyle(isHovered ? theme.ink : theme.muted)
      }
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs)
      .background(
        RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
          .fill(isHovered ? theme.hover : .clear))
      // Back by the padding, so the name still sits over the text beneath it.
      .padding(.horizontal, -theme.space.xs)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable()
    .onHover { isHovered = $0 }
    .commandHelp(.goListNavigator, note: "Go to another list")
  }
}

/// The band every column's header is drawn on — the main pane's, the
/// sidebar's, and the right dock's tab bar.
///
/// Its height is `theme.paneHeaderHeight` and its hairline is drawn *inside*
/// that height, so a band is the same number of points whatever it holds. That
/// is what lets the rule under the sidebar, the pane and the dock run straight
/// across the window as one line, the way an editor's panel headers meet its
/// tab bar. They were three bands of three heights, each padded to fit what it
/// happened to carry, and the rule stepped at every resize handle.
///
/// `inset` is the side padding: the main pane's content gutter by default, so
/// a title sits over the text beneath it; the sidebar and the dock pass their
/// own row insets for the same reason.
struct WorkspaceHeaderBand<Content: View>: View {
  @Environment(\.theme) private var theme
  var inset: CGFloat?
  @ViewBuilder var content: Content

  init(inset: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.inset = inset
    self.content = content()
  }

  var body: some View {
    HStack(spacing: theme.space.sm) {
      content
    }
    .padding(.horizontal, inset ?? theme.paneGutter)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: theme.paneHeaderHeight)
    .overlay(alignment: .bottom) { FocusRule() }
  }
}

/// A header's or the status bar's action: a glyph, no label, no bezel.
///
/// The name and the key are in the tooltip, from the catalogue, so a glyph
/// never has to be learnt by clicking it. Lit — ink, on a quiet fill — while
/// what it toggles is showing, muted otherwise, with the same fill under the
/// pointer. One square everywhere, so a row of these in a header and a row of
/// them in the status bar are visibly the same kind of control.
struct WorkspacePaneIconButton: View {
  let symbol: String
  let title: String
  var command: WorkspaceCommandID?
  var isOn = false
  /// What the tooltip says in place of the title, when there is more to say
  /// than the accessibility label should carry.
  var note: String?
  let action: () -> Void

  init(
    _ symbol: String, title: String, command: WorkspaceCommandID? = nil, isOn: Bool = false,
    note: String? = nil, action: @escaping () -> Void
  ) {
    self.symbol = symbol
    self.title = title
    self.note = note
    self.command = command
    self.isOn = isOn
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      WorkspacePaneIconGlyph(symbol: symbol, isOn: isOn)
    }
    .buttonStyle(WorkspacePaneIconButtonStyle(isOn: isOn))
    // The keyboard reaches every one of these by its command; a tab stop on
    // each would only put more stops between the panes.
    .focusable(false)
    .help(command.map { WorkspaceCommandHelpText.text(for: $0, note: note ?? title) } ?? note ?? title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
  }
}

/// The glyph on its own, for a `Menu` whose label has to match the icon
/// buttons beside it.
struct WorkspacePaneIconGlyph: View {
  @Environment(\.theme) private var theme
  let symbol: String
  var isOn = false

  var body: some View {
    Image(systemName: symbol)
      .font(theme.captionFont)
      .foregroundStyle(isOn ? theme.ink : theme.muted)
      .frame(width: theme.paneIconButtonSize, height: theme.paneIconButtonSize)
      .contentShape(RoundedRectangle(cornerRadius: theme.controlRadius))
  }
}

/// Flat: the hover tone under the pointer, while pressed, and while lit. No
/// border and no ring.
struct WorkspacePaneIconButtonStyle: ButtonStyle {
  var isOn = false

  func makeBody(configuration: Configuration) -> some View {
    WorkspacePaneIconButtonBody(configuration: configuration, isOn: isOn)
  }
}

/// A view rather than the style's own body, so the hover state has somewhere
/// to live.
private struct WorkspacePaneIconButtonBody: View {
  @Environment(\.theme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  let configuration: ButtonStyleConfiguration
  let isOn: Bool
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .background(
        isOn || isHovering || configuration.isPressed ? theme.hover : Color.clear,
        in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
      .opacity(isEnabled ? 1 : Theme.disabledOpacity)
      .onHover { isHovering = $0 }
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

/// A pane with nothing to show: its header, so the rule still runs across the
/// window, and one line of muted text in the middle of the surface.
///
/// It was `ContentUnavailableView` — a large grey symbol and the system's own
/// title face, with no header over it, so the one pane without a list in it was
/// also the one place the rule under the headers broke.
struct WorkspaceEmptyPane: View {
  @Environment(\.theme) private var theme
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 0) {
      WorkspacePaneHeader(title: title)
      WorkspaceEmptyMessage(message)
    }
    .background(theme.paper)
  }
}

/// The empty state without the header: one line of muted body text, centred
/// on whatever surface it is given, with an optional quieter line under it.
/// Every pane, rail and dock with nothing to show says so through this, so
/// "nothing here" looks the same wherever it appears.
struct WorkspaceEmptyMessage<Trailing: View>: View {
  @Environment(\.theme) private var theme
  let text: String
  var detail: String?
  @ViewBuilder var trailing: Trailing

  init(_ text: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
    self.text = text
    self.detail = detail
    self.trailing = trailing()
  }

  var body: some View {
    VStack(spacing: theme.space.sm) {
      Text(text)
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
      if let detail {
        Text(detail)
          .font(theme.captionFont)
          .foregroundStyle(theme.dim)
      }
      trailing
    }
    .multilineTextAlignment(.center)
    .padding(theme.space.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension WorkspaceEmptyMessage where Trailing == EmptyView {
  init(_ text: String, detail: String? = nil) {
    self.init(text, detail: detail) { EmptyView() }
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
      .font(theme.monoCaptionFont)
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
