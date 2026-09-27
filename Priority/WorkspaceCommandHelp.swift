import PriorityCore
import SwiftUI

/// A tooltip that names a control's keyboard shortcut by asking the catalogue
/// for it.
///
/// Every on-screen control worth having has a key, and until now the only place
/// that said so was the command palette — which you have to know about and open.
/// The controls that did mention a key spelled it out inline, so the toolbar
/// said "(⌘8)" in a string literal while the router said `cmd+8` in a table, and
/// the two were free to disagree.
///
/// `WorkspaceCommandCatalog` is the single source of both the binding and its
/// rendering, so a tooltip built from a command id cannot go stale: rebind the
/// key and the tooltip follows.
extension View {
  /// `Title · ⌘8`, or just the title when the command has no key bound.
  ///
  /// Pass `note` to say something the catalogue does not know — what *this*
  /// instance of the control acts on, usually.
  func commandHelp(_ id: WorkspaceCommandID, note: String? = nil) -> some View {
    help(WorkspaceCommandHelpText.text(for: id, note: note))
  }
}

enum WorkspaceCommandHelpText {
  /// The command's first rendered key, for a key cap drawn beside a control.
  /// Empty when it has none, which `KeyCap` renders as nothing worth showing.
  static func firstKey(for id: WorkspaceCommandID) -> String {
    WorkspaceCommandCatalog.byID[id]?.displayKeys.first ?? ""
  }

  /// The menu key for a command with the keymap in force. Reads the keymap
  /// store's revision so a view asking — the menu bar — redraws when the
  /// keymap is reloaded; the catalogue itself is not observable.
  @MainActor
  static func menuShortcut(for id: WorkspaceCommandID) -> KeyboardShortcut? {
    _ = WorkspaceKeymapStore.shared.revision
    return WorkspaceCommandCatalog[id].menuShortcut
  }

  static func text(for id: WorkspaceCommandID, note: String? = nil) -> String {
    guard let command = WorkspaceCommandCatalog.byID[id] else { return note ?? "" }
    let subject = note ?? command.title
    let keys = command.displayKeys
    guard !keys.isEmpty else { return subject }
    // Alternatives separated by "or" rather than a slash: "EE / F2" read as one
    // four-key incantation on the old reference sheet, which is the mistake the
    // palette's key rows were rewritten to avoid.
    return "\(subject) · \(keys.joined(separator: " or "))"
  }
}

extension WorkspaceCommand {
  /// The command's shortcut as SwiftUI understands it, for a menu item.
  ///
  /// Only chorded keys qualify. A menu cannot express `gh` or `uu` — the
  /// Checkvist-style two-letter sequences the window monitor handles — and a
  /// bare letter in a menu would fire while you were typing a task title, so
  /// the first token carrying `cmd` or `ctrl` is the one a menu can use. A
  /// command with no such token gets no menu key, which is correct: it has one,
  /// and the palette is where you find it.
  var menuShortcut: KeyboardShortcut? {
    for token in keys {
      let parts = token.split(separator: "+").map(String.init)
      guard parts.count > 1, let key = parts.last,
        let equivalent = key.count == 1 ? KeyEquivalent(Character(key)) : Self.namedEquivalents[key]
      else { continue }
      var modifiers: EventModifiers = []
      for part in parts.dropLast() {
        switch part {
        case "cmd": modifiers.insert(.command)
        case "shift": modifiers.insert(.shift)
        case "option": modifiers.insert(.option)
        case "ctrl": modifiers.insert(.control)
        default: return nil
        }
      }
      guard modifiers.contains(.command) || modifiers.contains(.control) else { continue }
      // A menu's key equivalent is answered before the text field under the
      // caret sees the key, so ⌘← and ⇧⌘↑ would stop moving and selecting in
      // every field. Only arrows with ⌥ or ⌃ as well are left to the menu.
      if Self.arrows.contains(key), !modifiers.contains(.option), !modifiers.contains(.control) {
        continue
      }
      return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
    return nil
  }

  private static let arrows: Set<String> = ["up", "down", "left", "right"]

  private static let namedEquivalents: [String: KeyEquivalent] = [
    "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
    "delete": .delete, "enter": .return, "tab": .tab, "space": .space,
    "escape": .escape, "comma": ",",
  ]
}

extension View {
  /// The menu key for a command, taken from the catalogue rather than restated.
  @ViewBuilder
  func commandShortcut(_ id: WorkspaceCommandID) -> some View {
    if let shortcut = WorkspaceCommandHelpText.menuShortcut(for: id) {
      keyboardShortcut(shortcut)
    } else {
      self
    }
  }
}
