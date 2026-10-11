import Foundation
import TaktRustCore

/// Filter lists: saved, named rule sets evaluated over every task. Which
/// tasks a definition shows is the Rust core's (core/src/filter_lists.rs), so
/// the Mac, the phones and the CLI agree; this file only carries its values
/// across and turns its rows into models.

/// One condition of a filter list: a field compared by an operator with a
/// value (empty when the operator takes none). The vocabulary is
/// `WorkspaceFilterCatalog`.
public struct WorkspaceFilterRule: Hashable, Sendable, Identifiable {
  public var id = UUID()
  public var field: String
  public var op: String
  public var value: String

  public init(field: String, op: String, value: String = "") {
    self.field = field
    self.op = op
    self.value = value
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.field == rhs.field && lhs.op == rhs.op && lhs.value == rhs.value
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(field)
    hasher.combine(op)
    hasher.combine(value)
  }
}

/// What a filter list shows: tasks of a status, every rule holding or any.
public struct WorkspaceFilterDefinition: Hashable, Sendable {
  public enum Match: String, CaseIterable, Sendable { case all, any }
  public enum Show: String, CaseIterable, Sendable { case open, done, all }

  public var match: Match
  public var show: Show
  public var rules: [WorkspaceFilterRule]

  public init(match: Match = .all, show: Show = .open, rules: [WorkspaceFilterRule] = []) {
    self.match = match
    self.show = show
    self.rules = rules
  }

  init(_ core: FilterDefinition) {
    match = Match(rawValue: core.matchMode) ?? .all
    show = Show(rawValue: core.show) ?? .open
    rules = core.rules.map { WorkspaceFilterRule(field: $0.field, op: $0.op, value: $0.value) }
  }

  var core: FilterDefinition {
    FilterDefinition(
      matchMode: match.rawValue, show: show.rawValue,
      rules: rules.map { FilterRule(field: $0.field, op: $0.op, value: $0.value) })
  }

  /// A one-line reading: "Open tasks where tag has work and due date is
  /// within 7 days".
  public var summary: String { describeFilterDefinition(definition: core) }

  /// The definition tidied as it would be saved, or the reason it cannot be.
  public func validated() throws -> WorkspaceFilterDefinition {
    try WorkspaceStore.mappingCoreErrors { WorkspaceFilterDefinition(try validateFilterDefinition(definition: core)) }
  }

  /// The definition as `filter_lists.rulesJSON` stores it.
  public var json: String { filterDefinitionJson(definition: core) }

  public init(json: String) throws {
    self.init(try WorkspaceStore.mappingCoreErrors { try parseFilterDefinition(json: json) })
  }
}

/// A saved filter list, or Today or Everything as the definitions they are.
public struct WorkspaceFilterList: Hashable, Sendable, Identifiable {
  public static let todayID = "builtin:today"
  public static let everythingID = "builtin:everything"

  public var id: String
  public var workspaceId: String
  public var name: String
  /// An SF Symbol name; nil draws the default.
  public var icon: String?
  public var colorHex: String?
  public var definition: WorkspaceFilterDefinition
  public var sortOrder: Int
  public var isBuiltin: Bool
  public var createdAt: Date
  public var updatedAt: Date

  /// The symbol drawn when the list names none.
  public static let defaultIcon = "line.3.horizontal.decrease.circle"

  init(_ row: FilterListRow) {
    id = row.id
    workspaceId = row.workspaceId
    name = row.name
    icon = row.icon
    colorHex = row.colorHex
    definition = WorkspaceFilterDefinition(row.definition)
    sortOrder = Int(row.sortOrder)
    isBuiltin = row.isBuiltin
    createdAt = Date(timeIntervalSince1970: TimeInterval(row.createdAtMs) / 1000)
    updatedAt = Date(timeIntervalSince1970: TimeInterval(row.updatedAtMs) / 1000)
  }

  /// Today and Everything, as the core defines them.
  public static var builtins: [WorkspaceFilterList] { builtinFilterLists().map(WorkspaceFilterList.init) }
}

/// The fields a rule can test and their operators, in the order an editor
/// offers them.
public enum WorkspaceFilterCatalog {
  public struct Operator: Hashable, Sendable {
    public var op: String
    public var label: String
    /// "none", "text", "tag", "number", "days", "minutes", "date", "lists",
    /// "folder" or "column".
    public var valueKind: String
  }

  public struct Field: Hashable, Sendable, Identifiable {
    public var field: String
    public var label: String
    public var ops: [Operator]
    public var id: String { field }
  }

  public static let fields: [Field] = filterRuleCatalog().map { spec in
    Field(
      field: spec.field, label: spec.label,
      ops: spec.ops.map { Operator(op: $0.op, label: $0.label, valueKind: $0.valueKind) })
  }

  public static func field(_ name: String) -> Field? { fields.first { $0.field == name } }

  public static func op(_ op: String, of field: String) -> Operator? {
    self.field(field)?.ops.first { $0.op == op }
  }
}

extension WorkspaceStore {

  // MARK: - Reading

  /// The workspace's own filter lists, in sidebar order.
  public func filterLists(in workspaceId: String) throws -> [WorkspaceFilterList] {
    try Self.mappingCoreErrors { try core.filterLists(workspaceId: workspaceId) }.map(WorkspaceFilterList.init)
  }

  /// One filter list, stored or built in.
  public func filterList(id: String) throws -> WorkspaceFilterList? {
    try Self.mappingCoreErrors { try core.filterList(id: id) }.map(WorkspaceFilterList.init)
  }

  /// The tasks `definition` shows across the workspace, list by list in
  /// outline order.
  public func filterListTasks(
    _ definition: WorkspaceFilterDefinition, in workspaceId: String, now: Date = .now,
    timeZone: TimeZone = .current
  ) throws -> [WorkspaceTask] {
    try Self.mappingCoreErrors {
      try core.filterListTasks(
        workspaceId: workspaceId, definition: definition.core, nowMs: now.coreMilliseconds,
        zone: timeZone.identifier)
    }.map(WorkspaceTask.init)
  }

  /// A filter list's board over `listIds`, read like `combinedBoard`: its
  /// cards are the tasks the list shows.
  func filterListBoard(
    id: String, listIds: [String], hidingCompletedBefore cutoff: Date?, using handle: CoreWorkspace
  ) throws -> WorkspaceBoardRead {
    guard !listIds.isEmpty,
      let row = try Self.mappingCoreErrors({ try handle.filterList(id: id) })
    else { return .empty }
    let cutoffMs = cutoff.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }
    return try boardRead(
      Self.mappingCoreErrors {
        try handle.filterListBoard(
          definition: row.definition, listIds: listIds, hideCompletedBeforeMs: cutoffMs,
          nowMs: Date().coreMilliseconds, zone: TimeZone.current.identifier)
      })
  }

  // MARK: - Writing

  /// Creates a filter list at the end of the workspace's, as one "New Filter
  /// List" undo step. Throws `WorkspaceStoreError.invalidFilter` with the
  /// reason when a rule cannot be saved.
  @discardableResult
  public func createFilterList(
    in workspaceId: String, name: String, icon: String?, colorHex: String? = nil,
    definition: WorkspaceFilterDefinition, now: Date = .now
  ) throws -> WorkspaceFilterList {
    WorkspaceFilterList(
      try coreWrite {
        try core.createFilterList(
          workspaceId: workspaceId, name: name, icon: icon, colorHex: colorHex, definition: definition.core,
          nowMs: now.coreMilliseconds)
      })
  }

  /// Saves a filter list's name, icon, colour and rules, as one "Edit Filter
  /// List" undo step.
  @discardableResult
  public func updateFilterList(
    _ id: String, name: String, icon: String?, colorHex: String? = nil, definition: WorkspaceFilterDefinition,
    now: Date = .now
  ) throws -> WorkspaceFilterList {
    WorkspaceFilterList(
      try coreWrite {
        try core.updateFilterList(
          id: id, name: name, icon: icon, colorHex: colorHex, definition: definition.core,
          nowMs: now.coreMilliseconds)
      })
  }

  /// Renames a filter list, as one "Rename Filter List" undo step.
  public func renameFilterList(_ id: String, to name: String, now: Date = .now) throws {
    try coreWrite { try core.renameFilterList(id: id, name: name, nowMs: now.coreMilliseconds) }
  }

  /// Deletes a filter list, as one "Delete Filter List" undo step. No task
  /// is touched: a filter list holds none.
  public func deleteFilterList(_ id: String) throws {
    try coreWrite { try core.deleteFilterList(id: id) }
  }

  /// Moves a filter list to `index` among the workspace's.
  public func moveFilterList(_ id: String, to index: Int, now: Date = .now) throws {
    try coreWrite { try core.moveFilterList(id: id, index: UInt32(max(0, index)), nowMs: now.coreMilliseconds) }
  }
}
