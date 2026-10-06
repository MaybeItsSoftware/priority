import AppKit
import Foundation
import TaktCore
import TaktWorkspace

/// Everything that used to be a sheet on the workspace window and is now drawn
/// by the one overlay host at the top of it.
///
/// A sheet is a second window: it slides, it steals the title bar, it takes
/// the window's key monitor down with it, and two of them cannot replace each
/// other — ⌘K from inside search had to be pressed after closing search. One
/// enum means one of these is up at a time by construction, and asking for a
/// different one simply replaces it.
enum WorkspaceOverlay: Identifiable {
  case commandPalette
  case search
  /// The list finder: every list and nested list, filtered as you type.
  case listNavigator
  case keyboardReference
  case move(WorkspaceItemMoveRequest)
  case quickEdit(WorkspaceTaskQuickEditRequest)
  /// The habit form, on a task, a habit, or nothing.
  case habit(WorkspaceHabitRequest)
  /// A new list or folder. Where it goes is `creationParentFolderID` and
  /// `creationIsNested` on the model, set by whoever asked.
  case create(WorkspaceCreationKind)
  case newBoardColumn

  var id: String {
    switch self {
    case .commandPalette: "palette"
    case .search: "search"
    case .listNavigator: "navigator"
    case .keyboardReference: "keys"
    case .move(let request): "move:\(request.id)"
    case .quickEdit(let request): "edit:\(request.id)"
    case .habit(let request): "habit:\(request.id)"
    case .create(let kind): "create:\(kind.rawValue)"
    case .newBoardColumn: "column"
    }
  }
}

/// What an overlay does with the keys it owns. Registered by the overlay's own
/// view, because the selection it moves is the view's state, and keyed by the
/// overlay's id so a view on its way out cannot answer for its replacement.
struct WorkspaceOverlayKeyHandler {
  let overlayID: String
  /// Returns whether the key was consumed. A key that is not — a letter, say —
  /// goes on to the overlay's field.
  let handle: (String) -> Bool
}

@MainActor
extension WorkspaceViewModel {
  /// The chords that swap one overlay for another rather than closing it:
  /// ⌘K from search opens the palette.
  static let overlaySwitchingCommands: Set<WorkspaceCommandID> = [
    .goCommandPalette, .goSearch, .goKeyboardReference, .goListNavigator,
  ]

  /// Asking for the overlay already up closes it, the way ⌘K twice does in
  /// every editor that has one.
  func presentOverlay(_ overlay: WorkspaceOverlay) {
    desktopShortcutSequence.reset()
    if activeOverlay?.id == overlay.id {
      dismissOverlay()
      return
    }
    activeOverlay = overlay
  }

  /// - Parameter restoringFocus: whether to hand the keyboard back to the
  ///   region that had it. An overlay that goes somewhere on its way out — a
  ///   search result, a palette command — says where itself.
  func dismissOverlay(restoringFocus: Bool = true) {
    guard activeOverlay != nil else { return }
    activeOverlay = nil
    overlayKeyHandler = nil
    overlayPanelFrame = nil
    if restoringFocus { requestKeyboardFocus(keyboardFocusArea) }
  }

  /// The window's key monitor asks this first whenever an overlay is up.
  ///
  /// Escape always closes. The chords you leave a text field with still work,
  /// and the four that open an overlay replace this one rather than closing it.
  /// Everything else is offered to the overlay, and what it does not consume
  /// goes to its field — never through to the workspace behind it.
  func handleOverlayKey(_ event: NSEvent) -> Bool {
    guard let overlay = activeOverlay, let key = event.workspaceCommandKey else { return false }
    if key == "escape" {
      dismissOverlay()
      return true
    }
    if WorkspaceCommandCatalog.isChord(key),
      let command = WorkspaceCommandCatalog.command(forKey: key, on: .anywhere),
      WorkspaceCommandCatalog.reachableFromTextField.contains(command.id) {
      if !Self.overlaySwitchingCommands.contains(command.id) {
        dismissOverlay(restoringFocus: false)
      }
      run(command.id, key: key)
      return true
    }
    if let handler = overlayKeyHandler, handler.overlayID == overlay.id {
      return handler.handle(key)
    }
    return false
  }
}

/// How a list-shaped overlay reads the direction keys. `⌃N` and `⌃P` are
/// there because they are how a finder is driven in every editor that has one.
enum WorkspaceOverlayStep {
  static func offset(for key: String) -> Int? {
    switch key {
    case "down", "ctrl+n": 1
    case "up", "ctrl+p": -1
    case "pagedown": 8
    case "pageup": -8
    default: nil
    }
  }

  /// The index `offset` rows on from `current`, clamped to `count`.
  static func index(from current: Int?, by offset: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return offset > 0 ? 0 : count - 1 }
    return min(max(current + offset, 0), count - 1)
  }
}
