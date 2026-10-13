import Foundation
import TaktWorkspace

/// The condition catalogue as the manager draws it: every condition, active
/// first, with how many tasks require each — read in one go off the main
/// actor.
struct ConditionsCatalogue: Sendable, Equatable {
  var conditions: [TaskCondition] = []
  /// Task count per condition ID, over every requirement group.
  var usage: [String: Int] = [:]

  static let empty = ConditionsCatalogue()

  static func load(store: WorkspaceStore, workspaceID: String) throws -> ConditionsCatalogue {
    let conditions = try store.conditions(in: workspaceID)
    var usage: [String: Int] = [:]
    for planning in try store.taskPlanningValues().values {
      for id in Set((planning.requirementGroups ?? []).flatMap { $0 }) { usage[id, default: 0] += 1 }
    }
    return ConditionsCatalogue(conditions: conditions, usage: usage)
  }

  var active: [TaskCondition] { conditions.filter { !$0.isArchived } }
  /// The active conditions under their category headings.
  var activeSections: [TaskConditionSection] { TaskConditionSection.sections(active) }
  /// The categories a condition can be filed under: Location, then every other one in use.
  var categories: [String] { TaskConditionSection.categories(conditions) }
  var archived: [TaskCondition] { conditions.filter(\.isArchived) }
}

/// Writes to the catalogue. Tasks refer to a condition by its ID, so renaming
/// one keeps every requirement naming it, and archiving hides it from the
/// pickers without breaking the tasks that still need it.
@MainActor
extension WorkspaceModel {
  @discardableResult
  func createCondition(named name: String, isLocation: Bool) -> TaskCondition? {
    let workspaceID = workspace.id
    return performReturning { try $0.createCondition(workspaceId: workspaceID, name: name, isLocation: isLocation) }
  }

  /// Makes a condition under a category (nil for none; "Location" makes it a place).
  @discardableResult
  func createCondition(named name: String, category: String?) -> TaskCondition? {
    let workspaceID = workspace.id
    return performReturning { try $0.createCondition(workspaceId: workspaceID, name: name, category: category) }
  }

  /// Files a condition under a category, or none. Location makes it a place;
  /// anything else makes it not one.
  func setConditionCategory(_ condition: TaskCondition, category: String?) {
    perform { store in try store.setConditionCategory(id: condition.id, category: category) }
  }

  func saveCondition(_ condition: TaskCondition, name: String? = nil, isLocation: Bool? = nil, isArchived: Bool? = nil) {
    perform { store in
      try store.saveCondition(
        id: condition.id, name: name ?? condition.name, isLocation: isLocation ?? condition.isLocation,
        isArchived: isArchived ?? condition.isArchived)
    }
  }
}
