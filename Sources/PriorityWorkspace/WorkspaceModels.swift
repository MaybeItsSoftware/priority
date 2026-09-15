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
  public var parentFolderId: String?
  public var name: String
  public var sortOrder: Int
  public let createdAt: Date
  public var updatedAt: Date
}

public struct TaskList: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "task_lists"

  public let id: String
  public let workspaceId: String
  public var folderId: String?
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
  public var listId: String
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

public struct TaskMetadata: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
  public static let databaseTableName = "task_metadata"

  public let taskId: String
  public var priority: Int?
  public var startAt: Date?
  public var tagsJSON: String
  public var recurrenceRule: String?
  public var matrixUrgency: Int?
  public var matrixImportance: Int?
  public var kanbanColumn: String?
  public var externalLinksJSON: String
  public var updatedAt: Date

  public init(
    taskId: String,
    priority: Int?,
    startAt: Date?,
    tagsJSON: String,
    recurrenceRule: String?,
    matrixUrgency: Int?,
    matrixImportance: Int?,
    kanbanColumn: String?,
    externalLinksJSON: String,
    updatedAt: Date
  ) {
    self.taskId = taskId
    self.priority = priority
    self.startAt = startAt
    self.tagsJSON = tagsJSON
    self.recurrenceRule = recurrenceRule
    self.matrixUrgency = matrixUrgency
    self.matrixImportance = matrixImportance
    self.kanbanColumn = kanbanColumn
    self.externalLinksJSON = externalLinksJSON
    self.updatedAt = updatedAt
  }
}

public struct TaskEditorMetadata: Sendable, Equatable {
  public var priority: Int?
  public var tags: [String]
  public var recurrenceRule: String?
  public var externalLinks: [String]

  public init(priority: Int? = nil, tags: [String] = [], recurrenceRule: String? = nil, externalLinks: [String] = []) {
    self.priority = priority
    self.tags = tags
    self.recurrenceRule = recurrenceRule
    self.externalLinks = externalLinks
  }
}

/// A local board is scoped to a list or to one project's immediate children.
/// The task's column is deliberately independent of its parent's column: a
/// project can be in “In progress” while its next section is in “Today”.
public struct WorkspaceKanbanColumn: Codable, Identifiable, Sendable, Equatable {
  public let id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }

  public static let blitzitDefaults = [
    WorkspaceKanbanColumn(id: "backlog", title: "Backlog"),
    WorkspaceKanbanColumn(id: "in-progress", title: "In progress"),
    WorkspaceKanbanColumn(id: "this-week", title: "This week"),
    WorkspaceKanbanColumn(id: "waiting-on", title: "Waiting on"),
    WorkspaceKanbanColumn(id: "today", title: "Today"),
  ]
}

public struct TaskMatrixPosition: Sendable, Equatable {
  public let urgency: Int?
  public let importance: Int?

  public init(urgency: Int?, importance: Int?) {
    self.urgency = urgency
    self.importance = importance
  }
}

public enum FocusSessionPhase: String, Codable, Sendable, CaseIterable {
  case running
  case onBreak
  case finished
}

public struct FocusSession: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "focus_sessions"

  public let id: String
  public let startedAt: Date
  public var endedAt: Date?
  public var phase: FocusSessionPhase
  public var activeTaskId: String?
  public let workDurationSeconds: Int
  public let breakDurationSeconds: Int
  public var breakEndsAt: Date?
}

public enum FocusQueueState: String, Codable, Sendable, CaseIterable {
  case queued
  case completed
  case skipped
}

public struct FocusQueueItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "focus_queue_items"

  public let id: String
  public let sessionId: String
  public let taskId: String
  public var sortOrder: Int
  public var state: FocusQueueState
  /// What you committed to when you started this sitting, as distinct from the
  /// task's standing estimate. Nil when the queue item was added without one.
  public var plannedSeconds: Int?
  public var completedAt: Date?
  public var skippedAt: Date?
  public let createdAt: Date
}

public struct FocusQueueTask: Identifiable, Sendable, Equatable {
  public let item: FocusQueueItem
  public let task: WorkspaceTask

  public var id: String { item.id }
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

/// A standing commitment to move one task forward today.
///
/// Every daily points at a task. Ticking one does *not* complete the task — it
/// records a contribution against it, so "write 500 words" can be done daily
/// while "draft chapter three" stays open until it is genuinely finished. That
/// is the whole difference from a recurring task, which has to be completed and
/// respawned and therefore can't represent partial progress at all.
///
/// The schedule mirrors the legacy `Daily`: fixed weekdays, or a rotating
/// interval, never both. `intervalDays` wins when set.
public struct WorkspaceDaily: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "dailies"

  public let id: String
  public var taskId: String
  /// `Calendar` weekday numbering (1 = Sunday) as a bitmask, bit `n - 1` per
  /// weekday. A set stored as JSON would need decoding before SQL could filter
  /// on it, and the schedule is read on every launch.
  public var activeWeekdaysMask: Int
  public var intervalDays: Int?
  public var intervalAnchor: Date?
  /// How much of the task you mean to do on a day this lands — the estimate the
  /// focus screen offers first. Nil simply means "some".
  public var targetSeconds: Int?
  public var sortOrder: Int
  /// Archived rather than deleted, so past contributions keep a parent.
  public var archivedAt: Date?
  /// Set only on dailies carried over from the plugin-era store.
  public var legacyDailyId: String?
  public let createdAt: Date
  public var updatedAt: Date

  public static let allWeekdaysMask = 0b111_1111

  public init(
    id: String,
    taskId: String,
    activeWeekdaysMask: Int = WorkspaceDaily.allWeekdaysMask,
    intervalDays: Int? = nil,
    intervalAnchor: Date? = nil,
    targetSeconds: Int? = nil,
    sortOrder: Int,
    archivedAt: Date? = nil,
    legacyDailyId: String? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.taskId = taskId
    self.activeWeekdaysMask = activeWeekdaysMask == 0 ? WorkspaceDaily.allWeekdaysMask : activeWeekdaysMask
    self.intervalDays = intervalDays.map { min(366, max(1, $0)) }
    self.intervalAnchor = intervalAnchor
    self.targetSeconds = targetSeconds
    self.sortOrder = sortOrder
    self.archivedAt = archivedAt
    self.legacyDailyId = legacyDailyId
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var isArchived: Bool { archivedAt != nil }

  public static func mask(forWeekdays weekdays: Set<Int>) -> Int {
    weekdays.reduce(0) { $0 | (1 << ($1 - 1)) }
  }

  public var activeWeekdays: Set<Int> {
    Set((1...7).filter { activeWeekdaysMask & (1 << ($0 - 1)) != 0 })
  }

  /// Whether this daily is expected on `day`.
  public func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
    guard !isArchived else { return false }
    if let interval = intervalDays, interval > 0 {
      let anchor = calendar.startOfDay(for: intervalAnchor ?? createdAt)
      let target = calendar.startOfDay(for: day)
      guard target >= anchor else { return false }
      let elapsed = calendar.dateComponents([.day], from: anchor, to: target).day ?? 0
      return elapsed % interval == 0
    }
    return activeWeekdaysMask & (1 << (calendar.component(.weekday, from: day) - 1)) != 0
  }
}

/// One day's worth of progress against a daily's task.
///
/// Keyed by day rather than timestamped, because the question a daily answers
/// is "did I do this today", and a row per day makes that a lookup instead of a
/// range scan. `secondsLogged` accumulates across several focus sessions on the
/// same day.
public struct DailyContribution: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
  public static let databaseTableName = "daily_contributions"

  public let id: String
  public let dailyId: String
  public let taskId: String
  /// `yyyy-MM-dd` in the user's calendar, produced by `DailyContribution.dayKey`.
  public let dayKey: String
  public var secondsLogged: Int
  public var completedAt: Date?
  public let createdAt: Date

  public var isComplete: Bool { completedAt != nil }

  private static let dayKeyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
    let formatter = dayKeyFormatter
    formatter.timeZone = calendar.timeZone
    return formatter.string(from: date)
  }
}

/// A daily joined to its task and to today's contribution, which is what every
/// caller actually wants — the daily alone can't render a row.
public struct DailyItem: Identifiable, Sendable, Equatable {
  public let daily: WorkspaceDaily
  public let task: WorkspaceTask
  public let contribution: DailyContribution?

  public var id: String { daily.id }
  public var isDoneToday: Bool { contribution?.isComplete ?? false }
  public var secondsLoggedToday: Int { contribution?.secondsLogged ?? 0 }

  public init(daily: WorkspaceDaily, task: WorkspaceTask, contribution: DailyContribution?) {
    self.daily = daily
    self.task = task
    self.contribution = contribution
  }
}

/// A plugin-era daily on its way into the workspace. Mirrors `PriorityCore.Daily`
/// without making this module depend on how that file happens to be shaped.
public struct LegacyDailySeed: Sendable, Equatable {
  public let id: String
  public let title: String
  public let activeWeekdays: Set<Int>
  public let intervalDays: Int?
  public let intervalAnchor: Date?
  public let targetSeconds: Int?
  public let archivedAt: Date?
  public let createdAt: Date

  public init(
    id: String,
    title: String,
    activeWeekdays: Set<Int> = Set(1...7),
    intervalDays: Int? = nil,
    intervalAnchor: Date? = nil,
    targetSeconds: Int? = nil,
    archivedAt: Date? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.activeWeekdays = activeWeekdays
    self.intervalDays = intervalDays
    self.intervalAnchor = intervalAnchor
    self.targetSeconds = targetSeconds
    self.archivedAt = archivedAt
    self.createdAt = createdAt
  }
}
