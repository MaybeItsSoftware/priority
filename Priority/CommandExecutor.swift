import Foundation
import PriorityCore

@MainActor
final class CommandExecutor {
  private unowned let manager: AppCoordinator

  init(manager: AppCoordinator) {
    self.manager = manager
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func execute(parsed: Command) async {
    // Commands that do not require a current task
    switch parsed {
    case .openPreferences:
      AppDelegate.shared.menuSettings()
      return
    case .openMainWindow:
      AppDelegate.shared.showMainWindow()
      return
    case .openDiagnostics:
      // Diagnostics is a sheet on the main window, so opening it means opening
      // that window first — the panel has nothing to attach a sheet to.
      AppDelegate.shared.showMainWindow()
      manager.popoverChrome.showsDiagnostics = true
      return
    case .reloadCheckvistLists:
      _ = await manager.syncService.loadCheckvistLists(assignFirstIfMissing: false)
      return
    case .uploadOfflineTasks:
      if manager.repository.availableLists.isEmpty {
        _ = await manager.syncService.loadCheckvistLists(assignFirstIfMissing: false)
      }
      let destinationListId =
        manager.repository.listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? manager.repository.availableLists.first.map { String($0.id) } ?? ""
        : manager.repository.listId
      guard !destinationListId.isEmpty else {
        manager.repository.errorMessage = "No Checkvist list available for upload."
        return
      }
      _ = await manager.syncService.uploadOfflineTasksToCheckvist(destinationListId: destinationListId)
      return
    case .addSibling:
      manager.quickEntry.quickEntryMode = .addSibling
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .chooseObsidianInbox:
      _ = manager.integrations.chooseObsidianInboxFolder()
      return
    case .clearObsidianInbox:
      manager.integrations.clearObsidianInboxFolder()
      return
    case .search:
      manager.quickEntry.quickEntryMode = .search
      manager.quickEntry.searchText = ""
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .list(let query):
      guard !query.isEmpty else {
        manager.repository.errorMessage = "Missing list query. Try: list inbox"
        return
      }
      if manager.repository.availableLists.isEmpty {
        _ = await manager.syncService.fetchLists()
      }
      guard
        let found = manager.repository.availableLists.first(where: { $0.name.lowercased().contains(query) })
      else {
        manager.repository.errorMessage = "No list matching \"\(query)\"."
        return
      }
      manager.quickEntry.searchText = ""
      manager.quickEntry.quickEntryText = ""
      // One switch path. Hand-rolling the reset here used to skip the offline
      // queue and the kanban scope, so a list switched from the palette carried
      // the previous list's pending work and column filter into the new one.
      await manager.syncService.switchCheckvistList(to: "\(found.id)")
      return
    case .undo:
      await manager.undoService.undo()
      return
    case .undone:
      if manager.undoService.lastAction == nil {
        manager.repository.errorMessage = "Nothing to undo."
      } else {
        await manager.undoService.undo()
      }
      return
    case .toggleHideFuture:
      manager.taskListViewModel.hideFuture.toggle()
      return
    case .pauseTimer:
      if manager.timer.timerRunning { manager.timer.pauseTimer() } else { manager.timer.resumeTimer() }
      return
    case .refreshMCPPath:
      manager.integrations.refreshMCPServerCommandPath()
      return
    case .copyMCPClientConfig:
      manager.integrations.copyMCPClientConfigurationToClipboard()
      return
    case .openMCPGuide:
      manager.integrations.openMCPServerGuide()
      return
    case .exitParent:
      manager.taskNavigationService.exitToParent()
      return
    case .expandAll:
      manager.taskNavigationService.expandAll()
      manager.statusMessage = "Expanded every task with subtasks"
      return
    case .collapseAll:
      manager.taskNavigationService.collapseAll()
      manager.statusMessage = "Collapsed everything"
      return
    case .quickAdd:
      _ = manager.taskMutationService.beginQuickAddEntry()
      return
    case .toggleContext:
      manager.preferences.showTaskBreadcrumbContext.toggle()
      return
    case .toggleChildrenInMenus:
      manager.taskListViewModel.showChildrenInMenus.toggle()
      manager.statusMessage =
        manager.taskListViewModel.showChildrenInMenus ? "Showing siblings + children" : "Showing siblings only"
      return
    case .editAtStart:
      guard let task = manager.taskListViewModel.currentTask else {
        manager.repository.errorMessage = "No task selected."
        return
      }
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = false
      manager.quickEntry.quickEntryText = task.content
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .openCommandPalette:
      manager.quickEntry.quickEntryMode = .command
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.commandSuggestionIndex = 0
      manager.quickEntry.isQuickEntryFocused = true
      return
    case .syncAFFiNE:
      // A list, not a task: all three stay reachable with nothing selected.
      await manager.integrations.syncAFFiNEChecklist()
      return
    case .openAFFiNEDocument:
      manager.integrations.openAFFiNEDocument(listId: manager.repository.listId)
      return
    case .syncAFFiNEDay:
      await manager.integrations.exportDayToAFFiNE(
        renderedSection: manager.dailyLog.renderedDaySection(),
        titlePattern: manager.dailyLog.dayTitlePattern
      )
      return
    case .unknown(let raw):
      manager.repository.errorMessage = "Unknown command: \(raw)"
      return
    default:
      break
    }

    guard let task = manager.taskListViewModel.currentTask else {
      manager.repository.errorMessage = "No task selected."
      return
    }

    // Commands that require a current task
    switch parsed {
    case .done:
      await manager.taskMutationService.markCurrentTaskDone()
    case .invalidate:
      await manager.taskMutationService.invalidateCurrentTask()
    case .due(let raw):
      guard !raw.isEmpty else {
        manager.repository.errorMessage = "Missing due date/time. Try: due today 14:30"
        return
      }
      let resolved = manager.preferences.resolveDueDate(raw)
      await manager.taskMutationService.updateTask(task: task, due: resolved)
    case .clearDue:
      await manager.taskMutationService.updateTask(task: task, due: "")
    case .setStart(let raw):
      guard !raw.isEmpty else {
        manager.repository.errorMessage = "Missing start date/time. Try: start tomorrow 9am"
        return
      }
      manager.startDates.setStartDate(for: task, rawInput: raw)
    case .clearStart:
      manager.startDates.clearStartDate(for: task)
    case .setRecurrence(let raw):
      guard !raw.isEmpty else {
        manager.repository.errorMessage = "Missing repeat rule. Try: repeat daily, repeat every 3 days"
        return
      }
      manager.setRecurrenceRule(raw, for: task)
    case .clearRecurrence:
      manager.clearRecurrenceRule(for: task)
    case .edit:
      manager.quickEntry.quickEntryMode = .editTask
      manager.quickEntry.editCursorAtEnd = true
      manager.quickEntry.quickEntryText = task.content
      manager.quickEntry.isQuickEntryFocused = true
    case .addChild:
      manager.quickEntry.quickEntryMode = .addChild
      manager.quickEntry.quickEntryText = ""
      manager.quickEntry.isQuickEntryFocused = true
    case .openLink:
      manager.integrations.openTaskLink(task: task)
    case .toggleTimer:
      manager.timer.toggleTimer(forTaskId: task.id)
    case .delete:
      if manager.preferences.confirmBeforeDelete {
        manager.quickEntry.pendingDeleteConfirmation = true
      } else {
        await manager.taskMutationService.deleteTask(task)
      }
    case .moveUp:
      await manager.syncService.moveTask(task, direction: -1)
    case .moveDown:
      await manager.syncService.moveTask(task, direction: 1)
    case .enterChildren:
      manager.taskNavigationService.enterChildren()
    case .expandTask:
      manager.taskNavigationService.setExpanded(true, taskId: task.id)
    case .collapseTask:
      manager.taskNavigationService.setExpanded(false, taskId: task.id)
    case .tag(let tagName):
      guard !tagName.isEmpty else {
        manager.repository.errorMessage = "Missing tag name. Try: tag urgent"
        return
      }
      let tagged =
        task.content.contains("#\(tagName)") ? task.content : "\(task.content) #\(tagName)"
      await manager.taskMutationService.updateTask(task: task, content: tagged)
      manager.statusMessage = "Added tag: #\(tagName)"
      manager.statusMessage = "Added tag: #\(tagName)"
    case .untag(let tagName):
      guard !tagName.isEmpty else {
        manager.repository.errorMessage = "Missing tag name. Try: untag urgent"
        return
      }
      let cleaned = task.content.replacingOccurrences(of: " #\(tagName)", with: "")
        .replacingOccurrences(of: "#\(tagName)", with: "")
        .trimmingCharacters(in: .whitespaces)
      await manager.taskMutationService.updateTask(task: task, content: cleaned)
      manager.statusMessage = "Removed tag: #\(tagName)"
      manager.statusMessage = "Removed tag: #\(tagName)"
    case .priority(let rank):
      manager.taskMutationService.setPriorityForCurrentTask(rank)
    case .priorityBack:
      manager.taskMutationService.sendCurrentTaskToPriorityBack()
    case .clearPriority:
      manager.taskMutationService.clearPriorityForCurrentTask()
    case .syncObsidian:
      await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .standard)
    case .syncObsidianNewWindow:
      await manager.integrations.syncTaskToObsidian(taskId: nil, openMode: .newWindow)
    case .linkObsidianFolder:
      manager.integrations.linkTaskToObsidianFolder()
    case .createObsidianFolder:
      manager.integrations.createAndLinkTaskObsidianFolder()
    case .clearObsidianFolderLink:
      manager.integrations.clearTaskObsidianFolderLink()
    case .syncGoogleCalendar:
      manager.integrations.openTaskInGoogleCalendar()
    default:
      // Handled above
      break
    }
  }
}
