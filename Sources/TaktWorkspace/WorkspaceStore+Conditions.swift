import Foundation
import TaktCore

extension WorkspaceStore {

  public func conditions(in workspaceId: String) throws -> [TaskCondition] {
    try Self.mappingCoreErrors { try core.conditions(workspaceId: workspaceId) }.map(TaskCondition.init)
  }

  @discardableResult
  /// Creates a condition: the Rust core's `conditions::create_condition`.
  public func createCondition(workspaceId: String, name: String, isLocation: Bool = false,
                              now: Date = .now) throws -> TaskCondition {
    let id = try coreWrite {
      try core.createCondition(
        workspaceId: workspaceId, name: name, isLocation: isLocation, nowMs: now.coreMilliseconds)
    }
    guard let record = try Self.mappingCoreErrors({ try core.condition(id: id) }).map(TaskCondition.init) else {
      throw TaskPlanningError.invalidCondition
    }
    return record
  }

  @discardableResult
  /// Creates a condition under a category (nil for none; "Location" makes it
  /// a place): the Rust core's `conditions::create_condition_in_category`.
  public func createCondition(workspaceId: String, name: String, category: String?,
                              now: Date = .now) throws -> TaskCondition {
    let id = try coreWrite {
      try core.createConditionInCategory(
        workspaceId: workspaceId, name: name, category: category, nowMs: now.coreMilliseconds)
    }
    guard let record = try Self.mappingCoreErrors({ try core.condition(id: id) }).map(TaskCondition.init) else {
      throw TaskPlanningError.invalidCondition
    }
    return record
  }

  /// Files a condition under a category, or none: the Rust core's
  /// `conditions::set_condition_category`. "Location" makes it a place and
  /// anything else makes it not one.
  public func setConditionCategory(id: String, category: String?, now: Date = .now) throws {
    try coreWrite {
      try core.setConditionCategory(id: id, category: category, nowMs: now.coreMilliseconds)
    }
  }

  /// The conditions an open task in the workspace requires: the Rust core's
  /// `conditions::required_condition_ids`.
  public func requiredConditionIDs(in workspaceId: String) throws -> Set<String> {
    Set(try Self.mappingCoreErrors { try core.requiredConditionIds(workspaceId: workspaceId) })
  }

  /// Saves a condition: the Rust core's `conditions::save_condition`.
  public func saveCondition(id: String, name: String, isLocation: Bool, isArchived: Bool,
                            now: Date = .now) throws {
    try coreWrite {
      try core.saveCondition(
        id: id, name: name, isLocation: isLocation, isArchived: isArchived, nowMs: now.coreMilliseconds)
    }
  }

  /// Copies a task's requirements, start and block rules onto its subtasks,
  /// each keeping its own due date: the Rust core's
  /// `editor::apply_planning_to_descendants`.
  public func applyPlanningToDescendants(of taskId: String) throws {
    try coreWrite {
      try core.applyPlanningToDescendants(taskId: taskId, nowMs: Date.now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
  }

}

extension WorkspaceStore {
  public func taskPlanningValues() throws -> [String: TaskPlanning] {
    // Decoded and normalised in the core: one crossing, only the planned tasks.
    let entries = try Self.mappingCoreErrors { try core.taskPlanningValues() }
    return Dictionary(entries.map { ($0.taskId, TaskPlanning($0.planning)) }, uniquingKeysWith: { _, last in last })
  }
}
