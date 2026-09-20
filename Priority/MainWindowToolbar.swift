import AppKit
import PriorityCore
import SwiftUI

/// The main window's toolbar: which list you are in, and the three things you
/// reach for when it looks wrong.
///
/// Items are SwiftUI hosted in `NSHostingView` rather than `NSPopUpButton` /
/// `NSToolbarItem` targets, so `@Observable` drives them directly. The
/// alternative — hand-syncing AppKit control state through
/// `withObservationTracking` — is the pattern `MenuBarController` needs for the
/// status item title and is worth avoiding anywhere it isn't forced.
@MainActor
final class MainWindowToolbarController: NSObject, NSToolbarDelegate {

  private enum ItemID {
    static let listSwitcher = NSToolbarItem.Identifier("PriorityListSwitcher")
    static let refresh = NSToolbarItem.Identifier("PriorityRefresh")
    static let diagnostics = NSToolbarItem.Identifier("PriorityDiagnostics")
    static let settings = NSToolbarItem.Identifier("PrioritySettings")
  }

  private let manager: AppCoordinator

  var onRefresh: (() -> Void)?
  var onShowDiagnostics: (() -> Void)?
  var onShowSettings: (() -> Void)?

  init(manager: AppCoordinator) {
    self.manager = manager
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
      ItemID.listSwitcher,
      .flexibleSpace,
      ItemID.refresh,
      ItemID.diagnostics,
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
    case ItemID.listSwitcher:
      return hostedItem(
        identifier: itemIdentifier,
        label: "List",
        minWidth: 120,
        maxWidth: 260
      ) {
        AnyView(ListSwitcherMenu().environment(self.manager))
      }

    case ItemID.refresh:
      return buttonItem(
        identifier: itemIdentifier,
        label: "Refresh",
        symbol: "arrow.clockwise",
        action: #selector(refreshClicked)
      )

    case ItemID.diagnostics:
      return buttonItem(
        identifier: itemIdentifier,
        label: "Diagnostics",
        symbol: "stethoscope",
        action: #selector(diagnosticsClicked)
      )

    case ItemID.settings:
      return buttonItem(
        identifier: itemIdentifier,
        label: "Preferences",
        symbol: "gearshape",
        action: #selector(settingsClicked)
      )

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

  private func buttonItem(
    identifier: NSToolbarItem.Identifier,
    label: String,
    symbol: String,
    action: Selector
  ) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    item.toolTip = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.target = self
    item.action = action
    item.isBordered = true
    return item
  }

  @objc private func refreshClicked() { onRefresh?() }
  @objc private func diagnosticsClicked() { onShowDiagnostics?() }
  @objc private func settingsClicked() { onShowSettings?() }
}

/// The list switcher itself.
///
/// Reads `availableLists` and writes through `SyncService.switchCheckvistList`,
/// which is the one path that also resets the cursor, the kanban scope and the
/// offline queue — switching a list without those was a real bug in the palette.
struct ListSwitcherMenu: View {
  @Environment(AppCoordinator.self) private var manager

  /// Per-view-instance on purpose: this is "has *this* switcher tried loading
  /// yet", which is exactly the scope `@State` gives it. The two settings
  /// pickers guard their autoload the same way.
  @State private var didAutoloadLists = false

  private var repository: TaskRepository { manager.repository }

  /// A list id can outlive the list it names — a stale preference, or lists that
  /// haven't loaded yet. Showing the raw id beats showing nothing.
  private var currentLabel: String {
    if repository.listId.isEmpty { return "Offline workspace" }
    let name = repository.currentListName
    return name.isEmpty ? "List \(repository.listId)" : name
  }

  var body: some View {
    Menu {
      Button("Offline workspace") { switchTo("") }
      if !repository.availableLists.isEmpty {
        Divider()
        ForEach(repository.availableLists) { list in
          Button(list.name) { switchTo(String(list.id)) }
        }
      }
      Divider()
      Button("Refresh Lists") {
        Task { _ = await manager.syncService.loadCheckvistLists() }
      }
    } label: {
      HStack(spacing: 4) {
        Text(currentLabel).lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .task {
      guard !didAutoloadLists else { return }
      didAutoloadLists = true
      if repository.canAttemptLogin && repository.availableLists.isEmpty {
        _ = await manager.syncService.loadCheckvistLists()
      }
    }
  }

  private func switchTo(_ listId: String) {
    Task { await manager.syncService.switchCheckvistList(to: listId) }
  }
}
