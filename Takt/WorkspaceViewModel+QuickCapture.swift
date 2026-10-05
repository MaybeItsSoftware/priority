import Foundation
import TaktWorkspace

/// Global capture: what the quick-add hotkey does once it has the workspace.
/// Split from `WorkspaceViewModel.swift` — the same type — because the
/// destination, the start day and the pill row that shows them are a
/// self-contained piece of state nothing else reads.
@MainActor
extension WorkspaceViewModel {
  /// Captures into the inbox — or the list chosen in Settings → Keyboard —
  /// from anywhere: the global hotkey, with no assumption about what was on
  /// screen when it was pressed.
  ///
  /// Selecting the capture list rather than typing into whatever list happened
  /// to be open is the point — a thought caught mid-task belongs in the inbox,
  /// not filed into the project the user was looking at by accident.
  func beginQuickCapture() {
    // Explicitly, rather than relying on `selectList` to do it: the focus
    // screen can be up while the capture list is already the selected list.
    leaveFullPaneScreens()
    let target = quickCaptureHomeList
    if let target, selectedListID != target.id || isEverythingSelected {
      selectList(target.id)
    }
    isQuickCaptureActive = true
    quickCaptureDestinationID = target?.id ?? lists.first?.id
    quickCaptureStartDayOffset = nil
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

  var quickCaptureStartDate: Date? {
    guard let offset = quickCaptureStartDayOffset else { return nil }
    let start = Calendar.current.startOfDay(for: .now)
    return Calendar.current.date(byAdding: .day, value: offset, to: start)
  }

  var quickCaptureStartLabel: String {
    guard let offset = quickCaptureStartDayOffset, let date = quickCaptureStartDate else {
      return "Any day"
    }
    if offset == 1 { return "Tomorrow" }
    if offset == 2 { return "In 2 days" }
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
  }

  func moveQuickCaptureDestination(by offset: Int) {
    let destinations = quickCaptureDestinations
    guard !destinations.isEmpty else { return }
    let current = destinations.firstIndex { $0.id == quickCaptureDestination?.id } ?? 0
    let next = (current + offset + destinations.count) % destinations.count
    quickCaptureDestinationID = destinations[next].id
  }

  func moveQuickCaptureStartDay(by offset: Int) {
    let current = quickCaptureStartDayOffset ?? 0
    let next = max(0, current + offset)
    quickCaptureStartDayOffset = next == 0 ? nil : next
  }

  func cancelQuickCapture() {
    isQuickCaptureActive = false
    quickCaptureDestinationID = nil
    quickCaptureStartDayOffset = nil
  }

  func submitQuickCapture(named title: String) {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, let store, let destination = quickCaptureDestination else { return }
    perform {
      let parentID: String?
      if let nestedParent = destination.parentTaskID {
        parentID = nestedParent
      } else if let list = lists.first(where: { $0.id == destination.listID }) {
        parentID = try visibleRootParentTaskID(for: list, store: store)
      } else {
        parentID = nil
      }
      let task = try store.createTask(
        capturing: normalized, listId: destination.listID, parentTaskId: parentID,
        startAt: quickCaptureStartDate)
      selectedTaskID = destination.listID == selectedListID ? task.id : nil
      cancelQuickCapture()
      reloadOutline()
    }
  }
}
