import Foundation
import Observation
import PriorityWorkspace

/// Presentation state for the desktop-only local workspace. The menu bar and
/// its Checkvist compatibility panel deliberately do not read this state.
@MainActor
@Observable final class WorkspaceViewModel {
  private static let legacyMigrationKey = "localWorkspaceMigratedOfflineTasksV1"
  private static let checkvistMigrationKeysKey = "localWorkspaceMigratedCheckvistListIDsV1"

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
    let importedList = try migrateLegacyTasksIfNeeded(into: workspace, store: store)
    folders = try store.folders(in: workspace.id)
    lists = try store.lists(in: workspace.id)
    if selectedListID == nil || !lists.contains(where: { $0.id == selectedListID }) {
      // On the first desktop launch, put a migrated user straight into their
      // existing work rather than an empty Inbox. This also covers people who
      // ran an earlier preview that completed the import before the desktop
      // window became the default launch surface.
      selectedListID = importedList?.id
        ?? lists.first(where: { $0.name.hasPrefix("Imported from old Priority") })?.id
        ?? lists.first?.id
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

  /// Imports a loaded legacy Checkvist list once. This is deliberately a copy:
  /// once migration completes, the workspace is fully local and never needs
  /// Checkvist in order to open or edit these tasks.
  func importLegacyCheckvistTasks(_ tasks: [CheckvistTask], sourceListID: String) {
    guard let store, let workspace else { return }
    let listID = sourceListID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !listID.isEmpty, !tasks.isEmpty else { return }

    let defaults = UserDefaults.standard
    var migratedListIDs = Set(defaults.stringArray(forKey: Self.checkvistMigrationKeysKey) ?? [])
    guard !migratedListIDs.contains(listID) else { return }

    let uniqueTasks = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let sourcePrefix = "checkvist:\(listID):"
    let seeds = uniqueTasks.values.sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map { task in
      LegacyTaskSeed(
        sourceId: "\(sourcePrefix)\(task.id)",
        parentSourceId: task.parentId.map { "\(sourcePrefix)\($0)" },
        title: task.content,
        notes: task.notes?.map(\.content).joined(separator: "\n\n") ?? "",
        status: task.status == 0 ? .open : (task.status == 1 ? .completed : .cancelled),
        sortOrder: task.position ?? 0)
    }

    do {
      let importedList = try store.importLegacyTasks(
        workspaceId: workspace.id,
        listName: "Imported from Checkvist — \(listID)",
        seeds: seeds)
      migratedListIDs.insert(listID)
      defaults.set(Array(migratedListIDs).sorted(), forKey: Self.checkvistMigrationKeysKey)
      try load()
      if let importedList {
        selectedListID = importedList.id
        reloadOutline()
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
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

  @discardableResult
  private func migrateLegacyTasksIfNeeded(into workspace: Workspace, store: WorkspaceStore) throws -> TaskList? {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return nil }
    let payload = legacyStore.load()
    let legacyTasks = payload.openTasks + payload.archivedTasks
    guard !legacyTasks.isEmpty else {
      defaults.set(true, forKey: Self.legacyMigrationKey)
      return nil
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
    let importedList = try store.importLegacyTasks(
      workspaceId: workspace.id, listName: "Imported from old Priority — \(date)", seeds: seeds)
    defaults.set(true, forKey: Self.legacyMigrationKey)
    return importedList
  }
}
