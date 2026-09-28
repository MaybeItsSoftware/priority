import AppKit
import PriorityCore
import SwiftUI

/// The main window's toolbar: where you are, and nothing else.
///
/// It exists because the modes were reachable only by a command-digit nobody
/// had been told about — no strip, no menu item, nothing on screen naming the
/// one you were in. It used to carry the Focus, Timeline and Done toggles and a
/// Preferences gear beside the strip as well. Focus and the timeline are
/// places, so they joined the strip; Done is a dock, so it moved to the status
/// bar with the other dock toggles; Preferences is ⌘, and the app menu. Each
/// control has one home.
///
/// The strip is SwiftUI hosted in an `NSHostingView` rather than
/// `NSToolbarItem` targets, so `@Observable` drives it directly.
@MainActor
final class MainWindowToolbarController: NSObject, NSToolbarDelegate {

  private enum ItemID {
    static let modes = NSToolbarItem.Identifier("PriorityModes")
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
    [.flexibleSpace, ItemID.modes, .flexibleSpace]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard itemIdentifier == ItemID.modes else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = "View"
    item.paletteLabel = "View"
    let hostingView = NSHostingView(
      rootView: WorkspaceModeStrip()
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
          title: mode.title, symbol: mode.symbolName, command: mode.command,
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
      segment(title: "Focus", symbol: "timer", command: .goFocus, isCurrent: model.showsFocusScreen) {
        if model.showsFocusScreen { model.dismissFocusScreen() } else { model.presentFocusScreen() }
      }
      segment(
        title: "Timeline", symbol: "chart.bar.doc.horizontal", command: .goTimeline,
        isCurrent: model.showsTimelineScreen
      ) {
        if model.showsTimelineScreen { model.dismissTimelineScreen() } else { model.presentTimelineScreen() }
      }
    }
  }

  private func segment(
    title: String, symbol: String, command: WorkspaceCommandID?, isCurrent: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: theme.space.xs) {
        Image(systemName: symbol)
        Text(title)
      }
      .font(theme.bodyFont(weight: .medium))
      .foregroundStyle(isCurrent ? theme.primary : theme.muted)
      .padding(.horizontal, theme.space.sm)
      .padding(.vertical, theme.space.xxs)
      // The same selection every other row in the app draws.
      .workspaceSelection(isSelected: isCurrent, hasKeyboard: false)
      .contentShape(RoundedRectangle(cornerRadius: theme.controlRadius))
    }
    .buttonStyle(.plain)
    .help(command.map { WorkspaceCommandHelpText.text(for: $0, note: title) } ?? title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}
