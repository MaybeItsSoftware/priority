import TaktCore
import TaktWorkspace
import SwiftUI

/// The Keyboard page: the three global hotkeys `GlobalShortcutManager`
/// registers with Carbon, the list Quick Add captures into, and the way into
/// the window's own keymap (`keymap.json`, laid over
/// `WorkspaceCommandCatalog`; see `docs/keyboard-shortcuts.md`).
///
/// The Quick Add target used to be a Checkvist parent-task ID typed by hand;
/// it is a list from the workspace now.
extension SettingsView {
  @ViewBuilder
  var keyboardPane: some View {
    Section {
      hotkeyRow(
        title: "Show or hide the window",
        description: "From anywhere, even when Takt is not in front.",
        defaultDisplay: HotkeyRecorderField.displayString(keyCode: 49, modifiers: 0x0800),
        enabled: preferenceBinding(\.globalHotkeyEnabled),
        keyCode: preferenceBinding(\.globalHotkeyKeyCode),
        modifiers: preferenceBinding(\.globalHotkeyModifiers)
      )
      hotkeyRow(
        title: "Focus panel",
        description: "Summons the focus panel over any app. Type to search, ↵ to start.",
        defaultDisplay: HotkeyRecorderField.displayString(keyCode: 3, modifiers: 0x1B00),
        enabled: preferenceBinding(\.focusPanelHotkeyEnabled),
        keyCode: preferenceBinding(\.focusPanelHotkeyKeyCode),
        modifiers: preferenceBinding(\.focusPanelHotkeyModifiers)
      )
      hotkeyRow(
        title: "Quick Add",
        description: "Captures a task. ↑/↓ picks the list and ←/→ the start day as you type.",
        defaultDisplay: HotkeyRecorderField.displayString(keyCode: 45, modifiers: 0x1B00),
        enabled: preferenceBinding(\.quickAddHotkeyEnabled),
        keyCode: preferenceBinding(\.quickAddHotkeyKeyCode),
        modifiers: preferenceBinding(\.quickAddHotkeyModifiers)
      )
      if let conflict = hotkeyConflict {
        Label(conflict, systemImage: "exclamationmark.triangle")
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
          .settingsStatusSurface(theme, tint: theme.danger)
      }
      HStack {
        Text("Click a shortcut and press a modifier plus a key. Escape cancels.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
        Spacer(minLength: theme.space.sm)
        Button("Reset to defaults") {
          preferences.globalHotkeyKeyCode = 49  // Space
          preferences.globalHotkeyModifiers = 0x0800  // Option
          preferences.quickAddHotkeyKeyCode = 2  // D
          preferences.quickAddHotkeyModifiers = 0x1B00  // Hyper
          preferences.focusPanelHotkeyKeyCode = 3  // F
          preferences.focusPanelHotkeyModifiers = 0x1B00  // Hyper
        }
      }
    } header: {
      Text("Global hotkeys")
    }

    Section {
      SettingsRow(
        "Quick Add captures into",
        detail: "Where the Quick Add hotkey starts. A list that is later deleted falls back to the Inbox."
      ) {
        ThemedMenuPicker(
          "Quick Add captures into",
          selection: preferenceBinding(\.quickCaptureListID),
          options: [ThemedPickerOption("Inbox", value: "", systemImage: "tray")]
            + workspace.lists
            .filter { $0.systemRole != .inbox && !$0.isArchived }
            .map { ThemedPickerOption($0.name, value: $0.id) })
      }
    } header: {
      Text("Quick capture")
    }

    Section {
      let keymap = WorkspaceKeymapStore.shared
      SettingsRow(
        "keymap.json",
        detail: keymap.issues.isEmpty
          ? "Every key in the window can be rebound here. The format is in docs/keyboard-shortcuts.md."
          : "\(keymap.issues.count) problem(s) in the file — the details are in Diagnostics."
      ) {
        HStack(spacing: theme.space.xs) {
          Button("Reload") { keymap.reload(force: true) }
            .commandHelp(.windowReloadKeymap)
          Button("Open") { keymap.openFile() }
            .commandHelp(.windowOpenKeymap)
        }
      }
      KeyHint(WorkspaceCommandHelpText.firstKey(for: .goKeyboardReference), "Every key the window answers, in the window")
    } header: {
      Text("Window keys")
    }
  }

  // MARK: - Pane-local helpers

  /// Names the pair that clash rather than reporting a bare "conflict": with
  /// three global hotkeys, which two is the thing you need to know.
  fileprivate var hotkeyConflict: String? {
    let bindings: [(String, Bool, Int, Int)] = [
      ("Global hotkey", preferences.globalHotkeyEnabled,
        preferences.globalHotkeyKeyCode, preferences.globalHotkeyModifiers),
      ("Focus panel hotkey", preferences.focusPanelHotkeyEnabled,
        preferences.focusPanelHotkeyKeyCode, preferences.focusPanelHotkeyModifiers),
      ("Quick Add hotkey", preferences.quickAddHotkeyEnabled,
        preferences.quickAddHotkeyKeyCode, preferences.quickAddHotkeyModifiers)
    ].filter(\.1)
    for (index, binding) in bindings.enumerated() {
      for other in bindings.dropFirst(index + 1)
      where binding.2 == other.2 && binding.3 == other.3 {
        return "\(binding.0) and \(other.0) currently conflict."
      }
    }
    return nil
  }

  fileprivate func hotkeyRow(
    title: String,
    description: String,
    defaultDisplay: String,
    enabled: Binding<Bool>,
    keyCode: Binding<Int>,
    modifiers: Binding<Int>
  ) -> some View {
    HStack(alignment: .center, spacing: theme.space.md) {
      Toggle(isOn: enabled) {
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Text(title).font(theme.bodyFont()).foregroundStyle(theme.ink)
          Text("\(description) Default \(defaultDisplay).")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.themedSwitch)
      if enabled.wrappedValue {
        HotkeyRecorderField(keyCode: keyCode, modifiers: modifiers)
          .help("Click, then press a modifier and a key · esc cancels")
          .frame(width: Self.hotkeyRecorderWidth)
          .padding(.vertical, theme.space.xs)
          .themedSurface(theme, fill: theme.raised, radius: theme.controlRadius, stroke: theme.inputBorder)
      } else {
        Text("Off")
          .font(theme.monoFont(size: theme.scale.caption))
          .foregroundStyle(theme.muted)
          .frame(width: Self.hotkeyRecorderWidth)
          .padding(.vertical, theme.space.xs)
          .themedSurface(theme, fill: theme.well, radius: theme.controlRadius)
      }
    }
  }

  /// Room for the longest shortcut the recorder prints, four modifier glyphs
  /// and a named key, without truncating it.
  fileprivate static var hotkeyRecorderWidth: CGFloat { 150 }
}
