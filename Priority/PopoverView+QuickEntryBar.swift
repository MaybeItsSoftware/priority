import AppKit
import PriorityCore
import SwiftUI

/// Quick-entry bar (the inline prompt + command palette + autocomplete) and
/// its keyboard/submit helpers. Pulled out of `PopoverView` as part of the
/// Phase-4 split. `breadcrumbPath(for:includeCurrentParent:)` is intentionally
/// left in `PopoverView` itself because the task-row extension also uses it.
extension PopoverView {
  @ViewBuilder
  func quickEntryBar(verticalPadding: CGFloat = 10, leadingInset: CGFloat = 0) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if manager.quickEntry.quickEntryMode == .dueDatePicker {
        dueDatePicker
      } else {
        HStack(alignment: .center, spacing: PopoverLayout.rowContentSpacing) {
          Image(systemName: iconForMode)
            .foregroundColor(themeColor(.textSecondary))
            .font(.system(size: 13))
            .frame(width: PopoverLayout.rowIconWidth, height: 20, alignment: .center)

          QuickEntryField(
            text: activePromptTextBinding,
            isFocused: Bindable(manager).quickEntry.isQuickEntryFocused,
            font: quickEntryNSFont,
            placeholder: placeholderText,
            onSubmit: { submitAction() },
            onTab: { tabAction() },
            onEscape: { escapeAction() }
          )
          .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
          .onChange(of: manager.quickEntry.searchText) { _, _ in
            if manager.quickEntry.quickEntryMode == .search {
              navigationState.currentSiblingIndex = 0
            }
          }
          .onChange(of: manager.quickEntry.quickEntryText) { _, _ in
            if manager.quickEntry.quickEntryMode == .command {
              manager.quickEntry.commandSuggestionIndex = 0
            }
          }

          if !activePromptText.isEmpty || manager.quickEntry.isQuickEntryFocused {
            Button {
              clearPrompt()
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundColor(themeColor(.textSecondary))
                .frame(width: 16, height: 20)
            }.buttonStyle(PlainButtonStyle())
          }

          if repository.isLoading {
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 20)
          }
        }

        if manager.quickEntry.quickEntryMode == .command && manager.quickEntry.isQuickEntryFocused {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filteredCommandSuggestions.enumerated()), id: \.element.label) {
                  idx, suggestion in
                  Button {
                    manager.quickEntry.quickEntryText = suggestion.command
                    if suggestion.submitImmediately {
                      manager.quickEntry.isQuickEntryFocused = false
                      manager.quickEntry.quickEntryMode = .search
                      manager.quickEntry.quickEntryText = ""
                      Task { await manager.executeCommandInput(suggestion.command) }
                    } else {
                      manager.quickEntry.isQuickEntryFocused = true
                    }
                  } label: {
                    HStack(spacing: 8) {
                      VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.label)
                          .font(.system(size: 12, weight: .medium))
                          .foregroundColor(themeColor(.textPrimary))
                        Text(suggestion.preview)
                          .font(.system(size: 10))
                          .foregroundColor(themeColor(.textSecondary))
                      }
                      Spacer(minLength: 8)
                      if let keybind = suggestion.keybind {
                        Text(keybind)
                          .font(.system(size: 11, weight: .medium, design: .monospaced))
                          .foregroundColor(themeColor(.textSecondary))
                          .padding(.horizontal, 6)
                          .padding(.vertical, 2)
                          .background(themeColor(.panelSurfaceElevated))
                          .clipShape(RoundedRectangle(cornerRadius: 4))
                      }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                      idx == manager.quickEntry.commandSuggestionIndex
                        ? themeColor(.selectionBackground) : Color.clear
                    )
                  }
                  .buttonStyle(.plain)
                  .id("cmd-suggestion-\(idx)")
                  if suggestion.label != filteredCommandSuggestions.last?.label {
                    Divider().opacity(0.35)
                  }
                }
              }
            }
            .onChange(of: manager.quickEntry.commandSuggestionIndex) { _, idx in
              withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo("cmd-suggestion-\(idx)", anchor: .center)
              }
            }
            .onChange(of: manager.quickEntry.quickEntryText) { _, _ in
              withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(
                  "cmd-suggestion-\(manager.quickEntry.commandSuggestionIndex)", anchor: .center)
              }
            }
          }
          .frame(maxHeight: 170)
          .background(themeColor(.panelSurface))
          .clipShape(RoundedRectangle(cornerRadius: 7))
        }
      }
    }
    .padding(.leading, PopoverLayout.rowHorizontalPadding + leadingInset)
    .padding(.trailing, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, verticalPadding)
  }

  // MARK: - Helpers

  private var dueDatePicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "calendar")
          .foregroundColor(themeColor(.textSecondary))
        Text("Due date")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(themeColor(.textPrimary))
        Spacer()
        Text(
          manager.quickEntry.dueDatePickerSelection.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        )
        .font(.system(size: 11))
        .foregroundColor(themeColor(.textSecondary))
      }

      DatePicker(
        "Due date",
        selection: Binding(
          get: { manager.quickEntry.dueDatePickerSelection },
          set: { manager.quickEntry.dueDatePickerSelection = $0 }
        ),
        displayedComponents: .date
      )
      .labelsHidden()
      .datePickerStyle(.graphical)
      .frame(maxWidth: .infinity)

      HStack(spacing: 8) {
        Button("Clear") { manager.submitDueDatePicker(clearDueDate: true) }
        Spacer()
        Button("Today") { manager.quickEntry.dueDatePickerSelection = Date() }
        Button("Tomorrow") {
          manager.quickEntry.dueDatePickerSelection =
            Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        }
        Button("Set due date") { manager.submitDueDatePicker() }
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.small)

      Text("←/→ day  ·  ↑/↓ week  ·  ⇧←/⇧→ month  ·  T today  ·  ⌫ clear  ·  Esc cancel")
        .font(.system(size: 9))
        .foregroundColor(themeColor(.textSecondary))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  var iconForMode: String {
    switch manager.quickEntry.quickEntryMode {
    case .search:
      return manager.quickEntry.searchText.isEmpty
        ? "magnifyingglass" : "line.3.horizontal.decrease.circle.fill"
    case .addSibling: return "plus.square"
    case .addSiblingAbove: return "arrow.up.square"
    case .addChild: return "arrow.turn.down.right"
    case .editTask: return "pencil"
    case .command: return "terminal"
    case .dueDatePicker: return "calendar"
    case .quickAddDefault: return "plus.circle"
    case .quickAddSpecific: return "plus.circle.fill"
    }
  }

  var placeholderText: String {
    switch manager.quickEntry.quickEntryMode {
    case .search: return "Search tasks…"
    case .addSibling: return "Add task"
    case .addSiblingAbove: return "Add task above"
    case .addChild: return "Add task"
    case .editTask: return "Edit task..."
    case .command:
      return
        "Action… (done, due [date/time], tag [name], priority [1-9], google calendar)"
    case .dueDatePicker: return "Choose a due date"
    case .quickAddDefault:
      return "Quick add to list root"
    case .quickAddSpecific:
      if let taskId = manager.preferences.quickAddSpecificParentTaskIdValue {
        return "Quick add under task #\(taskId)"
      }
      return "Quick add under specific task (set parent ID in Preferences)"
    }
  }

  var quickEntryNSFont: NSFont {
    switch manager.quickEntry.quickEntryMode {
    case .addSibling, .addSiblingAbove, .addChild, .editTask, .quickAddDefault,
      .quickAddSpecific:
      return Typography.taskNSFont(ofSize: 13, name: manager.preferences.appFontName)
    case .search, .command, .dueDatePicker:
      return Typography.interfaceNSFont(ofSize: 13)
    }
  }

  var filteredCommandSuggestions: [CommandSuggestion] {
    manager.quickEntry.filteredCommandSuggestions(query: manager.quickEntry.quickEntryText)
  }

  func submitAction() {
    switch manager.quickEntry.quickEntryMode {
    case .search:
      manager.quickEntry.isQuickEntryFocused = false
    case .addSibling: submitSibling()
    case .addSiblingAbove: submitSibling(above: true)
    case .addChild: submitChild()
    case .editTask:
      guard !manager.quickEntry.quickEntryText.isEmpty else { return }
      if let task = taskListViewModel.currentTask {
        let newContent = manager.quickEntry.quickEntryText
        escapeAction()
        Task { await manager.taskMutationService.updateTask(task: task, content: newContent) }
      }
    case .command:
      guard !manager.quickEntry.quickEntryText.isEmpty else { return }
      let cmd = manager.quickEntry.quickEntryText
      escapeAction()
      Task { await manager.executeCommandInput(cmd) }
    case .dueDatePicker:
      manager.submitDueDatePicker()
    case .quickAddDefault:
      submitQuickAdd(useSpecificLocation: false)
    case .quickAddSpecific:
      submitQuickAdd(useSpecificLocation: true)
    }
  }

  func tabAction() {
    switch manager.quickEntry.quickEntryMode {
    case .addSibling, .addSiblingAbove, .addChild:
      if manager.quickEntry.quickEntryText.isEmpty {
        manager.quickEntry.quickEntryMode = .addChild
        manager.quickEntry.isQuickEntryFocused = true
        return
      }
      submitChild()
    case .search, .editTask, .command, .dueDatePicker, .quickAddDefault, .quickAddSpecific:
      return
    }
  }

  func escapeAction() {
    manager.quickEntry.isQuickEntryFocused = false
    switch manager.quickEntry.quickEntryMode {
    case .search:
      manager.quickEntry.searchText = ""
    case .dueDatePicker:
      manager.quickEntry.dismissDueDatePicker()
    case .addSibling, .addSiblingAbove, .addChild, .editTask, .command, .quickAddDefault,
      .quickAddSpecific:
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.commandSuggestionIndex = 0
    }
  }

  func escapeEmptyStateAdd() {
    manager.quickEntry.isQuickEntryFocused = false
    manager.quickEntry.quickEntryText = ""
    activateEmptyListComposerModeIfNeeded()
  }

  func submitEmptyStateAdd() {
    manager.quickEntry.quickEntryMode = .addSibling
    submitSibling()
  }

  func activateEmptyListComposerModeIfNeeded() {
    guard shouldShowEmptyListComposer else { return }
    if manager.quickEntry.quickEntryMode == .search {
      manager.quickEntry.quickEntryMode = .addSibling
    }
  }

  /// When the empty-list composer becomes inactive (e.g., user switches to a tab that
  /// has tasks), drop the .addSibling mode we activated for it so the quick-entry bar
  /// doesn't stay open with empty text.
  func deactivateEmptyListComposerModeIfNeeded() {
    guard manager.quickEntry.quickEntryMode == .addSibling,
      manager.quickEntry.quickEntryText.isEmpty
    else { return }
    manager.quickEntry.quickEntryMode = .search
    manager.quickEntry.isQuickEntryFocused = false
  }

  func submitSibling(above: Bool = false) {
    guard !manager.quickEntry.quickEntryText.isEmpty else {
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.isQuickEntryFocused = false
      return
    }
    let content = manager.quickEntry.quickEntryText
    let targetTask = taskListViewModel.currentTask
    manager.quickEntry.quickEntryText = ""
    manager.quickEntry.quickEntryMode = .search
    manager.quickEntry.isQuickEntryFocused = false
    repository.errorMessage = nil
    Task {
      await manager.taskMutationService.addTask(
        content: content, insertAfterTask: targetTask, insertsAbove: above)
    }
  }

  func submitTopLevelAdd() {
    guard !manager.quickEntry.quickEntryText.isEmpty else {
      manager.quickEntry.isQuickEntryFocused = false
      return
    }
    let content = manager.quickEntry.quickEntryText
    manager.quickEntry.quickEntryText = ""
    repository.errorMessage = nil
    manager.quickEntry.isQuickEntryFocused = true
    Task { await manager.taskMutationService.addTask(content: content, insertAtTopOfCurrentLevel: true) }
  }

  func submitChild() {
    guard !manager.quickEntry.quickEntryText.isEmpty, let parent = taskListViewModel.currentTask else {
      if manager.quickEntry.quickEntryText.isEmpty {
        manager.quickEntry.quickEntryText = ""
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.isQuickEntryFocused = false
      }
      return
    }
    let content = manager.quickEntry.quickEntryText
    manager.quickEntry.quickEntryText = ""
    manager.quickEntry.quickEntryMode = .search
    manager.quickEntry.isQuickEntryFocused = false
    repository.errorMessage = nil
    // Open the parent, or the task you just added lands somewhere you can't see.
    manager.taskNavigationService.setExpanded(true, taskId: parent.id)
    Task { await manager.taskMutationService.addTaskAsChild(content: content, parentId: parent.id) }
  }

  func submitQuickAdd(useSpecificLocation: Bool) {
    guard !manager.quickEntry.quickEntryText.isEmpty else { return }
    let content = manager.quickEntry.quickEntryText
    Task {
      await manager.taskMutationService.submitQuickAddTask(content: content, useSpecificLocation: useSpecificLocation)
    }
  }
}
