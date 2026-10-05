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

  func saveTaskEditor(_ task: WorkspaceTask) {
    guard let store, taskEditor.save(task.id, store: store) else { return }
    reloadOutline()
    reloadDailies()
    reloadFocus()
    reloadNextUp()
  }

  func revertTaskEditor(_ task: WorkspaceTask) {
    guard let store else { return }
    taskEditor.revert(task.id, store: store)
  }

  func addTaskToGoogleCalendar(_ task: WorkspaceTask) {
    guard let store, let creator = googleCalendarEventCreator else {
      errorMessage = "Google Calendar is not available."
      return
    }
    let listTitle = list(for: task)?.name ?? "Takt"
    let snapshot: TaskEditorSnapshot
    do {
      snapshot = try store.taskEditorSnapshot(for: task.id)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    let planning = snapshot.planning
    let date: Date?
    let isAllDay: Bool
    if let exactDue = snapshot.dueAt {
      date = exactDue
      isAllDay = false
    } else if let dueDay = planning?.dueDate.flatMap({ TaskCalendarDate.date($0) }) {
      date = dueDay
      isAllDay = true
    } else if let start = planning?.startAt {
      date = start
      isAllDay = false
    } else {
      date = nil
      isAllDay = false
    }

    Task { @MainActor in
      do {
        let eventID = try await creator(task.title, task.id, listTitle, date, isAllDay)
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
