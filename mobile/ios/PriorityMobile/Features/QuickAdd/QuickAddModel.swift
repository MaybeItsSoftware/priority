import Foundation
import Observation
import PriorityCore
import PriorityWorkspace

/// One place quick add can file a task: a list, or a list nested in one
/// (filed as a child of the nested list's task). The Mac's
/// `QuickCaptureDestination`.
struct QuickAddDestination: Identifiable, Equatable, Hashable {
  let id: String
  let listID: String
  let parentTaskID: String?
  let title: String
  /// `Work › Quarterly planning`, for telling nested lists apart.
  let path: String
  let depth: Int
}

/// Quick add: the text, what `TaskCapture` reads off the end of it, where it
/// goes, and filing it.
@MainActor
@Observable
final class QuickAddModel {
  var text = ""
  var destinationID: String?
  var plansToday = false
  /// The titles added in this sitting, newest first, so the sheet can show
  /// what went in while staying open for the next one.
  private(set) var added: [String] = []

  /// What the field will file, read the way the store will read it.
  func capture(now: Date = .now) -> TaskCapture { TaskCapture.parse(text, now: now) }

  /// The chips under the field: estimate, due day, tags, priority.
  func chips(now: Date = .now) -> [String] { capture(now: now).detailLabels(now: now) }

  var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// Every list, each followed by the lists nested in it.
  static func destinations(in structure: WorkspaceStructure) -> [QuickAddDestination] {
    let nested = structure.sidebar.nestedLists
    let titles = Dictionary(nested.map { ($0.id, $0.task) }, uniquingKeysWith: { first, _ in first })
    return structure.listsInTreeOrder.filter { $0.completedAt == nil }.flatMap { list -> [QuickAddDestination] in
      var result = [QuickAddDestination(
        id: list.id, listID: list.id, parentTaskID: nil, title: list.name, path: list.name, depth: 0)]
      result += nested.filter { $0.task.listId == list.id && $0.task.status == .open }.map { item -> QuickAddDestination in
        var components = [item.task.title]
        var parentID = item.task.parentTaskId
        var visited = Set<String>()
        while let id = parentID, visited.insert(id).inserted, let parent = titles[id] {
          components.append(parent.title)
          parentID = parent.parentTaskId
        }
        return QuickAddDestination(
          id: item.task.id, listID: list.id, parentTaskID: item.task.id, title: item.task.title,
          path: ([list.name] + components.reversed()).joined(separator: " › "), depth: item.depth + 1)
      }
      return result
    }
  }

  /// Chooses where the sheet starts: what it was opened from, else the Inbox.
  func prepare(_ model: WorkspaceModel) {
    let navigation = model.navigation
    let destinations = Self.destinations(in: model.structure)
    if let parent = navigation.quickAddParentTaskID, destinations.contains(where: { $0.id == parent }) {
      destinationID = parent
    } else if let parent = navigation.quickAddParentTaskID, let listID = model.task(parent)?.listId {
      // A subtask of an ordinary task: file into its list, under it.
      destinationID = listID
    } else if let listID = navigation.quickAddListID, destinations.contains(where: { $0.id == listID }) {
      destinationID = listID
    } else {
      destinationID = model.inbox?.id ?? destinations.first?.id
    }
  }

  func destination(in model: WorkspaceModel) -> QuickAddDestination? {
    let destinations = Self.destinations(in: model.structure)
    return destinations.first { $0.id == destinationID } ?? destinations.first { $0.id == model.inbox?.id }
      ?? destinations.first
  }

  /// Files the task — title, capture tokens and the Today column, in one undo
  /// step — and clears the field for the next one.
  @discardableResult
  func add(_ model: WorkspaceModel) -> WorkspaceTask? {
    guard canAdd, let destination = destination(in: model) else { return nil }
    let parentTaskID = model.navigation.quickAddParentTaskID.flatMap { parent in
      destination.listID == model.task(parent)?.listId && destination.parentTaskID == nil ? parent : nil
    } ?? destination.parentTaskID
    guard let task = model.createTask(
      text, listID: destination.listID, parentTaskID: parentTaskID,
      kanbanColumn: plansToday ? NextUpSelector.todayColumnID : nil)
    else { return nil }
    added.insert(task.title, at: 0)
    text = ""
    model.showToast("Added to \(destination.title)")
    return task
  }
}
