import Foundation
import TaktCore

public enum TaskEditorField: String, Codable, CaseIterable, Sendable {
  case title, notes, dueAt, estimateMinutes, priority, tags, recurrenceRule, links, dailyProgress
  case startAt, dueDate, requirements, minimumBlock, singleSitting

  public var label: String {
    switch self {
    case .title: "Title"
    case .notes: "Notes"
    case .dueAt: "Due date"
    case .estimateMinutes: "Estimate"
    case .priority: "Priority"
    case .tags: "Tags"
    case .recurrenceRule: "Repeat"
    case .links: "Links"
    case .dailyProgress: "Daily progress"
    case .startAt: "Start"
    case .dueDate: "Due day"
    case .requirements: "Conditions"
    case .minimumBlock: "Minimum block"
    case .singleSitting: "One sitting"
    }
  }
}

/// Only editable values participate in conflict detection. Moving or completing
/// a task must not make an unrelated title edit stale.
public struct TaskEditorSnapshot: Codable, Equatable, Sendable {
  public let workspaceId: String
  public let taskId: String
  public var title: String
  public var notes: String
  public var dueAt: Date?
  public var estimateSeconds: Int?
  public var metadata: TaskEditorMetadata
  public var dailyProgress: Bool
  public var planning: TaskPlanning?

  public var values: TaskEditorValues {
    TaskEditorValues(
      title: title, notes: notes, dueAt: dueAt,
      estimateMinutes: estimateSeconds.map { $0 % 60 == 0 ? String($0 / 60) : String(Double($0) / 60) } ?? "",
      priority: metadata.priority ?? 0, tags: metadata.tags.joined(separator: ", "),
      recurrenceRule: metadata.recurrenceRule ?? "",
      links: metadata.externalLinks.joined(separator: "\n"), dailyProgress: dailyProgress,
      startAt: planning?.startAt, dueDate: planning?.dueDate, requirementGroups: planning?.requirementGroups,
      minimumBlockMinutes: planning?.minimumBlockSeconds.map { String(Double($0) / 60) },
      requiresSingleSitting: planning?.requiresSingleSitting)
  }
}

/// Raw text stays intact until Save, including temporarily invalid input.
public struct TaskEditorValues: Codable, Equatable, Sendable {
  public var title: String
  public var notes: String
  public var dueAt: Date?
  public var estimateMinutes: String
  public var priority: Int
  public var tags: String
  public var recurrenceRule: String
  public var links: String
  public var dailyProgress: Bool
  public var startAt: Date?
  public var dueDate: String?
  public var requirementGroups: [[String]]?
  public var minimumBlockMinutes: String?
  public var requiresSingleSitting: Bool?

  static func parseEstimate(_ raw: String) throws -> Int? {
    let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return nil }
    guard raw.range(of: "^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil,
      let minutes = Double(raw), minutes.isFinite, minutes >= 0 else { throw TaskEditorError.invalidEstimate }
    let seconds = (minutes * 60).rounded()
    guard seconds.isFinite, seconds < Double(Int.max) else { throw TaskEditorError.invalidEstimate }
    return Int(seconds)
  }

  public func matches(_ field: TaskEditorField, in other: Self) -> Bool {
    switch field {
    case .title: title == other.title
    case .notes: notes == other.notes
    case .dueAt: dueAt == other.dueAt
    case .estimateMinutes: estimateMinutes == other.estimateMinutes
    case .priority: priority == other.priority
    case .tags: tags == other.tags
    case .recurrenceRule: recurrenceRule == other.recurrenceRule
    case .links: links == other.links
    case .dailyProgress: dailyProgress == other.dailyProgress
    case .startAt: startAt == other.startAt
    case .dueDate: dueDate == other.dueDate
    case .requirements: requirementGroups == other.requirementGroups
    case .minimumBlock: minimumBlockMinutes == other.minimumBlockMinutes
    case .singleSitting: requiresSingleSitting == other.requiresSingleSitting
    }
  }

  public mutating func copy(_ field: TaskEditorField, from other: Self) {
    switch field {
    case .title: title = other.title
    case .notes: notes = other.notes
    case .dueAt: dueAt = other.dueAt
    case .estimateMinutes: estimateMinutes = other.estimateMinutes
    case .priority: priority = other.priority
    case .tags: tags = other.tags
    case .recurrenceRule: recurrenceRule = other.recurrenceRule
    case .links: links = other.links
    case .dailyProgress: dailyProgress = other.dailyProgress
    case .startAt: startAt = other.startAt
    case .dueDate: dueDate = other.dueDate
    case .requirements: requirementGroups = other.requirementGroups
    case .minimumBlock: minimumBlockMinutes = other.minimumBlockMinutes
    case .singleSitting: requiresSingleSitting = other.requiresSingleSitting
    }
  }
}

public struct TaskEditorDraft: Codable, Equatable, Sendable {
  public private(set) var baseline: TaskEditorSnapshot
  public var values: TaskEditorValues
  public private(set) var conflicts: Set<TaskEditorField> = []
  public var isUnavailable = false
  public var isDirty: Bool { values != baseline.values || !conflicts.isEmpty }

  public init(snapshot: TaskEditorSnapshot) {
    baseline = snapshot
    values = snapshot.values
  }

  public mutating func reconcile(with saved: TaskEditorSnapshot) {
    guard saved.workspaceId == baseline.workspaceId, saved.taskId == baseline.taskId else { return }
    let previous = baseline.values
    let current = saved.values
    for field in TaskEditorField.allCases {
      if values.matches(field, in: current) {
        conflicts.remove(field)
      } else if !values.matches(field, in: previous) || conflicts.contains(field) {
        if !current.matches(field, in: previous) { conflicts.insert(field) }
      } else {
        values.copy(field, from: current)
      }
      // Estimates displayed in minutes can have identical text but different
      // exact seconds. A dirty estimate still conflicts with that saved edit.
      if field == .estimateMinutes, !values.matches(field, in: previous),
        saved.estimateSeconds != baseline.estimateSeconds {
        let parsed = try? TaskEditorValues.parseEstimate(values.estimateMinutes)
        let converged = parsed == saved.estimateSeconds
          && (values.estimateMinutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsed != nil)
        if converged { conflicts.remove(field) } else { conflicts.insert(field) }
      }
    }
    baseline = saved
    isUnavailable = false
  }

  public mutating func resolve(_ field: TaskEditorField, useSaved: Bool) {
    if useSaved { values.copy(field, from: baseline.values) }
    conflicts.remove(field)
  }

  public func validatedSnapshot() throws -> TaskEditorSnapshot {
    guard !isUnavailable else { throw WorkspaceStoreError.missingTask }
    guard conflicts.isEmpty else { throw TaskEditorError.conflictingChanges }
    var result = baseline
    result.title = try WorkspaceStore.nonEmptyName(values.title)
    result.notes = values.notes
    result.dueAt = values.dueAt
    if values.estimateMinutes != baseline.values.estimateMinutes {
      result.estimateSeconds = try TaskEditorValues.parseEstimate(values.estimateMinutes)
    }
    guard (0...4).contains(values.priority) else { throw TaskEditorError.invalidPriority }
    result.metadata.priority = values.priority == 0 ? nil : values.priority
    if values.tags != baseline.values.tags {
      result.metadata.tags = WorkspaceStore.normalizedStrings(values.tags.components(separatedBy: ","))
    }
    if values.recurrenceRule != baseline.values.recurrenceRule {
      let recurrence = values.recurrenceRule.trimmingCharacters(in: .whitespacesAndNewlines)
      result.metadata.recurrenceRule = recurrence.isEmpty ? nil : recurrence
    }
    if values.links != baseline.values.links {
      result.metadata.externalLinks = WorkspaceStore.normalizedStrings(values.links.components(separatedBy: .newlines))
    }
    result.dailyProgress = values.dailyProgress
    result.planning = TaskPlanning(startAt: values.startAt, dueDate: values.dueDate,
      requirementGroups: values.requirementGroups,
      minimumBlockSeconds: values.minimumBlockMinutes != baseline.values.minimumBlockMinutes
        ? try TaskEditorValues.parseEstimate(values.minimumBlockMinutes ?? "") : baseline.planning?.minimumBlockSeconds,
      requiresSingleSitting: values.requiresSingleSitting).normalized
    if values.dueDate != nil { result.dueAt = nil }
    return result
  }
}

public enum TaskEditorError: LocalizedError, Equatable {
  case invalidEstimate, invalidPriority, conflictingChanges, invalidVisibleRoot

  public var errorDescription: String? {
    switch self {
    case .invalidEstimate: "Enter a non-negative number of minutes within the supported range."
    case .invalidPriority: "Choose a priority between None and Urgent."
    case .conflictingChanges: "Saved values have changed. Review the conflicting fields before saving."
    case .invalidVisibleRoot: "Choose the list's only imported top-level task, with children, as its visible root."
    }
  }
}
