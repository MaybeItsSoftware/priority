import PriorityCore
import SwiftUI

/// Keybindings pane for `SettingsView` plus every helper used exclusively by
/// it (the three descriptor structs, the static shortcut-reference catalogue,
/// hotkey-card builder, shortcut-binding editor, and search filters). Pulled
/// out of the main file as part of the Phase-4 settings split.
extension SettingsView {
  struct ShortcutCategoryDescriptor: Identifiable {
    let title: String
    let actions: [ConfigurableShortcutAction]
    var id: String { title }
  }

  var keybindingsPane: some View {
    Group {
      Section(header: Text("Configurable Hotkeys")) {
        Text("These shortcuts work globally, even when Priority is not focused.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

        hotkeyCard(
          title: "Global hotkey",
          description: "Shows or hides the task popover from anywhere.",
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

      Section(header: Text("In-App Shortcut Bindings")) {
        Text(
          "Search, edit, or reset the in-app bindings below. Multiple bindings can be separated with commas."
        )
        .font(.caption)
        .foregroundColor(themeColor(.textSecondary))

        HStack(spacing: 8) {
          TextField("Filter shortcuts", text: $shortcutSearchText)
            .textFieldStyle(.roundedBorder)
          if !shortcutSearchText.isEmpty {
            Button("Clear") {
              shortcutSearchText = ""
            }
          }
        }
        .padding(.bottom, 2)

        if filteredShortcutCategories.isEmpty {
          Text("No in-app shortcuts match “\(shortcutSearchText)”.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
        } else {
          ForEach(filteredShortcutCategories) { category in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(category.title)
                  .font(.caption)
                  .foregroundColor(themeColor(.textSecondary))
                Spacer(minLength: 0)
                Text("\(category.actions.count)")
                  .font(.system(size: 11, weight: .medium, design: .monospaced))
                  .foregroundColor(themeColor(.textSecondary))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background(themeColor(.panelSurfaceElevated))
                  .clipShape(Capsule())
              }

              ForEach(category.actions) { action in
                shortcutBindingEditor(for: action)
              }
            }
            .padding(.vertical, 2)
          }
        }

        HStack {
          Spacer(minLength: 0)
          Button("Reset all in-app shortcuts to defaults") {
            preferences.resetConfigurableShortcutBindings()
          }
        }
      }

      Section(header: Text("Shortcut Reference")) {
        Text("Built-in navigation and command patterns that help when learning the app.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

        if filteredShortcutReferenceGroups.isEmpty {
          Text("No reference shortcuts match “\(shortcutSearchText)”.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
        } else {
          ForEach(filteredShortcutReferenceGroups) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(group.title)
                .font(.caption)
                .foregroundColor(themeColor(.textSecondary))
              ForEach(group.entries) { item in
                shortcutReferenceRow(item)
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

  fileprivate var configurableShortcutCategories: [ShortcutCategoryDescriptor] {
    let grouped = Dictionary(grouping: preferences.configurableShortcutActions, by: \.category)
    let order = ["Navigation", "Task Actions", "Entry & Commands", "Integrations & Timer"]
    return order.compactMap { category in
      guard let actions = grouped[category] else { return nil }
      return ShortcutCategoryDescriptor(title: category, actions: actions)
    }
  }

  fileprivate var filteredShortcutCategories: [ShortcutCategoryDescriptor] {
    let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return configurableShortcutCategories }

    return configurableShortcutCategories.compactMap { category in
      let matchingActions = category.actions.filter {
        shortcutActionMatchesSearch($0, query: query)
      }
      guard !matchingActions.isEmpty else { return nil }
      return ShortcutCategoryDescriptor(title: category.title, actions: matchingActions)
    }
  }

  /// Derived from the bindings in force, not from a hand-written list.
  ///
  /// The list it replaces had drifted three entries out of date — it named `u`
  /// as undo, `t` as the timer and `m` as a filter slot, all of which had moved
  /// — and, being static text, could never have shown a customised binding at
  /// all. See `ShortcutReference`.
  fileprivate var shortcutReferenceSections: [ShortcutReference.Section] {
    ShortcutReference.sections { preferences.shortcutBinding(for: $0) }
  }

  fileprivate var filteredShortcutReferenceGroups: [ShortcutReference.Section] {
    let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return shortcutReferenceSections }

    return shortcutReferenceSections.compactMap { group in
      let matchingItems = group.entries.filter {
        shortcutReferenceItemMatchesSearch($0, query: query)
      }
      guard !matchingItems.isEmpty else { return nil }
      return ShortcutReference.Section(title: group.title, entries: matchingItems)
    }
  }

  fileprivate func configurableShortcutBinding(for action: ConfigurableShortcutAction)
    -> Binding<String>
  {
    Binding(
      get: { preferences.shortcutBinding(for: action) },
      set: { preferences.setShortcutBinding($0, for: action) }
    )
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

  fileprivate func shortcutBindingEditor(for action: ConfigurableShortcutAction)
    -> some View
  {
    let isCustomized = isShortcutBindingCustomized(action)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(action.title)
          .font(.system(size: 13, weight: .semibold))
        if isCustomized {
          Text("Custom")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(themeColor(.selectionForeground))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(themeColor(.selectionBackground))
            .clipShape(Capsule())
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        TextField("Binding", text: configurableShortcutBinding(for: action))
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12, design: .monospaced))
        Button("Reset") {
          preferences.setShortcutBinding(action.defaultBinding, for: action)
        }
        .disabled(!isCustomized)
      }

      Text("Default: \(displayShortcutBinding(action.defaultBinding))")
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(themeColor(.textSecondary))
    }
    .padding(12)
    .background(themeColor(.panelSurface))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(themeColor(.panelDivider), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  fileprivate func shortcutReferenceRow(_ item: ShortcutReference.Entry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(item.keys.joined(separator: " / "))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(themeColor(.panelSurfaceElevated))
          .clipShape(Capsule())
        Text(item.title)
          .font(.system(size: 12))
        Spacer(minLength: 0)
      }
      if let note = item.note, !note.isEmpty {
        Text(note)
          .font(.caption2)
          .foregroundColor(themeColor(.textSecondary))
          .padding(.leading, 4)
      }
    }
  }

  fileprivate func displayShortcutBinding(_ raw: String) -> String {
    raw.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " / ")
  }

  fileprivate func isShortcutBindingCustomized(_ action: ConfigurableShortcutAction)
    -> Bool
  {
    let current = preferences.shortcutBinding(for: action)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let defaultValue = action.defaultBinding
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return !current.isEmpty && current != defaultValue
  }

  fileprivate func shortcutActionMatchesSearch(
    _ action: ConfigurableShortcutAction,
    query: String
  ) -> Bool {
    let normalizedQuery = query.lowercased()
    return action.title.lowercased().contains(normalizedQuery)
      || action.category.lowercased().contains(normalizedQuery)
      || action.defaultBinding.lowercased().contains(normalizedQuery)
      || preferences.shortcutBinding(for: action).lowercased().contains(normalizedQuery)
  }

  fileprivate func shortcutReferenceItemMatchesSearch(
    _ item: ShortcutReference.Entry, query: String
  ) -> Bool {
    let normalizedQuery = query.lowercased()
    return item.keys.contains { $0.lowercased().contains(normalizedQuery) }
      || item.title.lowercased().contains(normalizedQuery)
      || (item.note?.lowercased().contains(normalizedQuery) ?? false)
  }
}
