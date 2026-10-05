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

  func saveCondition(_ condition: TaskCondition, name: String? = nil, isLocation: Bool? = nil, isArchived: Bool? = nil) {
    perform { store in
      try store.saveCondition(
        id: condition.id, name: name ?? condition.name, isLocation: isLocation ?? condition.isLocation,
        isArchived: isArchived ?? condition.isArchived)
    }
  }
}
