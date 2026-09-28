import PriorityCore
import SwiftUI

/// Keybindings pane for `SettingsView`: the three global hotkeys, the Quick
/// Add target they capture to, and the card builder they share.
///
/// It used to carry two more sections — a per-action shortcut editor and a
/// searchable reference — both of which configured a key router that went with
/// the popover, so they were settings that changed nothing. What is left is
/// live: `GlobalShortcutManager` registers these three with Carbon. The
/// window's own keys are rebound in `keymap.json` — see
/// `docs/keyboard-shortcuts.md`.
extension SettingsView {
  var keybindingsPane: some View {
    Group {
      Section(header: MicroLabel("Configurable Hotkeys")) {
        Text("These shortcuts work globally, even when Priority is not focused.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)

        hotkeyCard(
          title: "Global hotkey",
          description: "Shows or hides the main window from anywhere.",
          defaultDisplay: HotkeyRecorderField.displayString(keyCode: 49, modifiers: 0x0800),
          enabled: preferenceBinding(\.globalHotkeyEnabled),
          keyCode: preferenceBinding(\.globalHotkeyKeyCode),
          modifiers: preferenceBinding(\.globalHotkeyModifiers)
        )
        hotkeyCard(
          title: "Focus panel hotkey",
          description: "Summons the focus panel over any app. Type to search, ↵ to start.",
          defaultDisplay: HotkeyRecorderField.displayString(keyCode: 3, modifiers: 0x1B00),
          enabled: preferenceBinding(\.focusPanelHotkeyEnabled),
          keyCode: preferenceBinding(\.focusPanelHotkeyKeyCode),
          modifiers: preferenceBinding(\.focusPanelHotkeyModifiers)
        )
        hotkeyCard(
          title: "Quick Add hotkey",
          description: "Captures to Inbox. Use ↑/↓ for lists and ←/→ for the start day.",
          defaultDisplay: HotkeyRecorderField.displayString(keyCode: 45, modifiers: 0x1B00),
          enabled: preferenceBinding(\.quickAddHotkeyEnabled),
          keyCode: preferenceBinding(\.quickAddHotkeyKeyCode),
          modifiers: preferenceBinding(\.quickAddHotkeyModifiers)
        )

        if let conflict = hotkeyConflict {
          Label(conflict, systemImage: "exclamationmark.triangle.fill")
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
          .settingsStatusSurface(theme, tint: theme.danger)
        }

        HStack {
          Text("Record a modifier plus a key. Press Escape while recording to cancel.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
          Spacer(minLength: 0)
          Button("Reset hotkeys to defaults") {
            preferences.globalHotkeyKeyCode = 49  // Space
            preferences.globalHotkeyModifiers = 0x0800  // Option
            preferences.quickAddHotkeyKeyCode = 45  // N
            preferences.quickAddHotkeyModifiers = 0x1B00  // Hyper
            preferences.focusPanelHotkeyKeyCode = 3  // F
            preferences.focusPanelHotkeyModifiers = 0x1B00  // Hyper
          }
        }
      }

      Section(header: MicroLabel("Window Keys")) {
        let keymap = WorkspaceKeymapStore.shared
        Text(
          "Every key in the window can be rebound in keymap.json. The format is in docs/keyboard-shortcuts.md."
        )
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        HStack {
          Text(keymap.issues.isEmpty ? "No problems" : "\(keymap.issues.count) problem(s) — see Diagnostics")
            .font(theme.captionFont)
            .foregroundStyle(keymap.issues.isEmpty ? theme.muted : theme.danger)
          Spacer(minLength: 0)
          Button("Reload") { keymap.reload(force: true) }
          Button("Open keymap.json") { keymap.openFile() }
        }
      }

      Section(header: MicroLabel("Quick Add Target")) {
        VStack(alignment: .leading, spacing: theme.space.xs) {
          Text("Quick Add location")
          Picker("", selection: preferenceBinding(\.quickAddLocationMode)) {
            Text("Default (List root)").tag(QuickAddLocationMode.defaultRoot)
            Text("Specific task ID").tag(QuickAddLocationMode.specificParentTask)
          }
          .labelsHidden()
          .pickerStyle(.segmented)

          if preferences.quickAddLocationMode == .specificParentTask {
            HStack {
              TextField("Parent task ID", text: preferenceBinding(\.quickAddSpecificParentTaskId))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
              Button("Use selected task") {
                checkvistManager.taskMutationService.setQuickAddSpecificLocationToCurrentTask()
              }
              .disabled(checkvistManager.taskListViewModel.currentTask == nil)
            }
            Text("Quick Add creates new tasks as children of this task ID.")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
          }
        }
      }

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

  fileprivate func hotkeyCard(
    title: String,
    description: String,
    defaultDisplay: String,
    enabled: Binding<Bool>,
    keyCode: Binding<Int>,
    modifiers: Binding<Int>
  ) -> some View {
    HStack(alignment: .top, spacing: theme.space.md) {
      VStack(alignment: .leading, spacing: theme.space.xs) {
        Toggle(isOn: enabled) {
          Text(title)
            .font(theme.bodyFont(weight: .semibold))
        }
          .toggleStyle(.switch)
        Text(description)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
        Text("Default: \(defaultDisplay)")
          .font(theme.monoFont(size: theme.scale.caption, weight: .medium))
          .foregroundStyle(theme.muted)
      }
      Spacer()
      if enabled.wrappedValue {
        HotkeyRecorderField(keyCode: keyCode, modifiers: modifiers)
          .frame(width: Self.hotkeyRecorderWidth)
      } else {
        Text("Off")
          .font(theme.monoFont(size: theme.scale.caption, weight: .medium))
          .foregroundStyle(theme.muted)
          .padding(.horizontal, theme.space.sm)
          .padding(.vertical, theme.space.xs)
          .themedSurface(theme, fill: theme.well, radius: theme.controlRadius)
      }
    }
    .padding(theme.space.sm)
    .themedSurface(theme, fill: theme.paper, radius: theme.panelRadius)
  }

  /// Room for the longest shortcut the recorder prints, four modifier glyphs
  /// and a named key, without truncating it.
  fileprivate static var hotkeyRecorderWidth: CGFloat { 150 }
}
