import Foundation

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
  /// `ledger` is what Priority last pushed. A list Priority knows nothing
  /// about is left entirely alone — the mirror owns the lists it created and
  /// nothing else, so an unrelated Google Tasks list is never touched.
  public static func plan(
    localLists: [LocalList],
    localTasks: [LocalTask],
    remoteLists: [RemoteList],
    remoteTasks: [RemoteTask],
    ledger: Ledger,
    calendar: Calendar = .current
  ) -> Plan {
    var operations: [Operation] = []
    var conflicts: [Conflict] = []

    let remoteListsByID = Dictionary(remoteLists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let localListsByID = Dictionary(localLists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    // --- Lists -------------------------------------------------------------
    // A mapped list whose Google copy has been deleted is remapped by being
    // created again: Priority says which lists exist.
    var listMapping: [String: String] = [:]
    for list in localLists {
      guard let remoteListID = ledger.lists[list.id], remoteListsByID[remoteListID] != nil else {
        operations.append(.createList(localListID: list.id, title: list.name))
        continue
      }
      listMapping[list.id] = remoteListID
      if remoteListsByID[remoteListID]?.title != list.name {
        operations.append(.renameList(remoteListID: remoteListID, title: list.name))
      }
    }
    // Mapped to a list Priority no longer has: archived, deleted, or renamed
    // into nothing. The Google copy follows it.
    for (localListID, remoteListID) in ledger.lists
    where localListsByID[localListID] == nil && remoteListsByID[remoteListID] != nil {
      operations.append(.deleteList(remoteListID: remoteListID, localListID: localListID))
    }

    // --- Tasks -------------------------------------------------------------
    let remoteTasksByID = Dictionary(remoteTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let localTasksByID = Dictionary(localTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let parentRemoteIDs = parentMapping(localTasks: localTasks, localTasksByID: localTasksByID, ledger: ledger)

    for task in localTasks {
      let due = task.due.map { formatDueDate($0, calendar: calendar) }
      // A task in a list that has no Google copy yet waits for the next pass,
      // once creating the list has handed back an id.
      guard let remoteListID = listMapping[task.listID] else { continue }

      guard let entry = ledger.tasks[task.id] else {
        // Completed before it was ever mirrored: nothing to put on a phone.
        if task.isCompleted { continue }
        operations.append(
          .createTask(
            localID: task.id, remoteListID: remoteListID,
            payload: TaskPayload(
              title: task.title, notes: task.notes, due: due, isCompleted: false,
              parentRemoteID: parentRemoteIDs[task.id])))
        continue
      }

      let local = TaskPayload(
        title: task.title, notes: task.notes, due: due, isCompleted: task.isCompleted,
        parentRemoteID: parentRemoteIDs[task.id])

      guard let remote = remoteTasksByID[entry.remoteID], !remote.isDeleted else {
        // Deleted on the Google side. Priority still has it, so Priority is
        // right — it comes back, and the deletion is recorded as overwritten.
        if !task.isCompleted {
          operations.append(
            .createTask(localID: task.id, remoteListID: remoteListID, payload: local))
          conflicts.append(
            Conflict(
              localID: task.id, remoteID: entry.remoteID, field: .existence,
              localValue: task.title, remoteValue: "deleted in Google Tasks"))
        }
        continue
      }

      // Completion is not a disagreement: whoever ticked it off, it is done.
      if remote.isCompleted && !task.isCompleted && !entry.pushedCompleted {
        operations.append(.completeLocalTask(localID: task.id))
        continue
      }

      var wantsPush = false

      // Notes added on the Google side are an addition, not an edit, as long
      // as Priority has not written anything new of its own to disagree with.
      if remote.notes != entry.pushedNotes {
        let localUnchanged = task.notes == entry.pushedNotes
        if localUnchanged && isAdditive(remote.notes, to: entry.pushedNotes) {
          operations.append(.mergeNotesIntoLocalTask(localID: task.id, notes: remote.notes))
          continue
        }
        conflicts.append(
          Conflict(
            localID: task.id, remoteID: remote.id, field: .notes,
            localValue: task.notes, remoteValue: remote.notes))
        wantsPush = true
      }

      if remote.title != entry.pushedTitle {
        conflicts.append(
          Conflict(
            localID: task.id, remoteID: remote.id, field: .title,
            localValue: task.title, remoteValue: remote.title))
        wantsPush = true
      }

      if remote.due != entry.pushedDue {
        conflicts.append(
          Conflict(
            localID: task.id, remoteID: remote.id, field: .due,
            localValue: due ?? "none", remoteValue: remote.due ?? "none"))
        wantsPush = true
      }

      // Priority moved: push it. This covers the ordinary case as well as the
      // reverting half of a conflict, which is the same write either way.
      if local.title != entry.pushedTitle || local.notes != entry.pushedNotes
        || local.due != entry.pushedDue || local.isCompleted != entry.pushedCompleted
      {
        wantsPush = true
      }
      // The remote copy drifted from what Priority believes it pushed, even
      // if Priority itself has not changed. Put it back.
      if remote.title != local.title || remote.notes != local.notes || remote.due != local.due {
        wantsPush = true
      }

      if wantsPush {
        operations.append(
          .updateTask(
            localID: task.id, remoteID: remote.id, remoteListID: entry.remoteListID,
            payload: local))
      }
    }

    // Mirrored once, gone from Priority now: delete the Google copy.
    for (localID, entry) in ledger.tasks where localTasksByID[localID] == nil {
      guard let remote = remoteTasksByID[entry.remoteID], !remote.isDeleted else { continue }
      operations.append(
        .deleteTask(remoteID: entry.remoteID, remoteListID: entry.remoteListID, localID: localID))
    }

    // Typed into Google Tasks directly: adopted rather than deleted, because
    // authority decides who wins an argument, not who is allowed to write.
    let mirroredRemoteIDs = Set(ledger.tasks.values.map(\.remoteID))
    let localListIDsByRemoteListID = Dictionary(
      listMapping.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
    for remote in remoteTasks
    where !remote.isDeleted && !remote.isCompleted && !mirroredRemoteIDs.contains(remote.id) {
      guard let localListID = localListIDsByRemoteListID[remote.listID] else { continue }
      operations.append(
        .adoptRemoteTask(
          remoteID: remote.id, remoteListID: remote.listID, localListID: localListID,
          payload: TaskPayload(
            title: remote.title, notes: remote.notes, due: remote.due, isCompleted: false)))
    }

    return Plan(operations: operations, conflicts: conflicts)
  }

  // MARK: - Helpers

  /// Google Tasks nests exactly one level. Priority's trees are as deep as you
  /// like, so a task whose parent is itself a child is mirrored at the top
  /// level rather than silently vanishing into a nesting Google will refuse.
  private static func parentMapping(
    localTasks: [LocalTask],
    localTasksByID: [String: LocalTask],
    ledger: Ledger
  ) -> [String: String] {
    var mapping: [String: String] = [:]
    for task in localTasks {
      guard let parentID = task.parentID, let parent = localTasksByID[parentID] else { continue }
      // A grandchild: its parent already occupies the one level Google allows.
      if parent.parentID != nil, localTasksByID[parent.parentID!] != nil { continue }
      guard parent.listID == task.listID, let parentEntry = ledger.tasks[parentID] else { continue }
      mapping[task.id] = parentEntry.remoteID
    }
    return mapping
  }

  /// Whether one piece of text only *adds* to another: same start, more after
  /// it. Anything else is a rewrite, and a rewrite is a disagreement.
  static func isAdditive(_ candidate: String, to original: String) -> Bool {
    if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return candidate.hasPrefix(original) && candidate.count > original.count
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
