import Foundation
import Observation
import TaktCore
import TaktWorkspace
import os

/// Drives the Google Tasks mirror.
///
/// Reads both sides, asks `GoogleTasksMirror` what should happen, and carries
/// it out — against Google through the plugin, against the workspace through
/// the store. Two orderings matter and are the things worth knowing about
/// this file. Lists are created before the tasks that go in them, because the
/// ids Google hands back are what the task operations need. And the ledger is
/// saved whether or not the pass finishes: every Google write lands in the
/// in-memory ledger as it happens, and a pass that dies halfway saves what it
/// has before reporting the error, so the next pass finds the tasks it already
/// created rather than creating them again and adopting the orphans back.
///
/// A pass is never concurrent with itself. Google Tasks has no transactions,
/// and two passes racing would each see the other's half-finished work as
/// remote edits to argue with. A change that arrives mid-pass is not dropped,
/// though: the running pass has already read its snapshot, so the flag it
/// sets makes the loop in `sync()` go round once more.
@MainActor
@Observable final class GoogleTasksMirrorService {
  enum State: Equatable {
    case idle
    case syncing
    case failed(String)
  }

  private(set) var state: State = .idle
  private(set) var lastSyncedAt: Date?
  private(set) var mirroredTaskCount = 0
  private(set) var recentConflicts: [GoogleTasksConflictRecord] = []

  /// How long after a local change the mirror waits before pushing. Long
  /// enough that typing a title is one push rather than twelve.
  private static let debounce: Duration = .seconds(4)
  /// How often a pass runs with nothing prompting it, to notice things ticked
  /// off on a phone. Google Tasks has no push channel to subscribe to.
  private static let pollInterval: Duration = .seconds(300)

  private let plugin: any GoogleTasksIntegrationPlugin
  private let ledgerStore: GoogleTasksMirrorLedgerStore
  private let conflictLog: GoogleTasksConflictLog
  private let storeProvider: () -> WorkspaceStore?
  private let isEnabled: () -> Bool
  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "GoogleTasksMirrorService")

  /// Called on the main actor after a pass has written to the workspace — a
  /// completion ticked on a phone, notes merged in, a task adopted. The view
  /// model's external-write poller deliberately ignores this process's own
  /// commits, so without this a phone tick would not show until the next
  /// local edit happened to reload the screen.
  var onWroteLocally: (() -> Void)?

  private var pendingSync: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var isRunning = false
  /// Set when a change arrives mid-pass. The pass that is running has already
  /// read its snapshot, so the change needs one of its own rather than being
  /// dropped.
  private var wantsAnotherPass = false

  init(
    plugin: any GoogleTasksIntegrationPlugin,
    storeProvider: @escaping () -> WorkspaceStore?,
    isEnabled: @escaping () -> Bool,
    ledgerStore: GoogleTasksMirrorLedgerStore = GoogleTasksMirrorLedgerStore(),
    conflictLog: GoogleTasksConflictLog = GoogleTasksConflictLog()
  ) {
    self.plugin = plugin
    self.storeProvider = storeProvider
    self.isEnabled = isEnabled
    self.ledgerStore = ledgerStore
    self.conflictLog = conflictLog
    self.recentConflicts = conflictLog.recent()
    self.mirroredTaskCount = ledgerStore.load().tasks.count
  }

  // MARK: - Triggers

  /// Something changed locally. Coalesced, because a mirror that pushed on
  /// every keystroke would spend the day rate-limited.
  func scheduleSync() {
    guard isEnabled() else { return }
    pendingSync?.cancel()
    pendingSync = Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      await self?.sync()
    }
  }

  /// The user asked, so it happens now rather than in four seconds.
  func syncNow() {
    pendingSync?.cancel()
    pendingSync = Task { [weak self] in await self?.sync() }
  }

  /// Starts the background poll. Cheap while the integration is off: it wakes,
  /// sees it is disabled, and goes back to sleep.
  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.pollInterval)
        guard !Task.isCancelled else { return }
        await self?.sync()
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    pendingSync?.cancel()
    pendingSync = nil
  }

  // MARK: - One pass

  func sync() async {
    guard isEnabled(), plugin.isAuthenticated else { return }
    guard !isRunning else {
      wantsAnotherPass = true
      return
    }
    isRunning = true
    defer { isRunning = false }

    // A loop rather than a recursive call: `isRunning` is still set here, so a
    // recursive `sync()` would only ever set the flag again and return.
    repeat {
      state = .syncing
      do {
        try await runPass()
        state = .idle
        lastSyncedAt = .now
      } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.error("Google Tasks mirror failed: \(message, privacy: .public)")
        state = .failed(message)
      }
    } while consumeWantsAnotherPass()
  }

  /// Whether a change arrived during the pass that just finished, clearing
  /// the flag either way. False once the integration has been switched off or
  /// signed out mid-pass, whatever the flag says.
  private func consumeWantsAnotherPass() -> Bool {
    defer { wantsAnotherPass = false }
    return wantsAnotherPass && isEnabled() && plugin.isAuthenticated
  }

  private func runPass() async throws {
    guard let store = storeProvider() else { return }
    // The ledger file and the whole-workspace read are the heavy, local half
    // of a pass, and nothing on screen waits for either, so they run off the
    // main thread. The pass itself stays serial: `isRunning` was set before
    // the first suspension, so nothing can start another in the meantime.
    let ledgerStore = self.ledgerStore
    var ledger = await Task.detached(priority: .utility) { ledgerStore.load() }.value

    let (localLists, localTasks) = try await Task.detached(priority: .utility) {
      try Self.snapshot(store: store)
    }.value
    let remoteLists = try await plugin.fetchTaskLists()
    // Only the lists this mirror owns are read. An unrelated Google Tasks list
    // is none of Priority's business, and fetching it would only invite the
    // planner to have an opinion about it.
    let mirroredListIDs = Set(ledger.lists.values).intersection(Set(remoteLists.map(\.id)))
    var remoteTasks: [GoogleTasksMirror.RemoteTask] = []
    for listID in mirroredListIDs {
      remoteTasks += try await plugin.fetchTasks(inList: listID)
    }

    let plan = GoogleTasksMirror.plan(
      localLists: localLists, localTasks: localTasks, remoteLists: remoteLists,
      remoteTasks: remoteTasks, ledger: ledger)

    guard !plan.isEmpty else {
      mirroredTaskCount = ledger.tasks.count
      return
    }

    let titlesByLocalID = Dictionary(
      localTasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    var wroteLocally = false
    do {
      try await apply(plan.operations, ledger: &ledger, store: store, wroteLocally: &wroteLocally)
    } catch {
      // The ledger already holds every Google write that landed before the
      // failure, and it has to reach disk before the error reaches anyone:
      // otherwise the next pass, reading the old ledger, would create those
      // tasks in Google a second time and then adopt the first copies back as
      // if a phone had typed them. The save's own failure is not allowed to
      // mask the one that stopped the pass.
      try? await save(ledger)
      if wroteLocally { onWroteLocally?() }
      throw error
    }
    record(plan.conflicts, titles: titlesByLocalID)

    try await save(ledger)
    if wroteLocally { onWroteLocally?() }
  }

  private func save(_ ledger: GoogleTasksMirror.Ledger) async throws {
    let ledgerStore = self.ledgerStore
    try await Task.detached(priority: .utility) { try ledgerStore.save(ledger) }.value
    mirroredTaskCount = ledger.tasks.count
  }

  /// Everything Priority holds, flattened into the planner's vocabulary.
  ///
  /// Archived lists are left out rather than filtered later: to the mirror,
  /// archiving is the list ceasing to exist, which is what makes its Google
  /// copy go away.
  nonisolated private static func snapshot(store: WorkspaceStore) throws
    -> ([GoogleTasksMirror.LocalList], [GoogleTasksMirror.LocalTask])
  {
    // A workspace that will not resolve is not the same thing as a workspace
    // with nothing in it, and the difference is destructive: an empty local
    // side means "delete every mirrored list" to the planner, which is the
    // wrong reading of "I could not read my own data". A workspace that
    // genuinely holds no lists still deletes, because that is true.
    guard let workspace = try store.workspaces().first else {
      throw GoogleTasksMirrorError.workspaceUnavailable
    }
    let lists = try store.lists(in: workspace.id, includingArchived: false)
    // One read of every list rather than one per list.
    let trees = try store.listTrees(in: lists.map(\.id))
    var localLists: [GoogleTasksMirror.LocalList] = []
    var localTasks: [GoogleTasksMirror.LocalTask] = []

    for list in lists {
      localLists.append(.init(id: list.id, name: list.name))
      for item in trees[list.id]?.outline() ?? [] {
        let task = item.task
        // A list-shaped task is a container, and a container is a Google list
        // rather than a task in one. Cancelled work is not work to do.
        guard !task.isList, task.status != TaskStatus.cancelled, task.archivedAt == nil else { continue }
        localTasks.append(
          .init(
            id: task.id, listID: list.id, parentID: task.parentTaskId, title: task.title,
            notes: task.notes, due: task.dueAt, isCompleted: task.status == TaskStatus.completed))
      }
    }
    return (localLists, localTasks)
  }

  // MARK: - Carrying out a plan

  /// Carries the plan out. `ledger` is updated after each Google write rather
  /// than at the end, and `wroteLocally` is set by the first workspace write,
  /// so both are accurate at the point a throw leaves this function.
  private func apply(
    _ operations: [GoogleTasksMirror.Operation],
    ledger: inout GoogleTasksMirror.Ledger,
    store: WorkspaceStore,
    wroteLocally: inout Bool
  ) async throws {
    // Lists first: a task cannot be created in a list that does not exist yet,
    // and the ids handed back are what the task operations need.
    for operation in operations {
      switch operation {
      case .createList(let localListID, let title):
        ledger.lists[localListID] = try await plugin.createTaskList(title: title)
      case .adoptRemoteList(let localListID, let remoteListID):
        // Nothing to send: the list is already there, and the ledger learning
        // its id is the whole of the adoption.
        ledger.lists[localListID] = remoteListID
      case .renameList(let remoteListID, let title):
        try await forgiving { try await plugin.renameTaskList(id: remoteListID, title: title) }
      case .deleteList(let remoteListID, let localListID):
        try await forgiving { try await plugin.deleteTaskList(id: remoteListID) }
        ledger.lists.removeValue(forKey: localListID)
        // The tasks went with it. Keeping their entries would make the next
        // pass try to update tasks in a list that is gone.
        ledger.tasks = ledger.tasks.filter { $0.value.remoteListID != remoteListID }
      default:
        continue
      }
    }

    for operation in operations {
      switch operation {
      case .createList, .adoptRemoteList, .renameList, .deleteList:
        continue

      case .createTask(let localID, let remoteListID, let payload):
        let remoteID = try await plugin.createTask(inList: remoteListID, payload: payload)
        ledger.tasks[localID] = entry(remoteID: remoteID, listID: remoteListID, payload: payload)

      case .updateTask(let localID, let remoteID, let remoteListID, let payload):
        try await forgiving {
          try await plugin.updateTask(id: remoteID, inList: remoteListID, payload: payload)
        }
        ledger.tasks[localID] = entry(remoteID: remoteID, listID: remoteListID, payload: payload)

      case .deleteTask(let remoteID, let remoteListID, let localID):
        try await forgiving { try await plugin.deleteTask(id: remoteID, inList: remoteListID) }
        ledger.tasks.removeValue(forKey: localID)

      // Workspace writes are per-operation rather than pass-fatal. The store
      // has opinions the planner cannot check against its snapshot — a task
      // deleted locally since the read, a list that has just gone — and one
      // row it refuses must not stop every other row from syncing, or the
      // mirror would fail at the same place five minutes from now, forever.
      // What the ledger records is only what actually landed, so a skipped
      // write is retried next pass rather than believed.
      case .completeLocalTask(let localID):
        if locally("complete", localID, { try store.setStatus(.completed, for: localID) }) {
          ledger.tasks[localID]?.pushedCompleted = true
          wroteLocally = true
        }

      case .mergeNotesIntoLocalTask(let localID, let notes):
        if locally("merge notes into", localID, { try mergeNotes(notes, into: localID, store: store) }) {
          ledger.tasks[localID]?.pushedNotes = notes
          wroteLocally = true
        }

      case .adoptRemoteTask(let remoteID, let remoteListID, let localListID, let payload):
        let created: WorkspaceTask
        do {
          created = try store.createTask(listId: localListID, title: payload.title)
        } catch {
          logger.error(
            "Google Tasks mirror could not adopt \(remoteID, privacy: .public): \(error.localizedDescription, privacy: .public)")
          continue
        }
        wroteLocally = true
        // The ledger entry is written against what the local task really has
        // in it, so if the notes and due date fail to land the entry says they
        // were never pushed, and the next pass merges them in again instead of
        // reading the gap as a local decision to clear them.
        var landed = GoogleTasksMirror.TaskPayload(
          title: payload.title, notes: "", due: nil, isCompleted: false)
        if !payload.notes.isEmpty || payload.due != nil,
          locally("fill in", created.id, {
            try store.updateTask(
              id: created.id, title: payload.title, notes: payload.notes,
              dueAt: payload.due.flatMap { GoogleTasksMirror.parseDueDate($0) },
              estimateSeconds: nil)
          })
        {
          landed = payload
        }
        ledger.tasks[created.id] = entry(remoteID: remoteID, listID: remoteListID, payload: landed)
      }
    }
  }

  /// Runs one workspace write, logging a failure instead of throwing it.
  /// Returns whether it landed, so the caller can keep the ledger honest.
  private func locally(_ verb: String, _ localID: String, _ work: () throws -> Void) -> Bool {
    do {
      try work()
      return true
    } catch {
      logger.error(
        "Google Tasks mirror could not \(verb, privacy: .public) local task \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  private func mergeNotes(_ notes: String, into localID: String, store: WorkspaceStore) throws {
    let snapshot = try store.taskEditorSnapshot(for: localID)
    try store.updateTask(
      id: localID, title: snapshot.title, notes: notes, dueAt: snapshot.dueAt,
      estimateSeconds: snapshot.estimateSeconds)
  }

  private func entry(
    remoteID: String, listID: String, payload: GoogleTasksMirror.TaskPayload
  ) -> GoogleTasksMirror.LedgerEntry {
    .init(
      remoteID: remoteID, remoteListID: listID, pushedTitle: payload.title,
      pushedNotes: payload.notes, pushedDue: payload.due, pushedCompleted: payload.isCompleted)
  }

  /// Runs a write that is allowed to find its target already gone. Deleting
  /// something twice is the same outcome as deleting it once, and a mirror
  /// that failed the whole pass over it would never get past the first
  /// tidy-up on a phone.
  private func forgiving(_ work: () async throws -> Void) async throws {
    do {
      try await work()
    } catch GoogleTasksPluginError.alreadyGone {
      return
    }
  }

  private func record(_ conflicts: [GoogleTasksMirror.Conflict], titles: [String: String]) {
    guard !conflicts.isEmpty else { return }
    let now = Date.now
    let records = conflicts.map { conflict in
      GoogleTasksConflictRecord(
        id: "\(conflict.localID)/\(conflict.field.rawValue)/\(now.timeIntervalSince1970)",
        resolvedAt: now,
        taskTitle: titles[conflict.localID] ?? conflict.localValue,
        field: conflict.field,
        keptValue: conflict.localValue,
        discardedValue: conflict.remoteValue)
    }
    conflictLog.append(records)
    recentConflicts = conflictLog.recent()
    logger.info("Google Tasks mirror resolved \(records.count, privacy: .public) conflicts locally")
  }
}

enum GoogleTasksMirrorError: LocalizedError {
  case workspaceUnavailable

  var errorDescription: String? {
    switch self {
    case .workspaceUnavailable:
      return "Could not read the local workspace, so nothing was mirrored."
    }
  }
}
