import AppKit
import PriorityCore
import SwiftUI

/// The main window's toolbar: where you are, and the two surfaces that take the
/// pane away from you.
///
/// It exists because the modes were reachable only by a command-digit nobody
/// had been told about — no strip, no menu item, nothing on screen naming the
/// one you were in. A keyboard-first app still has to say what its keys do
/// somewhere other than a reference sheet.
///
/// It also used to carry a Checkvist list switcher, a Checkvist refresh and a
/// diagnostics button, which described the app this one grew out of rather than
/// this one. The list you are in is the sidebar's business; switching the
/// *Checkvist* list lives in Preferences, beside the account it belongs to.
///
/// Items are SwiftUI hosted in `NSHostingView` rather than `NSToolbarItem`
/// targets, so `@Observable` drives them directly. The alternative — hand-
/// syncing AppKit control state through `withObservationTracking` — is the
/// pattern `MenuBarController` needs for the status item title and is worth
/// avoiding anywhere it isn't forced.
@MainActor
final class MainWindowToolbarController: NSObject, NSToolbarDelegate {

  private enum ItemID {
    static let modes = NSToolbarItem.Identifier("PriorityModes")
    static let focus = NSToolbarItem.Identifier("PriorityFocus")
    static let timeline = NSToolbarItem.Identifier("PriorityTimeline")
    static let settings = NSToolbarItem.Identifier("PrioritySettings")
  }

  private let workspace: WorkspaceViewModel

  var onShowSettings: (() -> Void)?

  init(workspace: WorkspaceViewModel) {
    self.workspace = workspace
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
    [
      ItemID.modes,
      .flexibleSpace,
      ItemID.focus,
      ItemID.timeline,
      ItemID.settings,
    ]
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
    case ItemID.modes:
      return hostedItem(identifier: itemIdentifier, label: "View", minWidth: 220, maxWidth: 340) {
        AnyView(WorkspaceModeStrip().environment(self.workspace))
      }

    case ItemID.focus:
      return hostedItem(identifier: itemIdentifier, label: "Focus", minWidth: 30, maxWidth: 30) {
        AnyView(
          WorkspacePaneToggle(
            symbol: "timer", title: "Focus", shortcut: "⌘8",
            isOn: { self.workspace.showsFocusScreen },
            toggle: {
              if self.workspace.showsFocusScreen {
                self.workspace.dismissFocusScreen()
              } else {
                self.workspace.presentFocusScreen()
              }
            })
            .environment(self.workspace))
      }

    case ItemID.timeline:
      return hostedItem(identifier: itemIdentifier, label: "Timeline", minWidth: 30, maxWidth: 30) {
        AnyView(
          WorkspacePaneToggle(
            symbol: "chart.bar.doc.horizontal", title: "Timeline", shortcut: "⌘9",
            isOn: { self.workspace.showsTimelineScreen },
            toggle: {
              if self.workspace.showsTimelineScreen {
                self.workspace.dismissTimelineScreen()
              } else {
                self.workspace.presentTimelineScreen()
              }
            })
            .environment(self.workspace))
      }

    case ItemID.settings:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Preferences"
      item.paletteLabel = "Preferences"
      item.toolTip = "Preferences (⌘,)"
      item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Preferences")
      item.target = self
      item.action = #selector(settingsClicked)
      item.isBordered = true
      return item

    default:
      return nil
    }
  }

  // MARK: - Item construction

  private func hostedItem(
    identifier: NSToolbarItem.Identifier,
    label: String,
    minWidth: CGFloat,
    maxWidth: CGFloat,
    content: () -> AnyView
  ) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    let hostingView = NSHostingView(rootView: content().focusEffectDisabled())
    hostingView.sizingOptions = [.intrinsicContentSize]
    item.view = hostingView
    item.minSize = NSSize(width: minWidth, height: 24)
    item.maxSize = NSSize(width: maxWidth, height: 24)
    return item
  }

  @objc private func settingsClicked() { onShowSettings?() }
}

/// Where you are, and the other places you could be.
///
/// A segmented strip rather than a menu: there are four of them, they are
/// mutually exclusive, and the one you are in is the thing worth seeing without
/// clicking anything.
struct WorkspaceModeStrip: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    HStack(spacing: 2) {
      ForEach(WorkspaceViewMode.planningModes) { mode in
        let isCurrent = model.viewMode == mode && !model.showsFocusScreen && !model.showsTimelineScreen
        Button {
          model.dismissFocusScreen()
          model.dismissTimelineScreen()
          model.selectViewMode(mode)
          model.requestKeyboardFocus(.tasks)
        } label: {
          HStack(spacing: 5) {
            Image(systemName: mode.symbolName)
              .font(.system(size: 11, weight: .semibold))
            Text(mode.title)
              .font(.system(size: 11, weight: .medium))
          }
          .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            isCurrent ? Color.accentColor.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(isCurrent ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1))
          .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(mode.shortcutDigit.map { "\(mode.title) (⌘\($0))" } ?? mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
      }
    }
  }
}

/// A full-pane surface that takes the main view over: on or off, and saying
/// which on its face.
struct WorkspacePaneToggle: View {
  let symbol: String
  let title: String
  let shortcut: String
  let isOn: () -> Bool
  let toggle: () -> Void

  var body: some View {
    let on = isOn()
    Button(action: toggle) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(on ? Color.accentColor : .secondary)
        .frame(width: 26, height: 22)
        .background(
          on ? Color.accentColor.opacity(0.14) : .clear,
          in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .help("\(title) (\(shortcut))")
    .accessibilityLabel(title)
    .accessibilityAddTraits(on ? [.isSelected] : [])
  }
}
