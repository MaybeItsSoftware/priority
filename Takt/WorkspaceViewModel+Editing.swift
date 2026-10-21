import AppKit
import Foundation
import TaktCore
import TaktWorkspace

@MainActor
extension WorkspaceViewModel {
  func openTaskEditor(_ task: WorkspaceTask) {
    guard let store else { return }
    taskEditor.open(task.id, store: store)
  }

  /// Saves the inspector's draft — asking first what the deadline does when
  /// it starts the task on a later day, and when it moves a repeating task
  /// onto the day it comes round again anyway.
  func saveTaskEditor(_ task: WorkspaceTask) {
    if let draft = taskEditor.draft(for: task.id),
      askAboutStartingLater(draft, title: draft.values.title, proceed: { [weak self] answered, keepingDue in
        guard let self else { return }
        // The inspector stays live under the prompt, so the draft may have
        // moved on since it was asked; only the deadline the answer set goes
        // onto it, not the whole draft as it stood then.
        guard taskEditor.draft(for: task.id) != nil else {
          errorMessage = "“\(task.title)” was not saved: its edit was closed while the due date question was up."
          return
        }
        if answered.values.dueAt != draft.values.dueAt || answered.values.dueDate != draft.values.dueDate {
          taskEditor.edit(task.id) {
            $0.dueAt = answered.values.dueAt
            $0.dueDate = answered.values.dueDate
          }
        }
        saveAnsweredTaskEditor(task, keepingDue: keepingDue)
      }) {
      return
    }
    saveAnsweredTaskEditor(task, keepingDue: false)
  }

  /// The rest of the save once the start's question is answered, or had none.
  private func saveAnsweredTaskEditor(_ task: WorkspaceTask, keepingDue: Bool) {
    if let draft = taskEditor.draft(for: task.id),
      askAboutRecurrenceClash(draft, title: draft.values.title, save: { [weak self] in
        self?.commitTaskEditor(task, keepingDue: keepingDue) ?? false
      }) {
      return
    }
    commitTaskEditor(task, keepingDue: keepingDue)
  }

  @discardableResult
  private func commitTaskEditor(_ task: WorkspaceTask, keepingDue: Bool) -> Bool {
    guard let store, taskEditor.save(task.id, store: store, keepingDue: keepingDue) else { return false }
    reloadOutline()
    reloadDailies()
    reloadFocus()
    reloadNextUp()
    return true
  }

  func revertTaskEditor(_ task: WorkspaceTask) {
    guard let store else { return }
    taskEditor.revert(task.id, store: store)
  }

  /// Adds the selected task to Google Calendar, exactly as the inspector's
  /// button would. Answers false, and does nothing, when nothing is selected
  /// or the selection is a list, which the inspector offers no event for.
  ///
  /// This is what the Google Calendar settings page's "Create event from
  /// selected task" acts on: the desktop window's selection, the only one the
  /// user can see or move.
  @discardableResult
  func addSelectedTaskToGoogleCalendar() -> Bool {
    guard let task = selectedTask, !task.isList else { return false }
    addTaskToGoogleCalendar(task)
    return true
  }

  func addTaskToGoogleCalendar(_ task: WorkspaceTask) {
    guard let store, let creator = googleCalendarEventCreator else {
      errorMessage = "Google Calendar is not available."
      return
    }
    let listTitle = list(for: task)?.name ?? "Takt"
    let timing: CalendarEventTiming
    do {
      timing = try store.taskEditorSnapshot(for: task.id).calendarEventTiming()
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    Task { @MainActor in
      do {
        let eventID = try await creator(task.title, task.id, listTitle, timing.date, timing.isAllDay)
        // Clearing this event off the calendar later is how the task gets
        // completed, so the pairing has to be remembered now.
        if let eventID { onGoogleCalendarEventCreated?(task.id, eventID) }
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func validParentFolders(for folder: ListFolder) -> [ListFolder] {
    guard let store else { return [] }
    return (try? store.validParentFolders(for: folder.id)) ?? []
  }

  func visibleRootCandidates(for list: TaskList) -> [WorkspaceTask] {
    guard let store else { return [] }
    return (try? store.visibleRootCandidates(in: list.id)) ?? []
  }

  func visibleRootPreview(for list: TaskList, rootID: String?) -> [WorkspaceTask] {
    guard let store else { return [] }
    return (try? store.tasks(in: list.id, parentTaskId: rootID)) ?? []
  }

  func saveListSettings(
    _ list: TaskList, name: String, colorHex: String?, folderID: String?,
    isArchived: Bool, visibleRootTaskID: String?
  ) throws {
    guard let store else { throw WorkspaceStoreError.missingList }
    try store.saveListSettings(
      id: list.id, name: name, colorHex: colorHex, folderId: folderID,
      isArchived: isArchived, visibleRootTaskId: visibleRootTaskID)
    refreshAfterEditorCommit()
  }

  func saveFolderSettings(_ folder: ListFolder, name: String, parentFolderID: String?) throws {
    guard let store else { throw WorkspaceStoreError.missingFolder }
    try store.saveFolderSettings(id: folder.id, name: name, parentFolderId: parentFolderID)
    refreshAfterEditorCommit()
  }

  private func refreshAfterEditorCommit() {
    // The edit is already committed. A display error must not report Save as
    // failed and encourage another write of the same edit.
    do { try load() } catch { errorMessage = "Saved, but the workspace could not refresh: \(error.localizedDescription)" }
  }
}
