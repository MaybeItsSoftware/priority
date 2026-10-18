import Foundation
import TaktCore
import TaktWorkspace

/// Global capture: what the quick-add hotkey does once it has the workspace.
/// Split from `WorkspaceViewModel.swift` — the same type — because the
/// destination and the list that shows it are a self-contained piece of
/// state nothing else reads. The due day, conditions and estimate the
/// field's slots hold are the field's own (`TaskEntryDraft`), handed over
/// with the title on Return.
@MainActor
extension WorkspaceViewModel {
  /// Captures into the inbox — or the list chosen in Settings → Keyboard —
  /// from anywhere: the global hotkey, with no assumption about what was on
  /// screen when it was pressed.
  ///
  /// Selecting the capture list rather than typing into whatever list happened
  /// to be open is the point — a thought caught mid-task belongs in the inbox,
  /// not filed into the project the user was looking at by accident.
  ///
  /// It types in its own window (`QuickCapturePanelController`), so the main
  /// window's list and selection are left alone.
  func beginQuickCapture() {
    let target = quickCaptureHomeList
    isQuickCaptureActive = true
    quickCaptureDestinationID = target?.id ?? lists.first?.id
    requestTaskComposerFocus()
  }

  /// Where capture starts: the preferred list while it exists, else the inbox.
  var quickCaptureHomeList: TaskList? {
    let preferred = preferredQuickCaptureListID()
    return lists.first { !preferred.isEmpty && $0.id == preferred } ?? inboxList
  }

  var quickCaptureDestinations: [QuickCaptureDestination] {
    lists.flatMap { list -> [QuickCaptureDestination] in
      var result = [QuickCaptureDestination(
        id: list.id, listID: list.id, parentTaskID: nil, title: list.name,
        path: list.name, depth: 0)]
      result += nestedLists.filter { $0.task.listId == list.id }.map { item in
        var components = [item.task.title]
        var parentID = item.task.parentTaskId
        var visited = Set<String>()
        while let id = parentID, visited.insert(id).inserted, let parent = task(withID: id) {
          if parent.isList && parent.id != list.visibleRootTaskId { components.append(parent.title) }
          parentID = parent.parentTaskId
        }
        let path = ([list.name] + components.reversed()).joined(separator: " › ")
        return QuickCaptureDestination(
          id: item.task.id, listID: list.id, parentTaskID: item.task.id,
          title: item.task.title, path: path, depth: item.depth + 1)
      }
      return result
    }
  }

  var quickCaptureDestination: QuickCaptureDestination? {
    let destinations = quickCaptureDestinations
    return destinations.first { $0.id == quickCaptureDestinationID }
      ?? destinations.first { destination in
        lists.first(where: { $0.id == destination.listID })?.systemRole == .inbox
      }
      ?? destinations.first
  }

  func moveQuickCaptureDestination(by offset: Int) {
    let destinations = quickCaptureDestinations
    guard !destinations.isEmpty else { return }
    let current = destinations.firstIndex { $0.id == quickCaptureDestination?.id } ?? 0
    let next = (current + offset + destinations.count) % destinations.count
    quickCaptureDestinationID = destinations[next].id
  }

  func cancelQuickCapture() {
    isQuickCaptureActive = false
    quickCaptureDestinationID = nil
  }

  /// Files the capture where it has been steered, with what its slots hold —
  /// a due day and an estimate that win over the title's words, and the
  /// conditions it needs — as one undo step.
  func submitQuickCapture(named title: String, slots: TaskEntryDraft = TaskEntryDraft()) {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, let destination = quickCaptureDestination else { return }
    let task = createTask(capturing: normalized, in: destination, slots: slots)
    guard let task else { return }
    selectedTaskID = destination.listID == selectedListID ? task.id : nil
    cancelQuickCapture()
  }

  /// Files a task at the top level of a list or nested list — under the
  /// list's wrapper root where an import gave it one — reading the title's
  /// trailing words as the add field does. One undo step. Quick add's, and
  /// the focus panel's when it is showing a list.
  @discardableResult
  func createTask(
    capturing title: String, in destination: QuickCaptureDestination, slots: TaskEntryDraft = TaskEntryDraft()
  ) -> WorkspaceTask? {
    guard let store else { return nil }
    var created: WorkspaceTask?
    perform {
      let parentID: String?
      if let nestedParent = destination.parentTaskID {
        parentID = nestedParent
      } else if let list = lists.first(where: { $0.id == destination.listID }) {
        parentID = try visibleRootParentTaskID(for: list, store: store)
      } else {
        parentID = nil
      }
      created = try store.createTask(
        capturing: title, listId: destination.listID, parentTaskId: parentID,
        dueAt: slots.dueDate, estimateSeconds: slots.estimateSeconds,
        requirementGroups: slots.requirementGroups)
      reloadOutline()
    }
    return created
  }
}
