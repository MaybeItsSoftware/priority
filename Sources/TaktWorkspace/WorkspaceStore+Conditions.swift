import Foundation
import TaktCore
import TaktRustCore

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

  /// How many open tasks require each condition, by id: the Rust core's
  /// `conditions::condition_usage`. Completed and archived tasks, and those
  /// in archived lists, do not count.
  public func conditionUsage(in workspaceId: String) throws -> [String: Int] {
    let usage = try Self.mappingCoreErrors { try core.conditionUsage(workspaceId: workspaceId) }
    return Dictionary(usage.map { ($0.conditionId, Int($0.openTasks)) }, uniquingKeysWith: { _, last in last })
  }

  /// The open tasks that require a condition, list by list.
  public func tasksRequiring(condition id: String, in workspaceId: String) throws -> [RequiringTask] {
    try Self.mappingCoreErrors { try core.tasksRequiringCondition(workspaceId: workspaceId, conditionId: id) }
  }

  /// Moves a condition one place up (negative) or down under its heading.
  @discardableResult
  public func moveCondition(id: String, by offset: Int, now: Date = .now) throws -> Bool {
    try coreWrite { try core.moveCondition(id: id, offset: Int64(offset), nowMs: now.coreMilliseconds) }
  }

  /// Moves a whole heading (nil for "Other") one place up or down.
  @discardableResult
  public func moveConditionCategory(_ category: String?, in workspaceId: String, by offset: Int,
                                    now: Date = .now) throws -> Bool {
    try coreWrite {
      try core.moveConditionCategory(
        workspaceId: workspaceId, category: category, offset: Int64(offset), nowMs: now.coreMilliseconds)
    }
  }

  /// Files every condition under one heading under another, keeping their
  /// places; onto a category in use, the two merge.
  @discardableResult
  public func renameConditionCategory(_ from: String?, to: String?, in workspaceId: String,
                                      now: Date = .now) throws -> Int {
    Int(try coreWrite {
      try core.renameConditionCategory(workspaceId: workspaceId, from: from, to: to, nowMs: now.coreMilliseconds)
    })
  }

  /// Merges a condition into another: its tasks require the other, and it
  /// is archived. Returns how many tasks changed.
  @discardableResult
  public func mergeConditions(_ from: String, into: String, now: Date = .now) throws -> Int {
    Int(try coreWrite { try core.mergeConditions(from: from, into: into, nowMs: now.coreMilliseconds) })
  }

  /// What holds now, as last saved, or nil if it never was.
  public func focusContext(in workspaceId: String) throws -> SavedFocusContext? {
    try Self.mappingCoreErrors { try core.focusContext(workspaceId: workspaceId) }.map(SavedFocusContext.init)
  }

  /// Saves what holds now. Not an undo step. The core stamps when the
  /// conditions on were said, whatever `conditionsSetAt` carries.
  @discardableResult
  public func saveFocusContext(_ context: SavedFocusContext, in workspaceId: String, now: Date = .now) throws -> Bool {
    try Self.mappingCoreErrors {
      try core.saveFocusContext(workspaceId: workspaceId, context: context.core, nowMs: now.coreMilliseconds)
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

/// What holds now — the conditions on, the time available, the goal, when
/// the answer lapses and what was set aside when it last did — as the
/// workspace keeps it (`focus_contexts`), where the CLI and the agent can
/// read and set it too.
public struct SavedFocusContext: Equatable, Sendable {
  public var conditionIDs: Set<String>
  /// When the conditions on were said; nil with none on.
  public var conditionsSetAt: Date?
  public var availableUntil: Date?
  public var expiresAt: Date?
  public var mode: FocusTimeMode
  public var suggestedIDs: Set<String>

  public init(
    conditionIDs: Set<String> = [], conditionsSetAt: Date? = nil, availableUntil: Date? = nil,
    expiresAt: Date? = nil, mode: FocusTimeMode = .progress, suggestedIDs: Set<String> = []
  ) {
    self.conditionIDs = conditionIDs; self.conditionsSetAt = conditionsSetAt
    self.availableUntil = availableUntil; self.expiresAt = expiresAt
    self.mode = mode; self.suggestedIDs = suggestedIDs
  }

  init(_ core: StoredFocusContext) {
    self.init(
      conditionIDs: Set(core.conditionIds), conditionsSetAt: core.conditionsSetAtMs.map(Date.init(coreMilliseconds:)),
      availableUntil: core.availableUntilMs.map(Date.init(coreMilliseconds:)), expiresAt: core.expiresAtMs.map(Date.init(coreMilliseconds:)),
      mode: FocusTimeMode(rawValue: core.mode) ?? .progress, suggestedIDs: Set(core.suggestedIds))
  }

  var core: StoredFocusContext {
    StoredFocusContext(
      conditionIds: conditionIDs.sorted(), conditionsSetAtMs: conditionsSetAt?.coreMilliseconds,
      availableUntilMs: availableUntil?.coreMilliseconds, expiresAtMs: expiresAt?.coreMilliseconds,
      mode: mode.rawValue, suggestedIds: suggestedIDs.sorted())
  }

  /// Whether it had lapsed by `now`.
  public func hasExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }

  /// As it stands at `now`: once expired, its conditions are set aside to be
  /// offered back. The core's `focus_context_in_force`.
  public func inForce(at now: Date) -> SavedFocusContext {
    SavedFocusContext(focusContextInForce(context: core, nowMs: now.coreMilliseconds))
  }
}
