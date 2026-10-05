import AppKit
import Observation

@Observable final class SettingsNavState: NSObject {
  enum Pane: String {
    case preferences
    case keybindings
    case theme
    case plugins
    case sync
    #if DEBUG
      case debug
    #endif

    var title: String {
      switch self {
      case .preferences: "Preferences"
      case .keybindings: "Keybindings"
      case .theme: "Theme"
      case .plugins: "Plugins"
      case .sync: "Sync"
      #if DEBUG
        case .debug: "Debug"
      #endif
      }
    }

    var systemImage: String {
      switch self {
      case .preferences: "slider.horizontal.3"
      case .keybindings: "keyboard"
      case .theme: "paintpalette"
      case .plugins: "puzzlepiece.extension"
      case .sync: "arrow.triangle.2.circlepath"
      #if DEBUG
        case .debug: "ladybug"
      #endif
      }
    }

    static var allPanes: [Pane] {
      var panes: [Pane] = [.preferences, .keybindings, .theme, .plugins, .sync]
      #if DEBUG
        panes.append(.debug)
      #endif
      return panes
    }
  }

  var selectedPane: Pane = .preferences
  @ObservationIgnored weak var toolbar: NSToolbar?

  func select(pane: Pane) {
    selectedPane = pane
    toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
  }
}

extension SettingsNavState: NSToolbarDelegate {
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Pane.allPanes.map { .init($0.rawValue) }
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let pane = Pane(rawValue: itemIdentifier.rawValue) else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = pane.title
    item.image = NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: pane.title)
    item.target = self
    item.action = #selector(selectPane(_:))
    return item
  }

  @objc private func selectPane(_ sender: NSToolbarItem) {
    guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
    selectedPane = pane
    toolbar?.selectedItemIdentifier = sender.itemIdentifier
  }
}

extension SettingsNavState: NSToolbarItemValidation {
  func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }
}
