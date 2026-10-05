import AppKit
import TaktCore
import SwiftUI

/// The main window's toolbar: where you are, and the field to add a task.
///
/// It exists because the modes were reachable only by a command-digit nobody
/// had been told about — no strip, no menu item, nothing on screen naming the
/// one you were in. It used to carry the Focus, Timeline and Done toggles and a
/// Preferences gear beside the strip as well. Focus and the timeline are
/// places, so they joined the strip; Done is a dock, so it moved to the status
/// bar with the other dock toggles; Preferences is ⌘, and the app menu. Each
/// control has one home.
///
/// The add field joined it from the foot of the panes, where it sat on top of
/// the status bar and existed only in the outline and the board.
///
/// The strip is SwiftUI hosted in an `NSHostingView` rather than
/// `NSToolbarItem` targets, so `@Observable` drives it directly.
@MainActor
final class MainWindowToolbarController: NSObject, NSToolbarDelegate {

  private enum ItemID {
    static let modes = NSToolbarItem.Identifier("PriorityModes")
    static let add = NSToolbarItem.Identifier("PriorityAddTask")
  }

  private let workspace: WorkspaceViewModel
  /// Toolbar items are hung off the window's titlebar rather than off the
  /// content view, so none of them sits below the `.themed(_:)` at the window
  /// root. Without this they read the environment's default theme.
  private let theme: ThemeManager

  init(workspace: WorkspaceViewModel, theme: ThemeManager) {
    self.workspace = workspace
    self.theme = theme
    super.init()
  }

  func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "PriorityMainWindowToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    return toolbar
  }

  // MARK: - NSToolbarDelegate

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, ItemID.modes, .flexibleSpace, ItemID.add]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case ItemID.modes: return item(itemIdentifier, label: "View", WorkspaceModeStrip())
    case ItemID.add: return item(itemIdentifier, label: "Add Task", WorkspaceTitleBarAddField())
    default: return nil
    }
  }

  private func item(
    _ identifier: NSToolbarItem.Identifier, label: String, _ content: some View
  ) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    let hostingView = NSHostingView(
      rootView: content
        .environment(workspace)
        .focusEffectDisabled()
        .themed(theme))
    hostingView.sizingOptions = [.intrinsicContentSize]
    item.view = hostingView
    return item
  }
}

/// Where you are, and the other places you could be.
///
/// A segmented strip rather than a menu: there are four of them, they are
/// mutually exclusive, and the one you are in is the thing worth seeing without
/// clicking anything.
struct WorkspaceModeStrip: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    let onScreen = !model.showsFocusScreen && !model.showsTimelineScreen
    HStack(spacing: theme.space.xxs) {
      ForEach(WorkspaceViewMode.planningModes) { mode in
        segment(
          title: mode.title, command: mode.command,
          isCurrent: onScreen && model.viewMode == mode
        ) {
          model.leaveFullPaneScreens()
          model.selectViewMode(mode)
          model.requestKeyboardFocus(.tasks)
        }
      }
      // The two full-pane screens, set apart by a rule: they take the pane
      // over rather than projecting the tasks another way.
      Rectangle()
        .fill(theme.border)
        .frame(width: theme.hairline, height: theme.space.lg)
        .padding(.horizontal, theme.space.xs)
      segment(title: "Focus", command: .goFocus, isCurrent: model.showsFocusScreen) {
        if model.showsFocusScreen { model.dismissFocusScreen() } else { model.presentFocusScreen() }
      }
      segment(
        title: "Timeline", command: .goTimeline,
        isCurrent: model.showsTimelineScreen
      ) {
        if model.showsTimelineScreen { model.dismissTimelineScreen() } else { model.presentTimelineScreen() }
      }
    }
  }

  private func segment(
    title: String, command: WorkspaceCommandID?, isCurrent: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      // Words only, the way an editor's title bar names things. With a glyph
      // beside every word and the current one boxed in the selection's border,
      // the strip was the loudest thing in the window; it should be the
      // quietest thing that still says where you are.
      Text(title)
        .font(theme.bodyFont())
        .foregroundStyle(isCurrent ? theme.ink : theme.muted)
        .padding(.horizontal, theme.space.sm)
        .padding(.vertical, theme.space.xxs)
        .background(
          isCurrent ? theme.hover : Color.clear,
          in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: theme.controlRadius))
    }
    .buttonStyle(.plain)
    .focusable(false)
    .help(command.map { WorkspaceCommandHelpText.text(for: $0, note: title) } ?? title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}
