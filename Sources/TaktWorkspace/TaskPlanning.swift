import Foundation
import TaktCore

public struct TaskCondition: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let workspaceId: String
  public var name: String
  public var isLocation: Bool
  public var isArchived: Bool
  public let createdAt: Date
  public var updatedAt: Date
}

/// Stored alongside metadata so complete planning edits share one undo step.
/// References are stable catalogue IDs; all groups match, any member may match.
public struct TaskPlanning: Codable, Equatable, Sendable {
  public var startAt: Date?
  public var dueDate: String?
  public var requirementGroups: [[String]]?
  public var minimumBlockSeconds: Int?
  public var requiresSingleSitting: Bool?

  public init(startAt: Date? = nil, dueDate: String? = nil, requirementGroups: [[String]]? = nil,
              minimumBlockSeconds: Int? = nil, requiresSingleSitting: Bool? = nil) {
    self.startAt = startAt; self.dueDate = dueDate; self.requirementGroups = requirementGroups
    self.minimumBlockSeconds = minimumBlockSeconds; self.requiresSingleSitting = requiresSingleSitting
  }

  public var normalized: TaskPlanning? {
    var result = self
    if result.requirementGroups?.isEmpty == true { result.requirementGroups = nil }
    if result.requiresSingleSitting == false { result.requiresSingleSitting = nil }
    return result == TaskPlanning() ? nil : result
  }
}

public struct FocusWorkBlock: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public let sessionId: String?
  public let taskId: String?
  public let taskTitle: String
  public let seconds: Int
  public let recordedAt: Date
  public var originalTaskId: String?
}

public enum TaskPlanningError: LocalizedError {
  case invalidCondition, invalidSchedule, invalidMinimum, estimateRequired, invalidDate, unavailable
  public var errorDescription: String? {
    switch self {
    case .invalidCondition: "A required condition is missing, archived or belongs to another workspace."
    case .invalidSchedule: "Start must be before the deadline."
    case .invalidMinimum: "Enter a minimum useful block of at least one minute."
    case .estimateRequired: "One-sitting tasks need a positive estimate at least as long as their minimum block."
    case .invalidDate: "Choose a valid calendar date."
    case .unavailable: "This task or planned block is no longer available in the current conditions and time window."
    }
  }
}
