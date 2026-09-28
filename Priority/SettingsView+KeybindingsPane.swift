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
      Section(header: Text("Configurable Hotkeys")) {
        Text("These shortcuts work globally, even when Priority is not focused.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

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
          .font(.caption)
          .foregroundColor(themeColor(.danger))
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(themeColor(.danger).opacity(0.08))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(themeColor(.danger).opacity(0.3), lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        HStack {
          Text("Record a modifier plus a key. Press Escape while recording to cancel.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
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

      Section(header: Text("Window Keys")) {
        let keymap = WorkspaceKeymapStore.shared
        Text(
          "Every key in the window can be rebound in keymap.json. The format is in docs/keyboard-shortcuts.md."
        )
        .font(.caption)
        .foregroundColor(themeColor(.textSecondary))
        HStack {
          Text(keymap.issues.isEmpty ? "No problems" : "\(keymap.issues.count) problem(s) — see Diagnostics")
            .font(.caption)
            .foregroundColor(themeColor(keymap.issues.isEmpty ? .textSecondary : .danger))
          Spacer(minLength: 0)
          Button("Reload") { keymap.reload(force: true) }
          Button("Open keymap.json") { keymap.openFile() }
        }
      }

      Section(header: Text("Quick Add Target")) {
        VStack(alignment: .leading, spacing: 6) {
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
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))
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
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Toggle(isOn: enabled) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
        }
          .toggleStyle(.switch)
        Text(description)
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))
        Text("Default: \(defaultDisplay)")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(themeColor(.textSecondary))
      }
      Spacer()
      if enabled.wrappedValue {
        HotkeyRecorderField(keyCode: keyCode, modifiers: modifiers)
          .frame(width: 150, height: 22)
      } else {
        Text("Off")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(themeColor(.textSecondary))
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(themeColor(.panelSurfaceElevated))
          .clipShape(Capsule())
      }
    }
    .padding(12)
    .background(themeColor(.panelSurface))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(themeColor(.panelDivider), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}
