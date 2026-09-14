import Foundation
import Observation
import PriorityWorkspace

/// Presentation state for the desktop-only local workspace. The menu bar and
/// its Checkvist compatibility panel deliberately do not read this state.
@MainActor
@Observable final class WorkspaceViewModel {
  private static let legacyMigrationKey = "localWorkspaceMigratedOfflineTasksV1"

  @ObservationIgnored private var store: WorkspaceStore?
  @ObservationIgnored private let legacyStore: LocalTaskStore

  private(set) var workspace: Workspace?
  private(set) var folders: [ListFolder] = []
  private(set) var lists: [TaskList] = []
  private(set) var outline: [TaskOutlineItem] = []
  var selectedListID: String?
  var scopeTaskID: String?
  var selectedTaskID: String?
  var showsFocusPanel = false
  private(set) var activeFocusSession: FocusSession?
  private(set) var focusQueue: [FocusQueueTask] = []
  var errorMessage: String?

  init(legacyStore: LocalTaskStore) {
    self.legacyStore = legacyStore
    do {
      self.store = try WorkspaceStore()
      try load()
    } catch {
      self.store = nil
      self.errorMessage = error.localizedDescription
    }
  }

  var selectedList: TaskList? { lists.first { $0.id == selectedListID } }

  var scopeTask: WorkspaceTask? {
    guard let scopeTaskID, let store else { return nil }
    return try? store.task(id: scopeTaskID)
  }

  var selectedTask: WorkspaceTask? {
    guard let selectedTaskID, let store else { return nil }
    return try? store.task(id: selectedTaskID)
  }

  var activeFocusTask: WorkspaceTask? {
    guard let taskID = activeFocusSession?.activeTaskId, let store else { return nil }
    return try? store.task(id: taskID)
  }

  func load() throws {
    guard let store else { return }
    let workspace = try store.bootstrapIfNeeded()
    self.workspace = workspace
    try migrateLegacyTasksIfNeeded(into: workspace, store: store)
    folders = try store.folders(in: workspace.id)
    lists = try store.lists(in: workspace.id)
    if selectedListID == nil || !lists.contains(where: { $0.id == selectedListID }) {
      selectedListID = lists.first?.id
    }
    reloadOutline()
    reloadFocus()
  }

  func selectList(_ id: String) {
    selectedListID = id
    scopeTaskID = nil
    selectedTaskID = nil
    reloadOutline()
  }

  func enterTask(_ task: WorkspaceTask) {
    scopeTaskID = task.id
    reloadOutline()
  }

  func selectTask(_ task: WorkspaceTask) {
    selectedTaskID = task.id
  }

  func leaveTaskScope() {
    guard let task = scopeTask else { return }
    scopeTaskID = task.parentTaskId
    reloadOutline()
  }

  func createList(named name: String) {
    guard let store, let workspace else { return }
    do {
      let list = try store.createList(workspaceId: workspace.id, name: name)
      try load()
      selectedListID = list.id
      reloadOutline()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createFolder(named name: String) {
    guard let store, let workspace else { return }
    perform {
      _ = try store.createFolder(workspaceId: workspace.id, name: name)
      try load()
    }
  }

  func createTask(named title: String) {
    guard let store, let selectedListID else { return }
    perform {
      _ = try store.createTask(listId: selectedListID, title: title, parentTaskId: scopeTaskID)
      reloadOutline()
    }
  }

  func toggleTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setStatus(task.status == .open ? .completed : .open, for: task.id)
      reloadOutline()
    }
  }

  func updateTask(_ task: WorkspaceTask, title: String, notes: String) {
    guard let store else { return }
    perform {
      try store.updateTask(
        id: task.id, title: title, notes: notes, dueAt: task.dueAt,
        estimateSeconds: task.estimateSeconds)
      reloadOutline()
    }
  }

  func startFocus(on task: WorkspaceTask) {
    guard let store else { return }
    perform {
      activeFocusSession = try store.startFocusSession(taskId: task.id)
      reloadFocus()
      showsFocusPanel = true
    }
  }

  func addToFocusQueue(_ task: WorkspaceTask) {
    guard let store, let session = activeFocusSession else { return }
    perform {
      try store.addToFocusQueue(sessionId: session.id, taskId: task.id)
      reloadFocus()
    }
  }

  func completeFocusedTask() {
    guard let store, let session = activeFocusSession else { return }
    perform {
      activeFocusSession = try store.completeActiveFocusTask(sessionId: session.id)
      reloadFocus()
      reloadOutline()
    }
  }

  func finishFocus() {
    guard let store, let session = activeFocusSession else { return }
    perform {
      try store.finishFocusSession(id: session.id)
      reloadFocus()
      showsFocusPanel = false
    }
  }

  private func reloadOutline() {
    guard let store, let selectedListID else {
      outline = []
      return
    }
    do {
      outline = try store.outline(in: selectedListID, parentTaskId: scopeTaskID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func reloadFocus() {
    guard let store else { return }
    do {
      activeFocusSession = try store.activeFocusSession()
      if let session = activeFocusSession {
        focusQueue = try store.focusQueue(for: session.id)
      } else {
        focusQueue = []
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func perform(_ work: () throws -> Void) {
    do {
      try work()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func migrateLegacyTasksIfNeeded(into workspace: Workspace, store: WorkspaceStore) throws {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return }
    let payload = legacyStore.load()
    let legacyTasks = payload.openTasks + payload.archivedTasks
    guard !legacyTasks.isEmpty else {
      defaults.set(true, forKey: Self.legacyMigrationKey)
      return
    }

    let uniqueTasks = Dictionary(legacyTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let seeds = uniqueTasks.values.sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map { task in
      LegacyTaskSeed(
        sourceId: String(task.id),
        parentSourceId: task.parentId.map(String.init),
        title: task.content,
        notes: task.notes?.map(\.content).joined(separator: "\n\n") ?? "",
        status: task.status == 0 ? .open : (task.status == 1 ? .completed : .cancelled),
        sortOrder: task.position ?? 0)
    }
    let date = ISO8601DateFormatter().string(from: .now).prefix(10)
    _ = try store.importLegacyTasks(
      workspaceId: workspace.id, listName: "Imported from old Priority — \(date)", seeds: seeds)
    defaults.set(true, forKey: Self.legacyMigrationKey)
  }
}
