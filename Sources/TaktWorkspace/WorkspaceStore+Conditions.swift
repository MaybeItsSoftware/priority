import Foundation
import GRDB
import TaktCore

extension WorkspaceStore {
  static func seedConditions(_ db: Database, workspaceId: String, now: Date) throws {
    for (name, location) in [("Home", true), ("Campus", true), ("Private", false), ("Floor space", false)] {
      try TaskCondition(id: UUID().uuidString, workspaceId: workspaceId, name: name,
                        isLocation: location, isArchived: false, createdAt: now, updatedAt: now).insert(db)
    }
  }

  public func conditions(in workspaceId: String) throws -> [TaskCondition] {
    try database.read { db in
      try TaskCondition.filter(Column("workspaceId") == workspaceId)
        .order(Column("createdAt"), Column("id")).fetchAll(db)
    }
  }

  @discardableResult
  /// Creates a condition: the Rust core's `conditions::create_condition`.
  public func createCondition(workspaceId: String, name: String, isLocation: Bool = false,
                              now: Date = .now) throws -> TaskCondition {
    let id = try coreWrite {
      try core.createCondition(
        workspaceId: workspaceId, name: name, isLocation: isLocation, nowMs: now.coreMilliseconds)
    }
    guard let record = try database.read({ db in try TaskCondition.fetchOne(db, key: id) }) else {
      throw TaskPlanningError.invalidCondition
    }
    return record
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

  static func planning(_ metadata: TaskMetadata?) throws -> TaskPlanning? {
    var result = try metadata?.planningJSON.map { try JSONDecoder().decode(TaskPlanning.self, from: Data($0.utf8)) }
      ?? TaskPlanning()
    result.startAt = metadata?.startAt
    return result.normalized
  }

}

extension WorkspaceStore {
  public func taskPlanningValues() throws -> [String: TaskPlanning] {
    try database.read { db in
      var result: [String: TaskPlanning] = [:]
      for record in try TaskMetadata.fetchAll(db) {
        if let plan = try Self.planning(record) { result[record.taskId] = plan }
      }
      return result
    }
  }
}
