import Foundation
import Observation
import PriorityCore
import PriorityWorkspace
import os

/// Drives the Google Tasks mirror.
///
/// Reads both sides, asks `GoogleTasksMirror` what should happen, and carries
/// it out — against Google through the plugin, against the workspace through
/// the store. The order matters and is the one thing worth knowing about this
/// file: lists are created before the tasks that go in them, and the ledger is
/// written last, so a pass that dies halfway leaves the next one able to work
/// out where it got to rather than duplicating what it already did.
///
/// A pass is never concurrent with itself. Google Tasks has no transactions,
/// and two passes racing would each see the other's half-finished work as
/// remote edits to argue with.
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
    subsystem: "uk.co.maybeitsadam.priority", category: "GoogleTasksMirrorService")

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
    state = .syncing
    defer { isRunning = false }

    do {
      try await runPass()
      state = .idle
      lastSyncedAt = .now
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      logger.error("Google Tasks mirror failed: \(message, privacy: .public)")
      state = .failed(message)
    }

    if wantsAnotherPass {
      wantsAnotherPass = false
      await sync()
    }
  }

  private func runPass() async throws {
    guard let store = storeProvider() else { return }
    var ledger = ledgerStore.load()

    let (localLists, localTasks) = try snapshot(store: store)
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
    try await apply(plan.operations, ledger: &ledger, store: store)
    record(plan.conflicts, titles: titlesByLocalID)

    try ledgerStore.save(ledger)
    mirroredTaskCount = ledger.tasks.count
  }

  /// Everything Priority holds, flattened into the planner's vocabulary.
  ///
  /// Archived lists are left out rather than filtered later: to the mirror,
  /// archiving is the list ceasing to exist, which is what makes its Google
  /// copy go away.
  private func snapshot(store: WorkspaceStore) throws
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
    var localLists: [GoogleTasksMirror.LocalList] = []
    var localTasks: [GoogleTasksMirror.LocalTask] = []

    for list in lists {
      localLists.append(.init(id: list.id, name: list.name))
      for item in try store.outline(in: list.id) {
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

  private func apply(
    _ operations: [GoogleTasksMirror.Operation],
    ledger: inout GoogleTasksMirror.Ledger,
    store: WorkspaceStore
  ) async throws {
    // Lists first: a task cannot be created in a list that does not exist yet,
    // and the ids handed back are what the task operations need.
    for operation in operations {
      switch operation {
      case .createList(let localListID, let title):
        ledger.lists[localListID] = try await plugin.createTaskList(title: title)
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
      case .createList, .renameList, .deleteList:
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

      case .completeLocalTask(let localID):
        try store.setStatus(.completed, for: localID)
        ledger.tasks[localID]?.pushedCompleted = true

      case .mergeNotesIntoLocalTask(let localID, let notes):
        try mergeNotes(notes, into: localID, store: store)
        ledger.tasks[localID]?.pushedNotes = notes

      case .adoptRemoteTask(let remoteID, let remoteListID, let localListID, let payload):
        let created = try store.createTask(listId: localListID, title: payload.title)
        if !payload.notes.isEmpty || payload.due != nil {
          try store.updateTask(
            id: created.id, title: payload.title, notes: payload.notes,
            dueAt: payload.due.flatMap { GoogleTasksMirror.parseDueDate($0) },
            estimateSeconds: nil)
        }
        ledger.tasks[created.id] = entry(
          remoteID: remoteID, listID: remoteListID, payload: payload)
      }
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
