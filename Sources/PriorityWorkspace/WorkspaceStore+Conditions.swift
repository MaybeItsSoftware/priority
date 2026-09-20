import Foundation
import GRDB
import PriorityCore

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
  public func createCondition(workspaceId: String, name: String, isLocation: Bool = false,
                              now: Date = .now) throws -> TaskCondition {
    let name = try Self.nonEmptyName(name)
    return try journalledWrite("New Condition") { db in
      guard try Workspace.fetchOne(db, key: workspaceId) != nil else { throw TaskPlanningError.invalidCondition }
      let record = TaskCondition(id: UUID().uuidString, workspaceId: workspaceId, name: name,
        isLocation: isLocation, isArchived: false, createdAt: now, updatedAt: now)
      try record.insert(db)
      return record
    }
  }

  public func saveCondition(id: String, name: String, isLocation: Bool, isArchived: Bool,
                            now: Date = .now) throws {
    let name = try Self.nonEmptyName(name)
    try journalledWrite("Edit Condition") { db in
      guard var record = try TaskCondition.fetchOne(db, key: id) else { throw TaskPlanningError.invalidCondition }
      guard record.name != name || record.isLocation != isLocation || record.isArchived != isArchived else { return }
      record.name = name; record.isLocation = isLocation; record.isArchived = isArchived; record.updatedAt = now
      try record.update(db)
    }
  }

  public func applyPlanningToDescendants(of taskId: String) throws {
    try journalledWrite("Apply Planning to Subtasks") { db in
      let parent = try Self.taskEditorSnapshot(db, taskId: taskId)
      let ids = try Self.taskDescendantIDs(db, of: taskId)
      for id in ids {
        var saved = try Self.taskEditorSnapshot(db, taskId: id)
        saved.planning = parent.planning
        // Due dates and estimates remain individual; this action copies only requirements/start/block rules.
        saved.planning?.dueDate = try Self.taskEditorSnapshot(db, taskId: id).planning?.dueDate
        try Self.updatePlanning(db, edit: saved, previous: nil, now: .now)
      }
    }
  }

  static func planning(_ metadata: TaskMetadata?) throws -> TaskPlanning? {
    var result = try metadata?.planningJSON.map { try JSONDecoder().decode(TaskPlanning.self, from: Data($0.utf8)) }
      ?? TaskPlanning()
    result.startAt = metadata?.startAt
    return result.normalized
  }

  static func updatePlanning(_ db: Database, edit: TaskEditorSnapshot,
                             previous: TaskPlanning?, previousDueAt: Date? = nil, now: Date) throws {
    let planning = edit.planning ?? TaskPlanning()
    if let date = planning.dueDate, TaskCalendarDate.date(date) == nil { throw TaskPlanningError.invalidDate }
    let deadline = planning.dueDate.flatMap { TaskCalendarDate.date($0) }
      .flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) } ?? edit.dueAt
    let changedSchedule = planning.startAt != previous?.startAt || planning.dueDate != previous?.dueDate || edit.dueAt != previousDueAt
    if changedSchedule, let start = planning.startAt, let deadline, start >= deadline { throw TaskPlanningError.invalidSchedule }
    if let minimum = planning.minimumBlockSeconds, minimum < 60 { throw TaskPlanningError.invalidMinimum }
    if planning.requiresSingleSitting == true {
      guard let estimate = edit.estimateSeconds, estimate > 0,
        estimate >= (planning.minimumBlockSeconds ?? 60) else { throw TaskPlanningError.estimateRequired }
    }
    let groups = planning.requirementGroups ?? []
    guard Set(groups.map { $0.sorted() }).count == groups.count else { throw TaskPlanningError.invalidCondition }
    for group in groups {
      guard !group.isEmpty, Set(group).count == group.count else { throw TaskPlanningError.invalidCondition }
      for id in group {
        guard let condition = try TaskCondition.fetchOne(db, key: id), condition.workspaceId == edit.workspaceId,
          !condition.isArchived || (previous?.requirementGroups ?? []).contains(where: { $0.contains(id) }) else {
          throw TaskPlanningError.invalidCondition
        }
      }
    }
    let existing = try TaskMetadata.fetchOne(db, key: edit.taskId)
    var record = existing ?? TaskMetadata(taskId: edit.taskId, priority: nil, startAt: nil,
      tagsJSON: "[]", recurrenceRule: nil, matrixUrgency: nil, matrixImportance: nil,
      kanbanColumn: nil, externalLinksJSON: "[]", updatedAt: now)
    var stored = planning
    stored.startAt = nil
    let json = try stored.normalized.flatMap { String(data: try JSONEncoder().encode($0), encoding: .utf8) }
    let current = try Self.planning(record)
    guard current != edit.planning else { return }
    record.startAt = planning.startAt; record.planningJSON = json; record.updatedAt = now
    if existing == nil { try record.insert(db) } else { try record.update(db) }
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
