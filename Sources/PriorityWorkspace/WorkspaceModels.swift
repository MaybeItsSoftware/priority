import Foundation
import GRDB

public struct Workspace: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "workspaces"

  public let id: String
  public var name: String
  public let createdAt: Date
  public var updatedAt: Date
}

public struct ListFolder: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "list_folders"

  public let id: String
  public let workspaceId: String
  public let parentFolderId: String?
  public var name: String
  public var sortOrder: Int
  public let createdAt: Date
  public var updatedAt: Date
}

public struct TaskList: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "task_lists"

  public let id: String
  public let workspaceId: String
  public let folderId: String?
  public var name: String
  public var colorHex: String?
  public var sortOrder: Int
  public var isArchived: Bool
  public let createdAt: Date
  public var updatedAt: Date
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
  case open
  case completed
  case cancelled
}

public struct WorkspaceTask: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "tasks"

  public let id: String
  public let listId: String
  public var parentTaskId: String?
  public var title: String
  public var notes: String
  public var status: TaskStatus
  public var sortOrder: Int
  public var dueAt: Date?
  public var estimateSeconds: Int?
  public let createdAt: Date
  public var updatedAt: Date
}

public struct TaskOutlineItem: Identifiable, Sendable, Equatable {
  public let task: WorkspaceTask
  public let depth: Int

  public var id: String { task.id }

  public init(task: WorkspaceTask, depth: Int) {
    self.task = task
    self.depth = depth
  }
}

/// A source task copied into the first local workspace. Its source ID is used
/// only to rebuild the hierarchy during this one transaction; local records
/// receive new UUID identities.
public struct LegacyTaskSeed: Sendable, Equatable {
  public let sourceId: String
  public let parentSourceId: String?
  public let title: String
  public let notes: String
  public let status: TaskStatus
  public let sortOrder: Int

  public init(
    sourceId: String,
    parentSourceId: String?,
    title: String,
    notes: String = "",
    status: TaskStatus,
    sortOrder: Int
  ) {
    self.sourceId = sourceId
    self.parentSourceId = parentSourceId
    self.title = title
    self.notes = notes
    self.status = status
    self.sortOrder = sortOrder
  }
}
