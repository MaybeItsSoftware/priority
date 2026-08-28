import AppKit
import OSLog
import PriorityCore

@MainActor
// The dispatch below is still one long function: 60 binding branches, each
// with a body that reaches a different manager. `ShortcutGate`,
// `ShortcutSequenceBuffer` and `ShortcutResolver` have taken the *decisions*
// out to `PriorityCore` where they are tested; what is left is the performing,
// and splitting that by line count alone would not make it clearer.
// swiftlint:disable type_body_length function_body_length cyclomatic_complexity
struct KeyboardShortcutRouter {
  let manager: AppCoordinator
  let logger: Logger
  let updateTitle: () -> Void
  let closeWindow: () -> Void

  /// - Parameter hostWindow: the window this router speaks for. Keys are only
  ///   claimed for events already destined for it, so the panel and the main
  ///   window each install their own monitor and neither sees the other's keys.
  func handle(event: NSEvent, hostWindow: NSWindow?) -> Bool {
    guard let hostWindow, event.window === hostWindow else { return false }

    let shift = event.modifierFlags.contains(.shift)
    let ctrl = event.modifierFlags.contains(.control)
    let cmd = event.modifierFlags.contains(.command)
    let option = event.modifierFlags.contains(.option)
    // The token spelling lives in `PriorityCore` alongside
    // `ConfigurableShortcutAction.defaultBinding`, which has to agree with it.
    let keyToken = ShortcutKeyToken.make(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      shift: shift,
      ctrl: ctrl,
      cmd: cmd,
      option: option
    )
    func matches(_ action: ConfigurableShortcutAction) -> Bool {
      manager.preferences.shortcutMatches(action: action, keyToken: keyToken)
    }

    let firstResponder = event.window?.firstResponder
    let typingInNativeTextField = firstResponder is NSTextView
    // The binding can drift briefly during AppKit focus changes; trust the native
    // first responder so Enter stays with the active text field.
    let isFocused = manager.quickEntry.isQuickEntryFocused || typingInNativeTextField
    // The modal gates — onboarding, the plugin-selection dialog, a running
    // focus session, the focus prompt — decide whether anything below is
    // reached at all. The decision and its precedence live in `PriorityCore`
    // so they can be tested; this is only the part that performs it.
    let gate = ShortcutGate.evaluate(
      ShortcutGate.State(
        needsInitialSetup: manager.needsInitialSetup,
        showsPluginSelectionDialog:
          manager.onboardingService.activeOnboardingDialog == .pluginSelection,
        focusSessionPhase: manager.focusSessionManager.phase.map(Self.gatePhase),
        hasFocusPrompt: manager.focusSessionManager.promptTaskId != nil,
        isTextEntryFocused: isFocused
      ),
      keyCode: event.keyCode,
      shift: shift
    )
    for action in gate.actions { perform(action) }
    switch gate.disposition {
    case .handled: return true
    case .notHandled: return false
    case .continueDispatch: break
    }
    let isRepeat = event.isARepeat
    let chars = event.charactersIgnoringModifiers ?? ""
    if !manager.taskListViewModel.shouldShowRootScopeSection && manager.navigationState.rootScopeFocusLevel != 0 {
      manager.navigationState.rootScopeFocusLevel = 0
    }
    let rootScopeFocused = manager.taskListViewModel.shouldShowRootScopeSection && manager.navigationState.rootScopeFocusLevel > 0
    // Where each binding is live is `ShortcutResolver`'s table, not a guard
    // written out again here. The two used to be the same thing stated twice,
    // which is how the Daily view's Cmd+arrow reorder came to be unreachable.
    let shortcutContext = ShortcutContext(
      rootTaskView: manager.taskListViewModel.rootTaskView,
      isTextEntryFocused: isFocused,
      isRootScopeFocused: rootScopeFocused,
      showsRootScopeSection: manager.taskListViewModel.shouldShowRootScopeSection,
      showsRootFilterControls: manager.taskListViewModel.rootScopeShowsFilterControls,
      hasCommandModifiers: ctrl || cmd || option
    )
    func claims(
      _ action: ConfigurableShortcutAction,
      scope: ShortcutResolver.Scope = .general
    ) -> Bool {
      ShortcutResolver.permits(action, scope: scope, in: shortcutContext) && matches(action)
    }
    // Allow UP arrow to enter the scope row when at the top of the current view.
    // In kanban mode, visibleTasks is intentionally empty (kanban uses per-column task lists),
    // so we check the focused column's first task instead.
    let canFocusRootScopeFromListTop: Bool
    if manager.taskListViewModel.rootTaskView == .kanban {
      canFocusRootScopeFromListTop =
        manager.taskListViewModel.shouldShowRootScopeSection
        && manager.kanban.isAtTopOfFocusedColumn
    } else {
      canFocusRootScopeFromListTop =
        manager.taskListViewModel.shouldShowRootScopeSection
        && manager.navigationState.currentSiblingIndex == 0
        && (!manager.taskListViewModel.visibleTasks.isEmpty || manager.navigationState.currentParentId == 0)
    }

    #if DEBUG
      if cmd && shift && !ctrl && !option && chars.lowercased() == "k" && !isFocused {
        manager.toggleDebugKeychainStorageMode()
        return true
      }
    #endif

    // Reliable fallback for command/actions prompt.
    if claims(.openCommandPalette) {
      manager.quickEntry.keyBuffer = ""
      manager.quickEntry.quickEntryMode = .command
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      manager.quickEntry.commandSuggestionIndex = 0
      logger.log("Opened command palette via Cmd+K")
      return true
    }

    if manager.quickEntry.quickEntryMode == .command && isFocused {
      if event.keyCode == 125 {
        manager.quickEntry.selectNextCommandSuggestion(for: manager.quickEntry.quickEntryText)
        return true
      }
      if event.keyCode == 126 {
        manager.quickEntry.selectPreviousCommandSuggestion(for: manager.quickEntry.quickEntryText)
        return true
      }
      if event.keyCode == 36 {
        let suggestions = manager.quickEntry.filteredCommandSuggestions(query: manager.quickEntry.quickEntryText)
        if suggestions.indices.contains(manager.quickEntry.commandSuggestionIndex) {
          let selected = suggestions[manager.quickEntry.commandSuggestionIndex]
          if selected.submitImmediately {
            manager.quickEntry.isQuickEntryFocused = false
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.quickEntryText = ""
            Task { await manager.executeCommandInput(selected.command) }
          } else {
            manager.quickEntry.quickEntryText = selected.command
            manager.quickEntry.isQuickEntryFocused = true
          }
          return true
        }
      }
    }

    // Delete confirmation: Return confirms, anything else cancels.
    if manager.quickEntry.pendingDeleteConfirmation {
      if event.keyCode == 36 {  // Return - confirm delete.
        manager.quickEntry.pendingDeleteConfirmation = false
        Task {
          if let task = manager.taskListViewModel.currentTask {
            await manager.taskMutationService.deleteTask(task)
            updateTitle()
          }
        }
        return true
      } else {
        manager.quickEntry.pendingDeleteConfirmation = false
        manager.quickEntry.quickEntryText = ""
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.isQuickEntryFocused = false
        if event.keyCode == 53 { return true }  // Escape just cancels.
      }
    }

    // Root scope keyboard navigation:
    // Ctrl+←/→ switches root tabs. Ctrl+↑/↓ cycles Due bucket or Tag filter.
    if claims(.rootCycleTabPrevious) {
      manager.taskNavigationService.cycleRootTaskView(direction: -1)
      return true
    }
    if claims(.rootCycleTabNext) {
      manager.taskNavigationService.cycleRootTaskView(direction: 1)
      return true
    }
    if claims(.rootCycleFilterPrevious) {
      manager.taskNavigationService.cycleRootScopeFilter(direction: -1)
      return true
    }
    if claims(.rootCycleFilterNext) {
      manager.taskNavigationService.cycleRootScopeFilter(direction: 1)
      return true
    }

    // Cmd+←/→ - move task to adjacent kanban column (kanban mode only).
    if claims(.kanbanMoveLeft) {
      if !isRepeat {
        manager.moveCurrentTaskToKanbanColumn(direction: -1)
      }
      return true
    }
    if claims(.kanbanMoveRight) {
      if !isRepeat {
        manager.moveCurrentTaskToKanbanColumn(direction: 1)
      }
      return true
    }
    if claims(.kanbanShowInAll) {
      if !isRepeat, let task = manager.kanban.currentKanbanTask {
        let childCounts = manager.taskListViewModel.childCountByTaskId()
        manager.taskListViewModel.rootTaskView = .all
        manager.navigationState.rootScopeFocusLevel = 0
        if childCounts[task.id, default: 0] > 0 {
          manager.navigationState.currentParentId = task.id
          manager.navigationState.currentSiblingIndex = 0
        } else {
          manager.taskNavigationService.navigate(to: task)
        }
      }
      return true
    }

    // ] / [ - enter or exit the selected task as the current scope.
    // Works in every view: kanban uses its scoped drill, other views use the
    // shared parent-id navigation so the keybind behaves consistently.
    if claims(.kanbanEnterTaskChildren) {
      if !isRepeat {
        if manager.taskListViewModel.rootTaskView == .kanban {
          manager.kanban.enterSelectedTaskAsScope()
        } else {
          manager.taskNavigationService.enterChildren()
          if !manager.quickEntry.searchText.isEmpty {
            manager.quickEntry.searchText = ""
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.isQuickEntryFocused = false
          }
        }
        updateTitle()
      }
      return true
    }
    if claims(.kanbanFocusMode) {
      if !isRepeat, let task = manager.taskListViewModel.currentTask {
        manager.focusSessionManager.presentPrompt(forTaskId: task.id)
        updateTitle()
      }
      return true
    }
    if claims(.kanbanExitToTaskParent) {
      if !isRepeat {
        if manager.taskListViewModel.rootTaskView == .kanban {
          manager.kanban.exitToParentScope()
        } else {
          if !manager.quickEntry.searchText.isEmpty {
            manager.quickEntry.searchText = ""
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.isQuickEntryFocused = false
          }
          manager.taskNavigationService.exitToParent()
        }
        updateTitle()
      }
      return true
    }

    // o / O - open selected task in Obsidian / new Obsidian window.
    if claims(.openInObsidian) {
      if !isRepeat {
        Task {
          await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .standard)
          updateTitle()
        }
      }
      return true
    }
    if claims(.openInObsidianNewWindow) {
      if !isRepeat {
        Task {
          await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .newWindow)
          updateTitle()
        }
      }
      return true
    }

    // Daily view - the dailies checklist owns navigation and the tick.
    // Placed ahead of the shared list navigation because this view renders its
    // own surface and has no `visibleTasks` to move through; falling into
    // `taskNavigationService` here would move a selection nothing is showing.
    if manager.taskListViewModel.rootTaskView == .daily && !isFocused && !rootScopeFocused {
      if claims(.nextTask, scope: .daily) {
        manager.dailyLog.moveDailySelection(by: 1)
        return true
      }
      if claims(.previousTask, scope: .daily) {
        // Only claim Up once the top of the list is passed, so the root scope
        // row stays reachable exactly as it is in every other view.
        if manager.dailyLog.selectedDailyIndex > 0 {
          manager.dailyLog.moveDailySelection(by: -1)
          return true
        }
        if canFocusRootScopeFromListTop {
          manager.navigationState.rootScopeFocusLevel =
            manager.taskListViewModel.rootScopeShowsFilterControls ? 2 : 1
          return true
        }
        return true
      }
      // Space ticks the selected daily. Not Enter: Enter adds, matching the
      // list views where Enter is "new sibling".
      if event.keyCode == 49 && !ctrl && !cmd && !option {
        if !isRepeat, let daily = manager.dailyLog.selectedDaily {
          manager.dailyLog.toggleDaily(daily)
        }
        return true
      }
      if claims(.addSibling, scope: .daily) {
        if !isRepeat { manager.dailyLog.isAddingDaily = true }
        return true
      }
      // Rename in place. Both edit bindings open the same field: a daily is one
      // short line, so "caret at the start" versus "at the end" is a
      // distinction without a difference here, and having only one of the two
      // work would just look broken.
      if claims(.editTaskAtEnd, scope: .daily) || claims(.editTaskAtStart, scope: .daily) {
        if !isRepeat { manager.dailyLog.beginEditingSelectedDaily() }
        return true
      }
      // Archives rather than removes, which is what makes it safe to do without
      // a confirmation — see `DailyLogManager.deleteDaily`. The status line
      // says where it went, because a row vanishing with no explanation is
      // indistinguishable from having lost it.
      if claims(.deleteTask, scope: .daily) {
        if !isRepeat, let daily = manager.dailyLog.deleteSelectedDaily() {
          manager.statusMessage =
            "Deleted \"\(daily.title)\" — restore it in Preferences › Daily Log"
        }
        return true
      }
      // Cmd+↑/↓ reorders, same gesture as moving a task in the list views.
      if claims(.moveTaskUp, scope: .daily) {
        if !isRepeat, let daily = manager.dailyLog.selectedDaily {
          manager.dailyLog.moveDaily(daily, by: -1)
          manager.dailyLog.moveDailySelection(by: -1)
        }
        return true
      }
      if claims(.moveTaskDown, scope: .daily) {
        if !isRepeat, let daily = manager.dailyLog.selectedDaily {
          manager.dailyLog.moveDaily(daily, by: 1)
          manager.dailyLog.moveDailySelection(by: 1)
        }
        return true
      }
    }

    // Cmd+↑/↓ - reorder. Optimistic UI is applied synchronously in moveTask;
    // the API request is queued so key repeat coalesces into the reorder queue.
    //
    // After the Daily view, deliberately. This ran before it until the
    // `ShortcutResolver` table made the shadowing visible: the Daily branch
    // above binds the same gesture to reordering a *daily*, and never saw it,
    // so Cmd+↑/↓ in the Daily view silently reordered a task in the list
    // underneath instead.
    if claims(.moveTaskDown) {
      Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.moveTask(task, direction: 1) } }
      return true
    }
    if claims(.moveTaskUp) {
      Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.moveTask(task, direction: -1) } }
      return true
    }

    // Up/Down arrows - list navigation + root scope navigation.
    if claims(.nextTask) {
      if rootScopeFocused {
        if manager.navigationState.rootScopeFocusLevel == 1 && manager.taskListViewModel.rootScopeShowsFilterControls {
          manager.navigationState.rootScopeFocusLevel = 2
        } else {
          manager.navigationState.rootScopeFocusLevel = 0
        }
        return true
      }
      if manager.taskListViewModel.rootTaskView == .kanban {
        manager.kanban.nextKanbanTask()
      } else {
        manager.taskNavigationService.nextTask()
      }
      updateTitle()
      return true
    }
    if claims(.previousTask) {
      if rootScopeFocused {
        if manager.navigationState.rootScopeFocusLevel == 2 {
          manager.navigationState.rootScopeFocusLevel = 1
        }
        return true
      }
      if canFocusRootScopeFromListTop {
        manager.navigationState.rootScopeFocusLevel = manager.taskListViewModel.rootScopeShowsFilterControls ? 2 : 1
        return true
      }
      if manager.taskListViewModel.rootTaskView == .kanban {
        manager.kanban.previousKanbanTask()
      } else {
        manager.taskNavigationService.previousTask()
      }
      updateTitle()
      return true
    }

    if claims(.enterChildren, scope: .rootScopeRow) {
      if manager.navigationState.rootScopeFocusLevel == 1 {
        manager.taskNavigationService.cycleRootTaskView(direction: 1)
      } else if manager.navigationState.rootScopeFocusLevel == 2 {
        manager.taskNavigationService.cycleRootScopeFilter(direction: 1)
      }
      return true
    }
    if claims(.exitToParent, scope: .rootScopeRow) {
      if manager.navigationState.rootScopeFocusLevel == 1 {
        manager.taskNavigationService.cycleRootTaskView(direction: -1)
      } else if manager.navigationState.rootScopeFocusLevel == 2 {
        manager.taskNavigationService.cycleRootScopeFilter(direction: -1)
      }
      return true
    }
    // Only while the root scope row actually has focus. Unguarded, this
    // swallowed every unmodified Enter in the list — see
    // `ShortcutResolver.dismissesRootScopeRow`.
    if ShortcutResolver.dismissesRootScopeRow(keyCode: event.keyCode, in: shortcutContext) {
      manager.navigationState.rootScopeFocusLevel = 0
      return true
    }

    // In kanban mode, ←/→ (h/l) navigate between columns without moving the task.
    if claims(.kanbanFocusLeft) {
      manager.kanban.focusKanbanColumn(direction: -1)
      updateTitle()
      return true
    }
    if claims(.kanbanFocusRight) {
      manager.kanban.focusKanbanColumn(direction: 1)
      updateTitle()
      return true
    }

    // Shift+→ / Shift+← - zoom the whole list into the selected task, or back
    // out of it. The scope-changing pair, as `]` / `[` are in every view.
    if claims(.zoomIntoTask) {
      manager.navigationState.rootScopeFocusLevel = 0
      if manager.taskListViewModel.rootTaskView == .kanban {
        manager.kanban.enterSelectedTaskAsScope()
      } else {
        manager.taskNavigationService.enterChildren()
        clearSearchFilter()
      }
      updateTitle()
      return true
    }
    if claims(.zoomOutOfTask) {
      manager.navigationState.rootScopeFocusLevel = 0
      if manager.taskListViewModel.rootTaskView == .kanban {
        manager.kanban.exitToParentScope()
      } else {
        clearSearchFilter()
        manager.taskNavigationService.exitToParent()
      }
      updateTitle()
      return true
    }
    // → - open the selected row in place, then walk into what it shows.
    if claims(.enterChildren) {
      if isFocused { return false }
      manager.navigationState.rootScopeFocusLevel = 0
      manager.taskNavigationService.expandOrDescend()
      updateTitle()
      return true
    }
    // ← - shut the row, step back up to its parent, or leave the scope.
    if claims(.exitToParent) {
      if isFocused { return false }
      manager.navigationState.rootScopeFocusLevel = 0
      manager.taskNavigationService.collapseOrAscend()
      updateTitle()
      return true
    }

    // Space - mark done; Shift+Space - invalidate.
    // Ignore key repeat to prevent multiple status changes.
    if claims(.invalidateTask) {
      if !isRepeat {
        Task {
          await manager.taskMutationService.invalidateCurrentTask()
          updateTitle()
        }
      }
      return true
    }
    if claims(.markDone) {
      if !isRepeat {
        Task {
          await manager.taskMutationService.markCurrentTaskDone()
          updateTitle()
        }
      }
      return true
    }

    if claims(.addSibling) {
      if rootScopeFocused {
        manager.navigationState.rootScopeFocusLevel = 0
        return true
      }
      if isFocused { return false }
      // In kanban mode, Enter opens the inline add field in the focused column.
      if manager.taskListViewModel.rootTaskView == .kanban {
        let columns = manager.kanban.kanbanColumns
        let idx = manager.kanban.kanbanFocusedColumnIndex
        if columns.indices.contains(idx) {
          manager.kanban.addingToColumnId = columns[idx].id
          manager.kanban.addText = ""
        }
        return true
      }
      manager.quickEntry.quickEntryMode = .addSibling
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Option+Enter - add a sibling *above* the selection, as Checkvist does.
    // No kanban branch: a column is an unordered bucket there, so "above" has
    // nothing to mean, and Enter's column composer already covers it.
    if claims(.addSiblingAbove) {
      if isFocused { return false }
      if rootScopeFocused { return true }
      guard manager.taskListViewModel.rootTaskView != .kanban else { return true }
      manager.quickEntry.quickEntryMode = .addSiblingAbove
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Cmd+D - duplicate, Checkvist's Ctrl+D. The copy lands directly below the
    // original with the same content; nothing else is carried over, because due
    // dates and tags on a duplicate are as often wrong as right.
    if claims(.duplicateTask) {
      if !isRepeat, let task = manager.taskListViewModel.currentTask {
        Task {
          await manager.taskMutationService.addTask(
            content: task.content, insertAfterTask: task)
        }
      }
      return true
    }

    // ? - the keyboard reference, on the key Checkvist puts it on.
    if claims(.showShortcutReference) {
      if !isRepeat { manager.popoverChrome.showsShortcutReference.toggle() }
      return true
    }
    if claims(.addChild) {
      if rootScopeFocused {
        manager.navigationState.rootScopeFocusLevel = 0
        return true
      }
      if isFocused { return false }
      manager.quickEntry.quickEntryMode = .addChild
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Tab / Shift+Tab - indent and unindent, as in Checkvist.
    //
    // Tab used to be a second binding for "add child", which left Shift+Tab as
    // an unindent whose counterpart indented nothing. It reaches here now
    // because `addChild` above no longer claims it — the two branches are in
    // this order, so a stray `tab` on `addChild` would shadow the indent again.
    if claims(.unindentTask) {
      if isFocused { return false }
      if rootScopeFocused { return true }
      if !isRepeat {
        Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.unindentTask(task) } }
      }
      return true
    }
    if claims(.indentTask) {
      if isFocused { return false }
      if rootScopeFocused { return true }
      if !isRepeat {
        Task { if let task = manager.taskListViewModel.currentTask { await manager.syncService.indentTask(task) } }
      }
      return true
    }

    // Escape - cancel input if active; otherwise close.
    if claims(.closeOrCancel) {
      // The keyboard reference first: it covers the whole panel, so whatever is
      // behind it is not what Escape can plausibly have meant. Its filter field
      // holds focus, which would otherwise send this down the quick-entry
      // branch below and dismiss nothing visible.
      if manager.popoverChrome.showsShortcutReference {
        manager.popoverChrome.showsShortcutReference = false
        return true
      }
      // Dismiss kanban inline add field first.
      if manager.kanban.addingToColumnId != nil {
        manager.kanban.addingToColumnId = nil
        manager.kanban.addText = ""
        return true
      }
      // Then the Daily view's, for the same reason and ahead of the quick-entry
      // branch below: this router runs before the responder chain, so the
      // field's own `.onExitCommand` never sees Escape. Without this the field
      // could only be dismissed by closing the whole popover — and it reopened
      // still showing, because `isAddingDaily` outlives the window.
      if manager.dailyLog.isAddingDaily {
        manager.dailyLog.cancelAddingDaily()
        return true
      }
      // And the rename field, for the same reason: the router runs ahead of the
      // responder chain, so the field's own `.onExitCommand` never sees Escape.
      // Discards the draft — the field commits on Return and on losing focus,
      // so Escape is the only way to say "forget it".
      if manager.dailyLog.editingDailyId != nil {
        manager.dailyLog.cancelDailyEdit()
        return true
      }
      if rootScopeFocused {
        manager.navigationState.rootScopeFocusLevel = 0
        return true
      }
      if manager.quickEntry.quickEntryMode == .search {
        if isFocused || !manager.quickEntry.searchText.isEmpty {
          manager.quickEntry.isQuickEntryFocused = false
          manager.quickEntry.searchText = ""
          return true
        }
      } else if isFocused || !manager.quickEntry.quickEntryText.isEmpty {
        manager.quickEntry.isQuickEntryFocused = false
        manager.quickEntry.quickEntryMode = .search
        manager.quickEntry.quickEntryText = ""
        manager.quickEntry.commandSuggestionIndex = 0
        return true
      }
      closeWindow()
      return true
    }

    // F2 - edit task, cursor at end.
    if claims(.editTaskAtEnd) {
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = true
      manager.quickEntry.quickEntryText = manager.taskListViewModel.currentTask?.content ?? ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Copy task (and subtree) to clipboard
    if claims(.copyTask) {
      if !isRepeat, let task = manager.taskListViewModel.currentTask {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let childCount = manager.taskListViewModel.childCountByTaskId()[task.id] ?? 0
        if childCount > 0,
           let range = manager.taskListViewModel.subtreeBlockRange(
             for: task.id, in: manager.repository.tasks) {
          let subtreeTasks = Array(manager.repository.tasks[range])
          let treeText = TaskTreeFormatter.formatAsTree(
            root: task, allTasks: subtreeTasks)
          pasteboard.setString(treeText, forType: .string)
          manager.statusMessage = "Copied task + \(childCount) subtask\(childCount == 1 ? "" : "s") to clipboard"
        } else {
          pasteboard.setString(task.content, forType: .string)
          manager.statusMessage = "Copied task to clipboard"
        }
      }
      return true
    }

    // Delete (either delete key) - delete task, behind a confirmation by default.
    if claims(.deleteTask) {
      if isRepeat { return true }
      if manager.preferences.confirmBeforeDelete {
        manager.quickEntry.pendingDeleteConfirmation = true
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = ""
        manager.quickEntry.isQuickEntryFocused = false
      } else {
        Task {
          if let task = manager.taskListViewModel.currentTask {
            await manager.taskMutationService.deleteTask(task)
            updateTitle()
          }
        }
      }
      return true
    }

    // q/w/e/r - root tab shortcuts: All / Due / Tags / Priority.
    if claims(.rootTabAll) {
      manager.taskNavigationService.setRootTaskView(.all)
      updateTitle()
      return true
    }
    if claims(.rootTabDue) {
      manager.taskNavigationService.setRootTaskView(.due)
      updateTitle()
      return true
    }
    if claims(.rootTabTags) {
      manager.taskNavigationService.setRootTaskView(.tags)
      updateTitle()
      return true
    }
    if claims(.rootTabPriority) {
      manager.taskNavigationService.setRootTaskView(.priority)
      updateTitle()
      return true
    }
    if claims(.rootTabKanban) {
      manager.taskNavigationService.setRootTaskView(.kanban)
      updateTitle()
      return true
    }
    if claims(.rootTabMatrix) {
      manager.taskNavigationService.setRootTaskView(.eisenhower)
      updateTitle()
      return true
    }
    if claims(.rootTabDaily) {
      manager.taskNavigationService.setRootTaskView(.daily)
      updateTitle()
      return true
    }

    // z/x/c/v/b/n/m - lower root filter shortcuts (Due/Tags row options).
    if !isFocused && manager.taskListViewModel.rootScopeShowsFilterControls {
      let rootFilterActions: [ConfigurableShortcutAction] = [
        .rootFilter1, .rootFilter2, .rootFilter3, .rootFilter4, .rootFilter5, .rootFilter6,
        .rootFilter7,
      ]
      if let filterIndex = rootFilterActions.firstIndex(where: { claims($0) }) {
        manager.taskNavigationService.selectRootScopeFilter(at: filterIndex)
        updateTitle()
        return true
      }
    }

    // Two-key sequences.
    let sequenceActions = ConfigurableShortcutAction.twoKeySequenceActions
    let sequenceTokens = sequenceActions.flatMap {
      manager.preferences.shortcutBinding(for: $0).split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }
    }
    let matrixSequenceStarters = ShortcutSequenceBuffer.starters(
      fromBindings: manager.preferences.shortcutBinding(for: .sequenceMatrixCoord)
        .split(separator: ",").map(String.init))
    let sequenceStarters = ShortcutSequenceBuffer.starters(fromBindings: sequenceTokens)
    // The two-key sequence state machine. Which keys start a sequence, when a
    // pending one advances rather than completes, and when the buffer is
    // dropped all live in `PriorityCore`; this performs the result.
    let sequenceStep = ShortcutSequenceBuffer.advance(
      buffer: manager.quickEntry.keyBuffer,
      characters: chars,
      starters: sequenceStarters,
      matrixStarters: matrixSequenceStarters,
      isTextEntryFocused: isFocused,
      shift: shift,
      ctrl: ctrl
    )
    manager.quickEntry.keyBuffer = sequenceStep.buffer
    switch sequenceStep.effect {
    case .pass:
      break
    case .awaitSecondKey:
      return true
    case .reportMatrixUrgency(let digit):
      manager.statusMessage = "Matrix: (\(digit), _)"
      return true
    case .applyMatrixCoordinate(let urgency, let importance):
      placeCurrentTaskOnMatrix(urgency: urgency, importance: importance)
      return true
    case .applyMatrixQuadrant(let quadrant):
      let point = quadrant.representativeCoordinate
      placeCurrentTaskOnMatrix(
        urgency: point.urgency, importance: point.importance, quadrantName: quadrant.title)
      return true
    case .clearMatrixCoordinate:
      guard let task = manager.taskListViewModel.currentTask else {
        manager.repository.errorMessage = "No task selected."
        return true
      }
      manager.repository.setUrgency(taskId: task.id, level: 0)
      manager.repository.setImportance(taskId: task.id, level: 0)
      manager.repository.errorMessage = nil
      manager.statusMessage = "Removed from the matrix."
      updateTitle()
      return true
    case .abandon:
      return false
    case .attempt(let sequence):
      if manager.preferences.shortcutMatchesSequence(action: .sequenceDue, sequence: sequence) {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "due "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceDueToday, sequence: sequence)
      {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "due today "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceStart, sequence: sequence) {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "start "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceRepeat, sequence: sequence) {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "repeat "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceOpenLink, sequence: sequence)
      {
        if let task = manager.taskListViewModel.currentTask { manager.integrations.openTaskLink(task: task) }
        return true
      }
      if manager.preferences.shortcutMatchesSequence(
        action: .sequenceGoogleCalendar,
        sequence: sequence
      ) {
        manager.integrations.openTaskInGoogleCalendar()
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceTag, sequence: sequence) {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "tag "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      // Not a command-palette prefix like its neighbours: this one switches a
      // block of the view on, so it acts and reports rather than opening a
      // field to type into.
      if manager.taskListViewModel.rootTaskView == .eisenhower,
        manager.preferences.shortcutMatchesSequence(
          action: .matrixToggleUnplaced, sequence: sequence)
      {
        let chrome = manager.popoverChrome
        chrome.showsMatrixUnplaced.toggle()
        manager.statusMessage =
          chrome.showsMatrixUnplaced
          ? "Unplaced: \(manager.taskListViewModel.cache.matrixUnplacedTasks.count)"
          : "Unplaced list hidden."
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceMatrixCoord, sequence: sequence)
      {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "matrix "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceUrgency, sequence: sequence) {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "urgency "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceImportance, sequence: sequence) {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "importance "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(action: .sequenceUntag, sequence: sequence) {
        manager.quickEntry.quickEntryMode = .command
        manager.quickEntry.commandSuggestionIndex = 0
        manager.quickEntry.quickEntryText = "untag "
        manager.quickEntry.isQuickEntryFocused = true
        return true
      }
      if manager.preferences.shortcutMatchesSequence(
        action: .sequenceToggleContext,
        sequence: sequence
      ) {
        manager.preferences.showTaskBreadcrumbContext.toggle()
        return true
      }
      // A sequence that matched nothing is handed on unclaimed rather than
      // retried as a single-key binding.
      return false
    }

    // p - toggle timer on current task.
    if claims(.toggleTimer) {
      if !isRepeat && manager.timer.timerIsEnabled {
        if let task = manager.taskListViewModel.currentTask {
          manager.timer.toggleTimer(forTaskId: task.id)
        }
      }
      return true
    }

    // shift+p - pause/resume timer.
    if claims(.toggleTimerPause) {
      if !isRepeat && manager.timer.timerIsEnabled {
        if manager.timer.timerRunning { manager.timer.pauseTimer() } else { manager.timer.resumeTimer() }
      }
      return true
    }

    // j/k/u - Vim up/down navigation, undo.
    if claims(.undo) {
      if !isRepeat { Task { await manager.undoService.undo() } }
      return true
    }

    // H (Shift+h) - toggle hide future.
    if claims(.toggleHideFuture) {
      manager.taskListViewModel.hideFuture.toggle()
      return true
    }

    // Shift+L - fast list switch prompt.
    if claims(.quickListSwitch) {
      manager.quickEntry.quickEntryMode = .command
      manager.quickEntry.commandSuggestionIndex = 0
      manager.quickEntry.quickEntryText = "list "
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // Shift+A - quick add using the configured quick add location.
    if claims(.quickAdd) {
      _ = manager.taskMutationService.beginQuickAddEntry()
      return true
    }

    // Forward-slash - focus search.
    if claims(.focusSearch) {
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    // 1-9 set scoped priority, Hyper+1-9 (Ctrl+Cmd+Option+Shift) set absolute priority,
    // = sends to the back of prioritized tasks, - clears priority.
    if !isFocused && !rootScopeFocused {
      if claims(.clearAbsolutePriority) {
        manager.taskMutationService.clearAbsolutePriorityForCurrentTask()
        updateTitle()
        return true
      }
      if claims(.clearPriority) {
        manager.taskMutationService.clearPriorityForCurrentTask()
        updateTitle()
        return true
      }
      if claims(.pushPriorityBack) {
        manager.taskMutationService.sendCurrentTaskToPriorityBack()
        updateTitle()
        return true
      }
      let keyCodePriority: Int? = {
        switch event.keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
      }()

      if claims(.setPriorityRank),
        let priority = Int(chars) ?? keyCodePriority,
        (1...TaskRepository.maxPriorityRank).contains(priority)
      {
        manager.taskMutationService.setPriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
      if claims(.setAbsolutePriorityRank),
        let priority = Int(chars) ?? keyCodePriority,
        (1...TaskRepository.maxPriorityRank).contains(priority)
      {
        manager.taskMutationService.setAbsolutePriorityForCurrentTask(priority)
        updateTitle()
        return true
      }
    }

    // i - insert, a - append.
    if claims(.editTaskAtStart) {
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = false
      manager.quickEntry.quickEntryText = manager.taskListViewModel.currentTask?.content ?? ""
      manager.quickEntry.isQuickEntryFocused = true
      return true
    }

    return false
  }

}
// swiftlint:enable type_body_length function_body_length cyclomatic_complexity

// MARK: - Matrix placement

extension KeyboardShortcutRouter {
  /// Place the selected task, then step to the next unplaced one.
  ///
  /// The advance is what turns two keystrokes per task into a sorting pass:
  /// with the matrix open you hold position and type `md`, `ms`, `me` down a
  /// backlog without ever moving the selection by hand. Outside the matrix
  /// there is nothing to sort through, so the selection stays where it was and
  /// the placement is just a placement.
  @MainActor func placeCurrentTaskOnMatrix(
    urgency: Double, importance: Double, quadrantName: String? = nil
  ) {
    guard let task = manager.taskListViewModel.currentTask else {
      manager.repository.errorMessage = "No task selected."
      return
    }
    manager.repository.setUrgency(taskId: task.id, level: urgency)
    manager.repository.setImportance(taskId: task.id, level: importance)
    manager.repository.errorMessage = nil

    let coordinate = "(\(Int(urgency)), \(Int(importance)))"
    let name =
      quadrantName ?? MatrixGeometry.quadrant(urgency: urgency, importance: importance).title
    manager.statusMessage = "Matrix: \(coordinate) — \(name)"

    if manager.taskListViewModel.rootTaskView == .eisenhower {
      advanceToNextUnplacedTask(after: task)
    }
    updateTitle()
  }

  /// The next task in the current scope with no coordinate, searched forward
  /// from the one just placed and wrapping once.
  ///
  /// Wrapping matters: placements land tasks anywhere in the order, so a strict
  /// forward search would strand the ones above the cursor and the pass would
  /// look finished while the rail still had entries in it.
  @MainActor private func advanceToNextUnplacedTask(after task: CheckvistTask) {
    let levels = manager.repository.taskEisenhowerLevels
    let scopeId = manager.navigationState.currentParentId
    let showChildren = manager.taskListViewModel.showChildrenInMenus
    let scoped = manager.repository.tasks.filter { candidate in
      guard candidate.status == 0 else { return false }
      if showChildren {
        return manager.taskListViewModel.isDescendant(candidate, of: scopeId)
      }
      return (candidate.parentId ?? 0) == scopeId
    }
    guard let placedIndex = scoped.firstIndex(where: { $0.id == task.id }) else { return }

    let following = scoped[(placedIndex + 1)...]
    let preceding = scoped[..<placedIndex]
    let isUnplaced: (CheckvistTask) -> Bool = { candidate in
      let level = levels[candidate.id] ?? .zero
      return !MatrixGeometry.isPlaced(urgency: level.urgency, importance: level.importance)
    }
    guard let next = following.first(where: isUnplaced) ?? preceding.first(where: isUnplaced)
    else { return }
    manager.taskNavigationService.navigate(to: next)
  }
}
