import Foundation

@MainActor
final class OfflineTaskSyncPlugin: CheckvistSyncPlugin {
  let pluginIdentifier = "native.offline.store"
  let displayName = "Offline Store"
  let pluginDescription = "Local offline task storage."

  private let localStore: LocalTaskStore
  private var archivedTasksById: [Int: CheckvistTask] = [:]
  private var nextTaskIdValue: Int = 1

  init(localStore: LocalTaskStore = LocalTaskStore()) {
    self.localStore = localStore
    let payload = localStore.load()
    self.archivedTasksById = Dictionary(
      uniqueKeysWithValues: payload.archivedTasks.map { ($0.id, $0) })
    self.nextTaskIdValue = max(payload.nextTaskId, 1)
  }

  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  {
    let payload = localStore.load()
    return normalizeOfflineTasks(payload.openTasks)
  }

  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList] {
    return []
  }

  func login(credentials: CheckvistCredentials) async throws -> Bool {
    return true
  }

  func clearAuthentication() {}

  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    let payload = localStore.load()
    var openTasks = payload.openTasks
    var archivedTasks = payload.archivedTasks

    if action == .close || action == .invalidate {
      let status = action == .invalidate ? -1 : 1
      if let index = openTasks.firstIndex(where: { $0.id == taskId }) {
        let task = openTasks[index]
        let archived = rebuiltTask(task, status: status)
        openTasks.remove(at: index)

        // Also remove children
        let descendantIds = getDescendantIds(for: taskId, in: openTasks)
        let descendants = openTasks.filter { descendantIds.contains($0.id) }
        openTasks.removeAll { descendantIds.contains($0.id) }

        archivedTasksById[taskId] = archived
        for desc in descendants {
          archivedTasksById[desc.id] = rebuiltTask(desc, status: status)
        }
      }
    } else if action == .reopen {
      if let archived = archivedTasksById[taskId] {
        archivedTasksById.removeValue(forKey: taskId)
        let reopened = rebuiltTask(archived, status: 0)
        openTasks.append(reopened)
      }
    }

    archivedTasks = Array(archivedTasksById.values)
    localStore.save(
      OfflineTaskStorePayload(
        openTasks: openTasks, archivedTasks: archivedTasks, nextTaskId: nextTaskIdValue))
    return true
  }

  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    let payload = localStore.load()
    var openTasks = payload.openTasks

    if let index = openTasks.firstIndex(where: { $0.id == taskId }) {
      let task = openTasks[index]
      openTasks[index] = rebuiltTask(task, content: content ?? task.content, due: due ?? task.due)
      localStore.save(
        OfflineTaskStorePayload(
          openTasks: openTasks, archivedTasks: payload.archivedTasks, nextTaskId: nextTaskIdValue))
      return true
    }
    return false
  }

  func createTask(
    listId: String,
    content: String,
    parentId: Int?,
    position: Int?,
    credentials: CheckvistCredentials
  ) async throws -> CheckvistTask? {
    let payload = localStore.load()
    var openTasks = payload.openTasks

    let taskId = nextTaskIdValue
    nextTaskIdValue += 1

    let newTask = CheckvistTask(
      id: taskId, content: content, status: 0, due: nil, position: position, parentId: parentId,
      level: nil
    )
    openTasks.append(newTask)

    localStore.save(
      OfflineTaskStorePayload(
        openTasks: openTasks, archivedTasks: payload.archivedTasks, nextTaskId: nextTaskIdValue))
    return newTask
  }

  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  {
    let payload = localStore.load()
    var openTasks = payload.openTasks

    let descendantIds = getDescendantIds(for: taskId, in: openTasks)
    var toRemove = descendantIds
    toRemove.insert(taskId)

    openTasks.removeAll { toRemove.contains($0.id) }

    localStore.save(
      OfflineTaskStorePayload(
        openTasks: openTasks, archivedTasks: payload.archivedTasks, nextTaskId: nextTaskIdValue))
    return true
  }

  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    let payload = localStore.load()
    var openTasks = payload.openTasks

    if let index = openTasks.firstIndex(where: { $0.id == taskId }) {
      let task = openTasks[index]
      openTasks[index] = rebuiltTask(task, position: position)
      localStore.save(
        OfflineTaskStorePayload(
          openTasks: openTasks, archivedTasks: payload.archivedTasks, nextTaskId: nextTaskIdValue))
      return true
    }
    return false
  }

  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    let payload = localStore.load()
    var openTasks = payload.openTasks

    if let index = openTasks.firstIndex(where: { $0.id == taskId }) {
      let task = openTasks[index]
      openTasks[index] = rebuiltTask(task, parentId: parentId)
      localStore.save(
        OfflineTaskStorePayload(
          openTasks: openTasks, archivedTasks: payload.archivedTasks, nextTaskId: nextTaskIdValue))
      return true
    }
    return false
  }

  func persistTaskCache(listId: String, tasks: [CheckvistTask]) {}
  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? { return nil }
  func isTaskCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool { return true }

  private func rebuiltTask(
    _ task: CheckvistTask,
    content: String? = nil,
    status: Int? = nil,
    due: String? = nil,
    position: Int? = nil,
    parentId: Int? = nil
  ) -> CheckvistTask {
    CheckvistTask(
      id: task.id,
      content: content ?? task.content,
      status: status ?? task.status,
      due: due ?? task.due,
      position: position ?? task.position,
      parentId: parentId ?? task.parentId,
      level: task.level,
      notes: task.notes,
      updatedAt: task.updatedAt
    )
  }

  private func getDescendantIds(for parentId: Int, in tasks: [CheckvistTask]) -> Set<Int> {
    var ids = Set<Int>()
    let children = tasks.filter { $0.parentId == parentId }
    for child in children {
      ids.insert(child.id)
      ids.formUnion(getDescendantIds(for: child.id, in: tasks))
    }
    return ids
  }

  private func normalizeOfflineTasks(_ flatTasks: [CheckvistTask]) -> [CheckvistTask] {
    guard !flatTasks.isEmpty else { return [] }
    let taskById = Dictionary(uniqueKeysWithValues: flatTasks.map { ($0.id, $0) })
    var childrenByParent: [Int: [(index: Int, task: CheckvistTask)]] = [:]

    for (index, task) in flatTasks.enumerated() {
      let parentId = task.parentId ?? 0
      childrenByParent[parentId, default: []].append((index: index, task: task))
    }

    func orderedChildren(for parentId: Int) -> [(index: Int, task: CheckvistTask)] {
      childrenByParent[parentId, default: []].sorted { lhs, rhs in
        let lhsPosition = lhs.task.position ?? Int.max
        let rhsPosition = rhs.task.position ?? Int.max
        if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
        return lhs.index < rhs.index
      }
    }

    var normalized: [CheckvistTask] = []

    func appendChildren(of parentId: Int, level: Int) {
      let children = orderedChildren(for: parentId)
      for (offset, entry) in children.enumerated() {
        let task = rebuiltTask(
          entry.task,
          position: offset + 1
        )
        let finalTask = CheckvistTask(
          id: task.id, content: task.content, status: task.status, due: task.due,
          position: task.position, parentId: parentId == 0 ? nil : parentId, level: level,
          notes: task.notes, updatedAt: task.updatedAt)
        normalized.append(finalTask)
        appendChildren(of: task.id, level: level + 1)
      }
    }

    let missingParentIds = Set(flatTasks.compactMap { $0.parentId }.filter { taskById[$0] == nil })
    let rootParentIds = Set([0]).union(missingParentIds).sorted()

    for rootId in rootParentIds {
      appendChildren(of: rootId, level: 0)
    }

    return normalized
  }
}
