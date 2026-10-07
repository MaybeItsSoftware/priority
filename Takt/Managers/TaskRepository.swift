import Foundation
import OSLog
import Observation
import TaktCore

/// A task creation that was attempted while offline and is awaiting replay.
struct PendingTaskCreate: Sendable, Codable {
  let tempId: Int
  let content: String
  let parentId: Int?
  let position: Int?
}

/// A close/reopen/invalidate action queued while offline.
struct PendingTaskAction: Sendable, Codable {
  let taskId: Int
  let action: CheckvistTaskAction
}

/// The on-disk shape of a pending update (content/due) — mirrors the
/// in-memory tuple in `TaskRepository.pendingTaskMutations` for Codable's
/// sake (tuples aren't Codable).
struct PendingTaskUpdate: Sendable, Codable {
  let content: String?
  let due: String?
}

@MainActor
@Observable class TaskRepository {
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "repository")

  // MARK: - Dependencies

  @ObservationIgnored let preferencesStore: PreferencesStore
  @ObservationIgnored let localTaskStore: LocalTaskStore
  @ObservationIgnored let pendingOfflineWorkStore: PendingOfflineWorkStore
  @ObservationIgnored let checkvistSyncPlugin: any CheckvistSyncPlugin
  @ObservationIgnored let offlineSyncPlugin: OfflineTaskSyncPlugin
  @ObservationIgnored let reorderQueue = ReorderQueue()
  @ObservationIgnored let priorityQueueStore: ListScopedPriorityStore
  @ObservationIgnored let absolutePriorityQueueStore: ListScopedTaskIDStore
  @ObservationIgnored let legacyPriorityQueueStore: ListScopedTaskIDStore
  @ObservationIgnored let eisenhowerStore: ListScopedEisenhowerStore
  @ObservationIgnored let expandedTaskIdStore: ListScopedTaskIDStore
  @ObservationIgnored let cacheInvalidationBus: CacheInvalidationBus

  // MARK: - Callbacks

  @ObservationIgnored var onUsernameChanged: (() -> Void)?
  @ObservationIgnored var onRemoteKeyChanged: ((String) -> Void)?
  @ObservationIgnored var onListIdChanged: ((String) -> Void)?

  // MARK: - Constants

  /// Keyboard rank bounds (1...9); also used by legacy migration.
  static let maxPriorityRank = 9
  private static let priorityQueuesDefaultsKey = "priorityTaskIdsByListId"
  private static let scopedPriorityQueuesDefaultsKey = "priorityTaskIdsByParentIdByListId"
  private static let absolutePriorityQueuesDefaultsKey = "absolutePriorityTaskIdsByListId"
  private static let eisenhowerLevelsDefaultsKey = "eisenhowerLevelsByTaskIdByListId"
  private static let expandedTaskIdsDefaultsKey = "expandedTaskIdsByListId"

  // MARK: - Task Data

  var tasks: [CheckvistTask] = [] {
    didSet { cacheInvalidationBus.invalidate() }
  }
  var availableLists: [CheckvistList] = [] {
    didSet { cacheInvalidationBus.invalidate() }
  }

  // MARK: - Auth / Connection

  var username: String {
    didSet {
      preferencesStore.set(username, for: .checkvistUsername)
      // The settings field writes this on every keystroke. The Checkvist
      // token belongs to the name it was fetched with, so it is dropped once,
      // when the name first departs from the one the session has been using —
      // not on every character, which left nothing signed in while typing.
      let typed = CheckvistCredentials(username: username, remoteKey: "").normalizedUsername
      guard let inUse = usernameInUse, typed != inUse else { return }
      usernameInUse = nil
      onUsernameChanged?()
    }
  }
  /// The username the Checkvist session was last handed, as
  /// `activeCredentials` normalises it; nil until a request has gone out with
  /// the current name.
  @ObservationIgnored private var usernameInUse: String?
  var remoteKey: String {
    didSet {
      guard remoteKey != oldValue else { return }
      onRemoteKeyChanged?(remoteKey)
    }
  }
  var listId: String {
    didSet {
      preferencesStore.set(listId, for: .checkvistListId)
      loadPriorityQueue(for: listId)
      loadAbsolutePriorityQueue(for: listId)
      loadEisenhowerLevels(for: listId)
      loadExpandedTaskIds(for: listId)
      // Suppressions are ids in the list we just left; against a different
      // list they would hide unrelated tasks that happen to share an id.
      completionSuppressionByTaskId = [:]
      onListIdChanged?(listId)
    }
  }
  var checkvistIntegrationEnabled: Bool {
    didSet {
      guard checkvistIntegrationEnabled != oldValue else { return }
      preferencesStore.set(checkvistIntegrationEnabled, for: .checkvistIntegrationEnabled)
      cacheInvalidationBus.invalidate()
      onCheckvistIntegrationEnabledChanged?()
    }
  }
  @ObservationIgnored var onCheckvistIntegrationEnabledChanged: (() -> Void)?

  // MARK: - UI State

  var isLoading: Bool = false
  /// The last thing that went wrong, and only the last: this is overwritten by
  /// the next failure and cleared by the next fetch that starts. Anything that
  /// needs to *remember* a failure listens on `onErrorMessageSet` — the app
  /// layer records those, since this target can't see the diagnostics log.
  var errorMessage: String? {
    didSet {
      if let errorMessage, !errorMessage.isEmpty, errorMessage != oldValue {
        onErrorMessageSet?(errorMessage)
      }
    }
  }
  @ObservationIgnored var onErrorMessageSet: ((String) -> Void)?
  var isNetworkReachable: Bool = true {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// When a fetch last replaced `tasks` without erroring.
  ///
  /// Deliberately in memory only. The question it answers — "is what I am
  /// looking at current?" — is about this run of the app; a timestamp restored
  /// from disk would claim freshness for a list fetched days ago. The on-disk
  /// cache carries its own `fetchedAt` for the separate question of whether the
  /// cache is stale.
  private(set) var lastSuccessfulSyncAt: Date?

  func markSyncSucceeded(at date: Date = Date()) {
    lastSuccessfulSyncAt = date
  }

  // MARK: - Priority

  /// Per-parent priority queues. Key = parent task id (0 = root). No cap per scope.
  var priorityTaskIdsByParentId: [Int: [Int]] {
    didSet { cacheInvalidationBus.invalidate() }
  }

  /// Convenience: flattened set of all prioritized task ids across every scope.
  var prioritizedTaskIds: Set<Int> {
    Set(priorityTaskIdsByParentId.values.flatMap { $0 })
  }
  /// Global absolute-priority queue across all tasks in the list.
  var absolutePriorityTaskIds: [Int] {
    didSet { cacheInvalidationBus.invalidate() }
  }
  var taskEisenhowerLevels: [Int: EisenhowerLevel] = [:] {
    didSet { cacheInvalidationBus.invalidate() }
  }

  // MARK: - Outline

  /// Tasks whose children are shown inline, indented beneath them. Persisted
  /// per list, so the outline looks how it was left across launches.
  ///
  /// Lives here rather than on `NavigationState` because it is list-scoped
  /// state with a store behind it, like the priority queues either side of it —
  /// switching lists has to swap it, not carry it over.
  var expandedTaskIds: Set<Int> = [] {
    didSet {
      guard expandedTaskIds != oldValue else { return }
      cacheInvalidationBus.invalidate()
      expandedTaskIdStore.save(expandedTaskIds.sorted(), for: listId)
    }
  }

  var absolutePrioritizedTaskIds: Set<Int> {
    Set(absolutePriorityTaskIds)
  }

  // MARK: - Offline State

  /// Updates (content/due) that failed to reach Checkvist while offline.
  /// Replayed by `SyncService.flushPendingTaskMutations` on reconnect.
  @ObservationIgnored var pendingTaskMutations: [Int: (content: String?, due: String?)] = [:]
  /// Task creates that failed while offline. `tempId` is the optimistic
  /// (negative) id currently sitting in `tasks`; on replay we map it to the
  /// real server id so dependent actions/updates/deletes can be retargeted.
  @ObservationIgnored var pendingTaskCreates: [PendingTaskCreate] = []
  /// close/reopen/invalidate actions queued while offline. `taskId` may be
  /// negative if it refers to a task in `pendingTaskCreates`.
  @ObservationIgnored var pendingTaskActions: [PendingTaskAction] = []
  /// Deletes queued while offline. May contain negative ids referring to
  /// `pendingTaskCreates`; resolved at flush time.
  @ObservationIgnored var pendingTaskDeletes: [Int] = []
  @ObservationIgnored var loadingOperationCount: Int = 0
  @ObservationIgnored var hasAttemptedRemoteKeyBootstrap: Bool = false

  // MARK: - In-Flight Fetch State

  /// Bumped for every fetch issued. A response carrying an older generation is
  /// stale by definition — a newer fetch has been issued since — so it must not
  /// be written over `tasks`. Fetches come from several places at once (the
  /// become-active auto-refresh, the refresh button, every mutation's refetch,
  /// the reorder resync, the offline flush) and nothing serialises them, so
  /// without this the answers can land out of order.
  @ObservationIgnored private var fetchGeneration = 0

  /// Tasks the user has closed, invalidated or deleted locally, mapped to the
  /// first fetch generation allowed to contradict that.
  ///
  /// A fetch already in flight when the user completes a task answers with the
  /// pre-close list, and applying it verbatim brought the row straight back —
  /// the completed task reappearing, minus its priority rank, until the next
  /// refresh. Only a fetch issued *after* the close went out can speak to
  /// whether the task is still open.
  @ObservationIgnored private var completionSuppressionByTaskId: [Int: Int] = [:]

  /// Bumped whenever the offline queues change.
  ///
  /// The queues themselves are `@ObservationIgnored` on purpose — they are
  /// written on hot mutation paths and nothing renders them directly — which
  /// left `hasPendingOfflineWork` computed entirely from unobserved storage,
  /// so it could never drive a UI indicator. Only `SyncService` reads it today,
  /// so this was a trap rather than a bug; the revision closes it without
  /// making the arrays themselves observable. Every queue write goes through
  /// `persistPendingOfflineWork()` or `clearPendingOfflineWork()`, which is
  /// what makes one counter sufficient.
  private(set) var pendingOfflineWorkRevision = 0

  /// True when any offline-queued work is awaiting a reconnect flush.
  var hasPendingOfflineWork: Bool {
    _ = pendingOfflineWorkRevision
    return !pendingTaskMutations.isEmpty
      || !pendingTaskCreates.isEmpty
      || !pendingTaskActions.isEmpty
      || !pendingTaskDeletes.isEmpty
  }

  /// Wipes the in-memory queues *and* the on-disk payload. Only for work that
  /// is genuinely being abandoned — switching lists, where the queued ids refer
  /// to a list we are leaving. Replay does *not* use this: it removes each item
  /// as the server confirms it, so that quitting mid-flush cannot discard work
  /// that has not been applied yet.
  func clearPendingOfflineWork() {
    pendingTaskMutations = [:]
    pendingTaskCreates = []
    pendingTaskActions = []
    pendingTaskDeletes = []
    pendingOfflineWorkStore.clear()
    pendingOfflineWorkRevision &+= 1
  }

  // MARK: - Pending-queue enqueue helpers (write-through to disk)

  /// Append a create and persist. Call instead of mutating
  /// `pendingTaskCreates` directly so the on-disk payload stays in sync.
  func enqueuePendingCreate(_ create: PendingTaskCreate) {
    pendingTaskCreates.append(create)
    persistPendingOfflineWork()
  }

  /// Append an action (close/reopen/invalidate) and persist.
  func enqueuePendingAction(_ action: PendingTaskAction) {
    pendingTaskActions.append(action)
    persistPendingOfflineWork()
  }

  /// Append a delete and persist. `taskId` may be a negative temp id when
  /// the delete refers to a still-pending create.
  func enqueuePendingDelete(_ taskId: Int) {
    pendingTaskDeletes.append(taskId)
    persistPendingOfflineWork()
  }

  /// Record (or overwrite) an update for `taskId` and persist.
  func enqueuePendingMutation(taskId: Int, content: String?, due: String?) {
    pendingTaskMutations[taskId] = (content: content, due: due)
    persistPendingOfflineWork()
  }

  // MARK: - Pending-queue removal helpers (write-through to disk)
  //
  // The replay in `SyncService.flushPendingTaskMutations` removes each item as
  // it is confirmed, rather than clearing the whole queue up front and
  // re-stashing the failures. The old shape wiped the on-disk payload before
  // the first request went out, so quitting or crashing mid-flush lost every
  // item that had not yet failed — the queue exists precisely to survive that.

  /// Remove a create once the server has acknowledged it.
  func removePendingCreate(tempId: Int) {
    guard let idx = pendingTaskCreates.firstIndex(where: { $0.tempId == tempId }) else { return }
    pendingTaskCreates.remove(at: idx)
    persistPendingOfflineWork()
  }

  /// Remove a delete once it has been applied (or found to be moot).
  func removePendingDelete(_ taskId: Int) {
    guard let idx = pendingTaskDeletes.firstIndex(of: taskId) else { return }
    pendingTaskDeletes.remove(at: idx)
    persistPendingOfflineWork()
  }

  /// Remove one queued action. Matches on id *and* action so a task with both a
  /// close and a reopen queued loses only the one that was replayed.
  func removePendingAction(taskId: Int, action: CheckvistTaskAction) {
    guard
      let idx = pendingTaskActions.firstIndex(where: {
        $0.taskId == taskId && $0.action == action
      })
    else { return }
    pendingTaskActions.remove(at: idx)
    persistPendingOfflineWork()
  }

  /// Remove a queued content/due update.
  func removePendingMutation(taskId: Int) {
    guard pendingTaskMutations.removeValue(forKey: taskId) != nil else { return }
    persistPendingOfflineWork()
  }

  // MARK: - Pending-queue retargeting
  //
  // When a create replays successfully but the work queued behind it then
  // fails, that work is still filed under the placeholder id. Re-filing it
  // under the real server id means the next flush can send it without needing
  // this flush's temp→real mapping, which does not outlive the call.

  /// Re-file a queued delete from `oldId` to `newId`. No-op when they match.
  func retargetPendingDelete(from oldId: Int, to newId: Int) {
    guard oldId != newId else { return }
    if let idx = pendingTaskDeletes.firstIndex(of: oldId) {
      pendingTaskDeletes[idx] = newId
    } else {
      pendingTaskDeletes.append(newId)
    }
    persistPendingOfflineWork()
  }

  /// Re-file a queued action from `oldId` to `newId`. No-op when they match.
  func retargetPendingAction(from oldId: Int, to newId: Int, action: CheckvistTaskAction) {
    guard oldId != newId else { return }
    if let idx = pendingTaskActions.firstIndex(where: {
      $0.taskId == oldId && $0.action == action
    }) {
      pendingTaskActions[idx] = PendingTaskAction(taskId: newId, action: action)
    } else {
      pendingTaskActions.append(PendingTaskAction(taskId: newId, action: action))
    }
    persistPendingOfflineWork()
  }

  /// Re-file a queued update from `oldId` to `newId`. No-op when they match.
  func retargetPendingMutation(from oldId: Int, to newId: Int) {
    guard oldId != newId else { return }
    let carried = pendingTaskMutations.removeValue(forKey: oldId)
    pendingTaskMutations[newId] = carried ?? pendingTaskMutations[newId]
    persistPendingOfflineWork()
  }

  /// Drop any queued work that targets a still-pending temp create. Returns
  /// `true` if the create was found and cancelled — callers (delete) can use
  /// that to short-circuit the round-trip create+delete on the server.
  @discardableResult
  func cancelPendingCreate(tempId: Int) -> Bool {
    guard let idx = pendingTaskCreates.firstIndex(where: { $0.tempId == tempId }) else {
      return false
    }
    pendingTaskCreates.remove(at: idx)
    pendingTaskActions.removeAll { $0.taskId == tempId }
    pendingTaskMutations.removeValue(forKey: tempId)
    pendingTaskDeletes.removeAll { $0 == tempId }
    persistPendingOfflineWork()
    return true
  }

  private func persistPendingOfflineWork() {
    let codableMutations = pendingTaskMutations.mapValues {
      PendingTaskUpdate(content: $0.content, due: $0.due)
    }
    pendingOfflineWorkStore.save(
      PendingOfflineWorkPayload(
        listId: listId,
        creates: pendingTaskCreates,
        actions: pendingTaskActions,
        deletes: pendingTaskDeletes,
        mutations: codableMutations))
    pendingOfflineWorkRevision &+= 1
  }

  // MARK: - Computed Properties

  var hasCredentials: Bool {
    !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var canAttemptLogin: Bool { hasCredentials }
  var hasListSelection: Bool {
    !listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  /// The selected list's name, or empty when there is no selection or the lists
  /// haven't loaded yet.
  ///
  /// One source of truth: this was being re-derived at each call site that
  /// wanted to name the current list, and the toolbar switcher would have made
  /// that three.
  var currentListName: String {
    availableLists.first { String($0.id) == listId }?.name ?? ""
  }
  var checkvistConnectionState: CheckvistConnectionState {
    if !hasCredentials { return .disconnected }
    if availableLists.isEmpty {
      return isLoading ? .connecting : .awaitingConnect
    }
    return .connected(listCount: availableLists.count)
  }
  /// True when the Checkvist integration is enabled, credentials are present,
  /// and the user has chosen a list — i.e. when the remote sync plugin is the
  /// active route. When false, mutations and fetches go through the offline
  /// store. This is the single source of truth for plugin-switch state; do not
  /// re-derive `!checkvistIntegrationEnabled || !hasListSelection || ...`
  /// elsewhere in the app.
  var canSyncRemotely: Bool {
    checkvistIntegrationEnabled && hasListSelection && hasCredentials
  }
  var offlineOpenTaskCount: Int { localTaskStore.load().openTasks.count }
  /// Every Checkvist request reads this, which is what makes it the place to
  /// note which name the session is signed in under; see `username`.
  var activeCredentials: CheckvistCredentials {
    let credentials = CheckvistCredentials(username: username, remoteKey: remoteKey)
    usernameInUse = credentials.normalizedUsername
    return credentials
  }
  var activeSyncPlugin: any CheckvistSyncPlugin {
    canSyncRemotely ? checkvistSyncPlugin : offlineSyncPlugin
  }

  // MARK: - Init

  init(
    preferencesStore: PreferencesStore,
    checkvistSyncPlugin: any CheckvistSyncPlugin,
    localTaskStore: LocalTaskStore,
    // Defaulted to `nil` rather than `PendingOfflineWorkStore()` so it can pick
    // up the injected `defaults` below. The eager default silently ignored
    // `defaults:` and always wrote the offline queue to `UserDefaults.standard`,
    // which leaked queued work between tests — and between any two repositories
    // that thought they were isolated.
    pendingOfflineWorkStore: PendingOfflineWorkStore? = nil,
    initialRemoteKey: String,
    cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus(),
    defaults: UserDefaults = .standard
  ) {
    self.preferencesStore = preferencesStore
    self.checkvistSyncPlugin = checkvistSyncPlugin
    self.localTaskStore = localTaskStore
    let resolvedPendingOfflineWorkStore =
      pendingOfflineWorkStore ?? PendingOfflineWorkStore(defaults: defaults)
    self.pendingOfflineWorkStore = resolvedPendingOfflineWorkStore
    self.cacheInvalidationBus = cacheInvalidationBus
    self.offlineSyncPlugin = OfflineTaskSyncPlugin(localStore: localTaskStore)
    self.priorityQueueStore = ListScopedPriorityStore(
      defaultsKey: Self.scopedPriorityQueuesDefaultsKey,
      defaults: defaults
    )
    self.absolutePriorityQueueStore = ListScopedTaskIDStore(
      defaultsKey: Self.absolutePriorityQueuesDefaultsKey,
      defaults: defaults
    )
    self.legacyPriorityQueueStore = ListScopedTaskIDStore(
      defaultsKey: Self.priorityQueuesDefaultsKey,
      maximumCount: Self.maxPriorityRank,
      defaults: defaults
    )
    self.eisenhowerStore = ListScopedEisenhowerStore(
      defaultsKey: Self.eisenhowerLevelsDefaultsKey,
      defaults: defaults
    )
    self.expandedTaskIdStore = ListScopedTaskIDStore(
      defaultsKey: Self.expandedTaskIdsDefaultsKey,
      defaults: defaults
    )

    let offlinePayload = localTaskStore.load()
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedListId = preferencesStore.string(.checkvistListId)

    let hasLegacyCheckvist =
      !storedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let storedIntegrationEnabled = preferencesStore.optionalBool(.checkvistIntegrationEnabled)
    let resolvedIntegrationEnabled = storedIntegrationEnabled ?? hasLegacyCheckvist

    self.checkvistIntegrationEnabled = resolvedIntegrationEnabled
    self.username = storedUsername
    self.listId = storedListId
    self.remoteKey = initialRemoteKey
    let isOfflineAtLaunch =
      !resolvedIntegrationEnabled
      || storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || initialRemoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    self.tasks = isOfflineAtLaunch ? offlinePayload.openTasks : []
    self.priorityTaskIdsByParentId = Self.loadScopedPriorities(
      scoped: priorityQueueStore,
      legacy: legacyPriorityQueueStore,
      listId: storedListId
    )
    self.absolutePriorityTaskIds = absolutePriorityQueueStore.load(for: storedListId)
    self.taskEisenhowerLevels = eisenhowerStore.load(for: storedListId)
    self.expandedTaskIds = Set(expandedTaskIdStore.load(for: storedListId))

    // Restore offline-queued work for the current list. A payload scoped to a
    // different list is dropped — replaying its mutations against the active
    // list would silently target the wrong tasks.
    let pendingPayload = resolvedPendingOfflineWorkStore.load()
    if !pendingPayload.isEmpty && pendingPayload.listId == storedListId {
      self.pendingTaskCreates = pendingPayload.creates
      self.pendingTaskActions = pendingPayload.actions
      self.pendingTaskDeletes = pendingPayload.deletes
      self.pendingTaskMutations = pendingPayload.mutations.mapValues {
        (content: $0.content, due: $0.due)
      }
      // Re-insert the optimistic placeholders so the user sees their
      // unsynced tasks immediately — `fetchTopTask` after a reconnect will
      // replace them with the real server tasks once the queued creates
      // replay.
      for create in pendingPayload.creates where !self.tasks.contains(where: {
        $0.id == create.tempId
      }) {
        self.tasks.append(
          CheckvistTask(
            id: create.tempId,
            content: create.content,
            status: 0,
            due: nil,
            position: create.position,
            parentId: create.parentId,
            level: nil
          ))
      }
    } else if !pendingPayload.isEmpty {
      resolvedPendingOfflineWorkStore.clear()
    }
  }
}

// MARK: - In-Flight Fetch Coordination

extension TaskRepository {
  /// Opens a fetch. Hand the returned generation back to
  /// `isLatestFetchGeneration` once the response arrives, and to
  /// `filteringLocallyCompletedTasks(from:generation:)` before applying it.
  @MainActor func beginFetchGeneration() -> Int {
    fetchGeneration += 1
    return fetchGeneration
  }

  /// False once a newer fetch has been issued: that one owns `tasks` now, and
  /// letting this response land would put back whatever it superseded.
  @MainActor func isLatestFetchGeneration(_ generation: Int) -> Bool {
    generation == fetchGeneration
  }

  /// Records `taskIds` as completed locally, so no fetch already in flight can
  /// bring them back. Only a fetch issued from here on is trusted about them.
  @MainActor func suppressLocallyCompletedTasks(_ taskIds: Set<Int>) {
    guard !taskIds.isEmpty else { return }
    let firstTrustedGeneration = fetchGeneration + 1
    for taskId in taskIds {
      completionSuppressionByTaskId[taskId] = firstTrustedGeneration
    }
  }

  /// Lifts `suppressLocallyCompletedTasks`. Call it whenever an optimistic
  /// completion is undone — a rolled-back close, or a reopen — or the task
  /// stays invisible even though the server still lists it open.
  @MainActor func unsuppressLocallyCompletedTasks(_ taskIds: Set<Int>) {
    for taskId in taskIds {
      completionSuppressionByTaskId.removeValue(forKey: taskId)
    }
  }

  /// Strips tasks the user has completed locally out of a fetch response, and
  /// retires each suppression this response was new enough to speak for: it was
  /// issued after the close, so its answer is now the truth. If it still lists
  /// the task as open (the close silently didn't take, or it was reopened
  /// elsewhere) the task reappears on the *next* fetch rather than being hidden
  /// forever.
  ///
  /// Two sources feed the filter. The suppression map covers a close that has
  /// gone out but hasn't been confirmed; the offline queue covers one that
  /// hasn't gone out at all, and that one has no generation attached because it
  /// stays true for exactly as long as the work is queued — which is what keeps
  /// tasks completed offline from reappearing after a relaunch.
  @MainActor func filteringLocallyCompletedTasks(
    from fetchedTasks: [CheckvistTask], generation: Int
  ) -> [CheckvistTask] {
    var hiddenTaskIds = Set(completionSuppressionByTaskId.keys)
    hiddenTaskIds.formUnion(offlineCompletedTaskIds)

    let retiredTaskIds = completionSuppressionByTaskId
      .filter { $0.value <= generation }
      .map(\.key)
    for taskId in retiredTaskIds {
      completionSuppressionByTaskId.removeValue(forKey: taskId)
    }

    guard !hiddenTaskIds.isEmpty else { return fetchedTasks }
    return fetchedTasks.filter { !hiddenTaskIds.contains($0.id) }
  }

  /// Ids whose close, invalidate or delete is still waiting in the offline
  /// queue. Walked in order so a reopen queued behind a close wins — the
  /// ancestor reopens that defeat Checkvist's cascade sit behind a child close,
  /// so the order genuinely matters.
  private var offlineCompletedTaskIds: Set<Int> {
    var closed: Set<Int> = []
    for pending in pendingTaskActions {
      switch pending.action {
      case .close, .invalidate: closed.insert(pending.taskId)
      case .reopen: closed.remove(pending.taskId)
      }
    }
    closed.formUnion(pendingTaskDeletes)
    return closed
  }
}

// MARK: - Loading Helpers

extension TaskRepository {
  @MainActor func beginLoading() {
    loadingOperationCount += 1
    isLoading = true
  }

  @MainActor func endLoading() {
    loadingOperationCount = max(loadingOperationCount - 1, 0)
    isLoading = loadingOperationCount > 0
  }

  @MainActor func withLoadingState<T>(_ operation: () async throws -> T) async rethrows -> T {
    beginLoading()
    defer { endLoading() }
    return try await operation()
  }

  @MainActor func setAuthenticationRequiredErrorIfNeeded() {
    if errorMessage == nil {
      errorMessage = "Authentication required."
    }
  }

  @MainActor func runBooleanMutation(
    failureMessage: String,
    errorMessageBuilder: @escaping (Error) -> String = { "Error: \($0.localizedDescription)" },
    action: () async throws -> Bool,
    onSuccess: @MainActor () async -> Void
  ) async {
    do {
      let success = try await action()
      if success {
        await onSuccess()
      } else {
        errorMessage = failureMessage
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      self.errorMessage = errorMessageBuilder(error)
    }
  }
}

// MARK: - Priority Queue

extension TaskRepository {
  static func normalizedTaskIdQueue(_ queue: [Int], maximumCount: Int? = nil) -> [Int] {
    var seen = Set<Int>()
    var normalized: [Int] = []
    for taskId in queue where taskId > 0 && !seen.contains(taskId) {
      seen.insert(taskId)
      normalized.append(taskId)
    }
    if let maximumCount, normalized.count > maximumCount {
      return Array(normalized.prefix(maximumCount))
    }
    return normalized
  }

  static func loadScopedPriorities(
    scoped: ListScopedPriorityStore,
    legacy: ListScopedTaskIDStore,
    listId: String
  ) -> [Int: [Int]] {
    let byParent = scoped.load(for: listId)
    if !byParent.isEmpty { return byParent }
    let legacyFlat = legacy.load(for: listId)
    guard !legacyFlat.isEmpty else { return [:] }
    // Migrate the legacy flat queue to root-scope. We don't have parentId info at this
    // point (tasks not loaded yet), so drop the legacy key into root. Re-scoping happens
    // on the next reconcile once tasks are loaded.
    return [0: legacyFlat]
  }

  func loadPriorityQueue(for listId: String) {
    priorityTaskIdsByParentId = Self.loadScopedPriorities(
      scoped: priorityQueueStore,
      legacy: legacyPriorityQueueStore,
      listId: listId
    )
  }

  func savePriorityQueue(_ queues: [Int: [Int]]) {
    var normalized: [Int: [Int]] = [:]
    for (parentId, ids) in queues {
      let dedup = ListScopedPriorityStore.normalizedQueue(ids)
      if !dedup.isEmpty { normalized[parentId] = dedup }
    }
    priorityTaskIdsByParentId = normalized
    priorityQueueStore.save(normalized, for: listId)
  }

  func loadExpandedTaskIds(for listId: String) {
    expandedTaskIds = Set(expandedTaskIdStore.load(for: listId))
  }

  func isExpanded(taskId: Int) -> Bool {
    expandedTaskIds.contains(taskId)
  }

  func setExpanded(_ expanded: Bool, taskId: Int) {
    guard taskId != 0 else { return }
    if expanded {
      expandedTaskIds.insert(taskId)
    } else {
      expandedTaskIds.remove(taskId)
    }
  }

  func toggleExpanded(taskId: Int) {
    setExpanded(!isExpanded(taskId: taskId), taskId: taskId)
  }

  /// Opens every task that has children. Used by the `expand all` command.
  func expandAll() {
    let parentIds = Set(tasks.compactMap { $0.parentId }).subtracting([0])
    expandedTaskIds = parentIds
  }

  func collapseAll() {
    expandedTaskIds = []
  }

  func loadAbsolutePriorityQueue(for listId: String) {
    absolutePriorityTaskIds = absolutePriorityQueueStore.load(for: listId)
  }

  func saveAbsolutePriorityQueue(_ queue: [Int]) {
    let normalized = Self.normalizedTaskIdQueue(queue)
    absolutePriorityTaskIds = normalized
    absolutePriorityQueueStore.save(normalized, for: listId)
  }

  @MainActor func setAbsolutePriority(taskId: Int, rank: Int) {
    guard taskId > 0, rank >= 1 else { return }
    var queue = absolutePriorityTaskIds.filter { $0 != taskId }
    let insertIndex = min(max(rank - 1, 0), queue.count)
    queue.insert(taskId, at: insertIndex)
    saveAbsolutePriorityQueue(queue)
  }

  @MainActor func clearAbsolutePriority(taskId: Int) {
    guard taskId > 0 else { return }
    guard absolutePriorityTaskIds.contains(taskId) else { return }
    saveAbsolutePriorityQueue(absolutePriorityTaskIds.filter { $0 != taskId })
  }

  @MainActor func removeTasksFromPriorityQueue(_ taskIds: Set<Int>) {
    guard !taskIds.isEmpty else { return }
    var changed = false
    var updated = priorityTaskIdsByParentId
    for (parentId, ids) in updated {
      let filtered = ids.filter { !taskIds.contains($0) }
      if filtered.count != ids.count {
        changed = true
        if filtered.isEmpty {
          updated.removeValue(forKey: parentId)
        } else {
          updated[parentId] = filtered
        }
      }
    }
    let filteredAbsolute = absolutePriorityTaskIds.filter { !taskIds.contains($0) }
    if filteredAbsolute.count != absolutePriorityTaskIds.count {
      changed = true
    }
    guard changed else { return }
    savePriorityQueue(updated)
    if filteredAbsolute != absolutePriorityTaskIds {
      saveAbsolutePriorityQueue(filteredAbsolute)
    }
  }

  @MainActor func reconcilePriorityQueueWithOpenTasks() {
    let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    let openTaskIds = Set(tasks.map(\.id))
    var updated: [Int: [Int]] = [:]
    var changed = false
    for (parentId, ids) in priorityTaskIdsByParentId {
      let retained = CompletionRetention.retained(storedIds: ids, openTaskIds: openTaskIds)
      for id in ids {
        guard retained.contains(id) else { changed = true; continue }
        // A task that is retained but not open has been completed. It keeps the
        // scope it was ranked in — there is no current parent to read, and
        // re-scoping it to the root would move it on reopening.
        guard openTaskIds.contains(id) else {
          updated[parentId, default: []].append(id)
          continue
        }
        // Re-scope each task under its *actual* current parent. This keeps stored
        // queues coherent if a task was moved, and also normalizes legacy-migrated
        // queues that all landed under root scope.
        let actualParent = tasksById[id]?.parentId ?? 0
        if actualParent != parentId { changed = true }
        updated[actualParent, default: []].append(id)
      }
    }
    if changed {
      savePriorityQueue(updated)
    }

    let retainedAbsolute = CompletionRetention.retained(
      storedIds: absolutePriorityTaskIds, openTaskIds: openTaskIds)
    let filteredAbsolute = absolutePriorityTaskIds.filter { retainedAbsolute.contains($0) }
    if filteredAbsolute != absolutePriorityTaskIds {
      saveAbsolutePriorityQueue(filteredAbsolute)
    }
    // Drop expansion state for tasks that are gone, so the store doesn't grow
    // forever. Skipped when there are no tasks at all — that's the pre-fetch
    // state, not an empty list, and pruning against it would forget the whole
    // outline every launch.
    if !tasks.isEmpty {
      let stillOpen = expandedTaskIds.intersection(openTaskIds)
      if stillOpen != expandedTaskIds {
        expandedTaskIds = stillOpen
      }
    }
    reconcileEisenhowerLevels()
  }
}

// MARK: - Eisenhower Matrix

extension TaskRepository {
  func loadEisenhowerLevels(for listId: String) {
    taskEisenhowerLevels = eisenhowerStore.load(for: listId)
  }

  func saveEisenhowerLevels(_ levels: [Int: EisenhowerLevel]) {
    taskEisenhowerLevels = levels
    eisenhowerStore.save(levels, for: listId)
  }

  @MainActor func setUrgency(taskId: Int, level: Double) {
    var updated = taskEisenhowerLevels
    var current = updated[taskId] ?? .zero
    current.urgency = level
    updated[taskId] = current
    saveEisenhowerLevels(updated)
  }

  @MainActor func setImportance(taskId: Int, level: Double) {
    var updated = taskEisenhowerLevels
    var current = updated[taskId] ?? .zero
    current.importance = level
    updated[taskId] = current
    saveEisenhowerLevels(updated)
  }

  @MainActor func reconcileEisenhowerLevels() {
    let retained = CompletionRetention.retained(
      storedIds: taskEisenhowerLevels.keys, openTaskIds: Set(tasks.map(\.id)))
    let filtered = taskEisenhowerLevels.filter { retained.contains($0.key) }
    if filtered.count != taskEisenhowerLevels.count {
      saveEisenhowerLevels(filtered)
    }
  }
}

// MARK: - API

extension TaskRepository {
  @MainActor func login() async -> Bool {
    let credentials = activeCredentials
    guard !credentials.normalizedUsername.isEmpty, !credentials.normalizedRemoteKey.isEmpty else {
      errorMessage = "Username or Remote Key is missing."
      return false
    }

    errorMessage = nil

    do {
      return try await withLoadingState {
        let success = try await checkvistSyncPlugin.login(credentials: credentials)
        guard success else {
          errorMessage = "Login failed. Check your credentials."
          return false
        }
        return true
      }
    } catch {
      errorMessage = "Network error: \(error.localizedDescription)"
      return false
    }
  }

  @MainActor func fetchLists() async -> Bool {
    do {
      let lists = try await checkvistSyncPlugin.fetchLists(credentials: activeCredentials)
      self.availableLists = lists
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      self.errorMessage = "Failed to fetch lists: \(error.localizedDescription)"
      return false
    }
  }

  @MainActor func loadCheckvistLists(assignFirstIfMissing: Bool = false) async -> Bool {
    let success = await login()
    guard success else { return false }
    let didFetchLists = await fetchLists()
    guard didFetchLists else { return false }

    if assignFirstIfMissing, listId.isEmpty, let first = availableLists.first {
      listId = String(first.id)
    }
    return true
  }

  /// Fetch a remote Checkvist list without changing the user's active list.
  /// The desktop workspace uses this to take a local snapshot of every list
  /// visible in its sidebar; its existence must not depend on which sync route
  /// happens to be active for the legacy menu-bar surface.
  @MainActor func fetchCheckvistOpenTasks(listId: String) async throws -> [CheckvistTask] {
    try await checkvistSyncPlugin.fetchOpenTasks(listId: listId, credentials: activeCredentials)
  }

  @MainActor func selectList(_ list: CheckvistList) {
    listId = String(list.id)
  }

  func copyTasks(_ sourceTasks: [CheckvistTask], to destinationListId: String) async throws
    -> (mergedCount: Int, skippedCount: Int)
  {
    var migratedBySourceTaskID: [Int: Int] = [:]
    var mergedCount = 0
    var skippedCount = 0

    for sourceTask in sourceTasks {
      let resolvedParentID = sourceTask.parentId.flatMap { migratedBySourceTaskID[$0] }
      guard
        let created = try await checkvistSyncPlugin.createTask(
          listId: destinationListId,
          content: sourceTask.content,
          parentId: resolvedParentID,
          position: nil,
          credentials: activeCredentials
        )
      else {
        skippedCount += 1
        continue
      }

      migratedBySourceTaskID[sourceTask.id] = created.id
      if let due = sourceTask.due, !due.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = try await checkvistSyncPlugin.updateTask(
          listId: destinationListId,
          taskId: created.id,
          content: nil,
          due: due,
          credentials: activeCredentials
        )
      }
      mergedCount += 1
    }

    return (mergedCount, skippedCount)
  }
}
