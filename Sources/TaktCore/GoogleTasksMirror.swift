import Foundation
import TaktRustCore

/// Reconciling Priority's lists with Google Tasks.
///
/// Priority is the authority, which is a narrower claim than "one-way sync".
/// Three things are true at once here, and the rules below are what it takes
/// to hold all three:
///
/// - **Priority wins a disagreement.** A title, a due date or a list name
///   edited on the Google side loses to the local one, and the mirror pushes
///   the local value back over it.
/// - **Ticking something off counts, wherever you tick it.** Completion is
///   not a disagreement — it is the same answer arriving by another route, so
///   a task completed in Google completes in Priority rather than being
///   un-completed on the next pass.
/// - **Nothing a person typed is thrown away.** Notes added on the Google side
///   where Priority had none are additions, not conflicts, and they are merged
///   back into the local task. A task created on the Google side is adopted
///   into the list it was created in.
///
/// Everything Priority does overwrite is recorded as a `Conflict`, so the one
/// case where the authority rule destroys something is the one case you can
/// go back and read.
///
/// Pure: the planner is handed a snapshot of both sides plus what was last
/// pushed, and returns operations for someone else to execute. Deciding what
/// to do is the part worth testing; doing it is HTTP.
public enum GoogleTasksMirror {

  // MARK: - What the two sides look like

  public struct LocalList: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public struct LocalTask: Equatable, Sendable {
    public let id: String
    public let listID: String
    public let parentID: String?
    public let title: String
    public let notes: String
    /// The day it is due, if any. Google Tasks keeps a day and discards a
    /// time, so this is already reduced to one.
    public let due: Date?
    public let isCompleted: Bool

    public init(
      id: String, listID: String, parentID: String? = nil, title: String, notes: String = "",
      due: Date? = nil, isCompleted: Bool = false
    ) {
      self.id = id
      self.listID = listID
      self.parentID = parentID
      self.title = title
      self.notes = notes
      self.due = due
      self.isCompleted = isCompleted
    }
  }

  public struct RemoteList: Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
      self.id = id
      self.title = title
    }
  }

  public struct RemoteTask: Equatable, Sendable {
    public let id: String
    public let listID: String
    public let parentID: String?
    public let title: String
    public let notes: String
    /// Google's own RFC3339 string, kept verbatim so a comparison against what
    /// was pushed is a comparison of the same thing.
    public let due: String?
    public let isCompleted: Bool
    /// Google marks a deleted task rather than dropping it from the feed, for
    /// a while. Either shape reaches the planner as "gone".
    public let isDeleted: Bool

    public init(
      id: String, listID: String, parentID: String? = nil, title: String, notes: String = "",
      due: String? = nil, isCompleted: Bool = false, isDeleted: Bool = false
    ) {
      self.id = id
      self.listID = listID
      self.parentID = parentID
      self.title = title
      self.notes = notes
      self.due = due
      self.isCompleted = isCompleted
      self.isDeleted = isDeleted
    }
  }

  // MARK: - What was last pushed

  /// What Priority sent to Google last time, per task.
  ///
  /// Without it there is no way to tell a remote edit from Priority's own echo
  /// coming back: both simply look like "the two sides differ". Comparing each
  /// side against what was pushed says which of them moved.
  public struct LedgerEntry: Codable, Equatable, Sendable {
    public let remoteID: String
    public let remoteListID: String
    public var pushedTitle: String
    public var pushedNotes: String
    public var pushedDue: String?
    public var pushedCompleted: Bool

    public init(
      remoteID: String, remoteListID: String, pushedTitle: String, pushedNotes: String,
      pushedDue: String?, pushedCompleted: Bool
    ) {
      self.remoteID = remoteID
      self.remoteListID = remoteListID
      self.pushedTitle = pushedTitle
      self.pushedNotes = pushedNotes
      self.pushedDue = pushedDue
      self.pushedCompleted = pushedCompleted
    }
  }

  public struct Ledger: Codable, Equatable, Sendable {
    /// Priority task id → what was pushed for it.
    public var tasks: [String: LedgerEntry]
    /// Priority list id → the Google list mirroring it.
    public var lists: [String: String]

    public static let empty = Ledger(tasks: [:], lists: [:])

    public init(tasks: [String: LedgerEntry] = [:], lists: [String: String] = [:]) {
      self.tasks = tasks
      self.lists = lists
    }
  }

  // MARK: - What to do about it

  public struct TaskPayload: Equatable, Sendable {
    public let title: String
    public let notes: String
    public let due: String?
    public let isCompleted: Bool
    /// The Google task this one hangs under, when the local parent is mirrored
    /// in the same list and is itself a top-level task.
    public let parentRemoteID: String?

    public init(
      title: String, notes: String, due: String?, isCompleted: Bool,
      parentRemoteID: String? = nil
    ) {
      self.title = title
      self.notes = notes
      self.due = due
      self.isCompleted = isCompleted
      self.parentRemoteID = parentRemoteID
    }
  }

  public enum Operation: Equatable, Sendable {
    case createList(localListID: String, title: String)
    /// A Google list the ledger has no record of, with the same title as a
    /// local one that has no Google copy. Most often the ledger file has been
    /// lost, and this is the mirror finding its own lists again rather than
    /// making a second set. Carried out as a ledger entry and nothing more.
    case adoptRemoteList(localListID: String, remoteListID: String)
    case renameList(remoteListID: String, title: String)
    /// A list archived or deleted in Priority. Its Google copy goes with it.
    case deleteList(remoteListID: String, localListID: String)
    case createTask(localID: String, remoteListID: String, payload: TaskPayload)
    case updateTask(localID: String, remoteID: String, remoteListID: String, payload: TaskPayload)
    case deleteTask(remoteID: String, remoteListID: String, localID: String)
    /// Ticked off in Google. Honoured rather than reverted.
    case completeLocalTask(localID: String)
    /// Notes written on the Google side where Priority had none, or appended
    /// to what Priority wrote. Kept.
    case mergeNotesIntoLocalTask(localID: String, notes: String)
    /// Typed straight into Google Tasks. It becomes a Priority task in the
    /// list that mirrors the one it appeared in.
    case adoptRemoteTask(remoteID: String, remoteListID: String, localListID: String, payload: TaskPayload)
  }

  /// What was overwritten. Hoisted out of `Conflict` rather than nested inside
  /// it because three levels of nesting is one more than this file earns.
  public enum ConflictField: String, Equatable, Sendable, Codable {
    case title
    case notes
    case due
    case existence
  }

  /// Something Priority overwrote because it had the final say.
  public struct Conflict: Equatable, Sendable, Codable {
    public let localID: String
    public let remoteID: String
    public let field: ConflictField
    public let localValue: String
    public let remoteValue: String

    public init(
      localID: String, remoteID: String, field: ConflictField, localValue: String,
      remoteValue: String
    ) {
      self.localID = localID
      self.remoteID = remoteID
      self.field = field
      self.localValue = localValue
      self.remoteValue = remoteValue
    }
  }

  public struct Plan: Equatable, Sendable {
    public let operations: [Operation]
    public let conflicts: [Conflict]

    public var isEmpty: Bool { operations.isEmpty && conflicts.isEmpty }

    public init(operations: [Operation], conflicts: [Conflict]) {
      self.operations = operations
      self.conflicts = conflicts
    }
  }

  // MARK: - Planning

  /// Works out what has to happen for the two sides to agree.
  ///
  /// `remoteTasks` and `remoteLists` are what Google currently holds;
  /// `ledger` is what Priority last pushed. A Google list the ledger does not
  /// map is left entirely alone unless a local list without a Google copy has
  /// exactly its title, in which case it is adopted as that list's copy — the
  /// mirror owns the lists it created and nothing else, and a title match is
  /// how it recognises one of its own after the ledger has been lost.
  ///
  /// The rules are the Rust core's (`core/src/google_tasks.rs`), called once
  /// per pass. Local due dates are reduced to Google's day string here, in
  /// `calendar`, before they cross; the ledger crosses sorted by local id, so
  /// lists and tasks gone from Priority are deleted in that order.
  public static func plan(
    localLists: [LocalList],
    localTasks: [LocalTask],
    remoteLists: [RemoteList],
    remoteTasks: [RemoteTask],
    ledger: Ledger,
    calendar: Calendar = .current
  ) -> Plan {
    let plan = googleTasksPlan(
      localLists: localLists.map { GoogleTasksLocalList(id: $0.id, name: $0.name) },
      localTasks: localTasks.map {
        GoogleTasksLocalTask(
          id: $0.id, listId: $0.listID, parentId: $0.parentID, title: $0.title, notes: $0.notes,
          due: $0.due.map { formatDueDate($0, calendar: calendar) }, isCompleted: $0.isCompleted)
      },
      remoteLists: remoteLists.map { GoogleTasksRemoteList(id: $0.id, title: $0.title) },
      remoteTasks: remoteTasks.map {
        GoogleTasksRemoteTask(
          id: $0.id, listId: $0.listID, parentId: $0.parentID, title: $0.title, notes: $0.notes,
          due: $0.due, isCompleted: $0.isCompleted, isDeleted: $0.isDeleted)
      },
      ledgerTasks: ledger.tasks.sorted { $0.key < $1.key }.map { localID, entry in
        GoogleTasksLedgerEntry(
          localId: localID, remoteId: entry.remoteID, remoteListId: entry.remoteListID,
          pushedTitle: entry.pushedTitle, pushedNotes: entry.pushedNotes,
          pushedDue: entry.pushedDue, pushedCompleted: entry.pushedCompleted)
      },
      ledgerLists: ledger.lists.sorted { $0.key < $1.key }.map {
        GoogleTasksListMapping(localListId: $0.key, remoteListId: $0.value)
      })
    return Plan(
      operations: plan.operations.map(Operation.init),
      conflicts: plan.conflicts.map(Conflict.init))
  }

  /// Reads Google's due string back as a day in the user's own calendar.
  ///
  /// The inverse of `formatDueDate`, and it has to be: Google's string is a
  /// *day* wearing an instant's clothes (midnight UTC). Parsing it as a real
  /// instant would put it on the previous evening for anyone west of
  /// Greenwich, and the next pass would then push that earlier day back to
  /// Google — a task adopted from a phone would walk backwards a day at a time.
  public static func parseDueDate(_ value: String, calendar: Calendar = .current) -> Date? {
    let digits = value.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard digits.count == 3 else { return nil }
    return calendar.date(
      from: DateComponents(year: digits[0], month: digits[1], day: digits[2], hour: 12))
  }

  /// Google Tasks stores a due day and discards any time sent with it, so the
  /// day is taken in the user's own calendar and sent as midnight UTC. Sending
  /// the real local timestamp would move a late-evening task to the next day
  /// for anyone east of Greenwich.
  public static func formatDueDate(_ date: Date, calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02dT00:00:00.000Z",
      components.year ?? 1970, components.month ?? 1, components.day ?? 1)
  }
}

// MARK: - From the core

extension GoogleTasksMirror.TaskPayload {
  init(_ core: GoogleTasksPayload) {
    self.init(
      title: core.title, notes: core.notes, due: core.due, isCompleted: core.isCompleted,
      parentRemoteID: core.parentRemoteId)
  }
}

extension GoogleTasksMirror.Operation {
  init(_ core: GoogleTasksOperation) {
    switch core {
    case .createList(let localListId, let title):
      self = .createList(localListID: localListId, title: title)
    case .adoptRemoteList(let localListId, let remoteListId):
      self = .adoptRemoteList(localListID: localListId, remoteListID: remoteListId)
    case .renameList(let remoteListId, let title):
      self = .renameList(remoteListID: remoteListId, title: title)
    case .deleteList(let remoteListId, let localListId):
      self = .deleteList(remoteListID: remoteListId, localListID: localListId)
    case .createTask(let localId, let remoteListId, let payload):
      self = .createTask(localID: localId, remoteListID: remoteListId, payload: .init(payload))
    case .updateTask(let localId, let remoteId, let remoteListId, let payload):
      self = .updateTask(
        localID: localId, remoteID: remoteId, remoteListID: remoteListId, payload: .init(payload))
    case .deleteTask(let remoteId, let remoteListId, let localId):
      self = .deleteTask(remoteID: remoteId, remoteListID: remoteListId, localID: localId)
    case .completeLocalTask(let localId):
      self = .completeLocalTask(localID: localId)
    case .mergeNotesIntoLocalTask(let localId, let notes):
      self = .mergeNotesIntoLocalTask(localID: localId, notes: notes)
    case .adoptRemoteTask(let remoteId, let remoteListId, let localListId, let payload):
      self = .adoptRemoteTask(
        remoteID: remoteId, remoteListID: remoteListId, localListID: localListId,
        payload: .init(payload))
    }
  }
}

extension GoogleTasksMirror.Conflict {
  init(_ core: GoogleTasksConflict) {
    let field: GoogleTasksMirror.ConflictField =
      switch core.field {
      case .title: .title
      case .notes: .notes
      case .due: .due
      case .existence: .existence
      }
    self.init(
      localID: core.localId, remoteID: core.remoteId, field: field, localValue: core.localValue,
      remoteValue: core.remoteValue)
  }
}
