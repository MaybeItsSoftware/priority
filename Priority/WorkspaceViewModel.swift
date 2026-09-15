import AppKit
import Foundation
import Observation
import PriorityCore
import PriorityWorkspace

enum WorkspaceCreationKind: String, Identifiable {
  case list
  case folder

  var id: String { rawValue }
  var title: String { self == .list ? "New list" : "New folder" }
}

/// The three persistent regions of the desktop window. Keeping this state in
/// the model lets the AppKit key monitor and the SwiftUI focus system agree on
/// where a shortcut belongs.
enum WorkspaceFocusArea: Hashable {
  case sidebar
  case tasks
  case inspector
}

/// Views of the same local task model, rather than separate applications.
enum WorkspaceViewMode: String, CaseIterable, Identifiable {
  case board
  case outline
  case dailies
  case matrix
  case focus

  /// Planning projections live beside the current list. Focus is an action
  /// on the Today queue, not a top-level place to navigate to.
  static let planningModes: [WorkspaceViewMode] = [.board, .outline, .dailies, .matrix]

  var id: String { rawValue }
  var title: String {
    switch self {
    case .board: "Board"
    case .outline: "Outline"
    case .dailies: "Dailies"
    case .matrix: "Matrix"
    case .focus: "Focus"
    }
  }

  var symbolName: String {
    switch self {
    case .board: "rectangle.split.3x1"
    case .outline: "list.bullet.indent"
    case .dailies: "checklist"
    case .matrix: "square.grid.2x2"
    case .focus: "timer"
    }
  }
}

enum WorkspaceSidebarEditor: Identifiable {
  case list(TaskList)
  case folder(ListFolder)

  var id: String {
    switch self {
    case .list(let list): "list-\(list.id)"
    case .folder(let folder): "folder-\(folder.id)"
    }
  }
}

enum WorkspaceSidebarItem: Identifiable {
  case list(TaskList)
  case folder(ListFolder)

  var id: String {
    switch self {
    case .list(let list): "list-\(list.id)"
    case .folder(let folder): "folder-\(folder.id)"
    }
  }

  var deletionTitle: String {
    switch self {
    case .list(let list): "Delete \(list.name)?"
    case .folder(let folder): "Delete \(folder.name)?"
    }
  }

  var deletionMessage: String {
    switch self {
    case .list: "This permanently deletes the list and all of its tasks."
    case .folder: "Lists remain, but move to the sidebar root. Nested folders are deleted."
    }
  }
}

/// Presentation state for the desktop-only local workspace. The menu bar and
/// its Checkvist compatibility panel deliberately do not read this state.
@MainActor
@Observable final class WorkspaceViewModel {
  private static let legacyMigrationKey = "localWorkspaceMigratedOfflineTasksV1"
  private static let checkvistMigrationKeysKey = "localWorkspaceMigratedCheckvistListIDsV1"
  private static let checkvistWorkspaceListIDsKey = "localWorkspaceCheckvistListIDsV1"
  private static let kanbanColumnsKey = "localWorkspaceKanbanColumnsV1"
  /// Read once by `migrateLegacyDailiesIfNeeded`, never written again.
  private static let dailyProgressTaskIDsKey = "localWorkspaceDailyProgressTaskIDsV1"
  private static let dailyMigrationKey = "localWorkspaceMigratedDailiesV1"
  private static let everythingScopeKey = "localWorkspaceEverythingScopeV1"

  /// Internal rather than private so `WorkspaceViewModel+Dailies.swift` —
  /// the same type, split only for size — can reach it.
  @ObservationIgnored var store: WorkspaceStore?
  @ObservationIgnored private let legacyStore: LocalTaskStore

  private(set) var workspace: Workspace?
  private(set) var folders: [ListFolder] = []
  private(set) var lists: [TaskList] = []
  private(set) var archivedLists: [TaskList] = []
  private(set) var outline: [TaskOutlineItem] = []
  private(set) var boardTasks: [WorkspaceTask] = []
  private(set) var boardCrossColumnTasks: [WorkspaceTask] = []
  private(set) var boardDescendants: [String: [TaskOutlineItem]] = [:]
  private(set) var boardTaskParents: [String: WorkspaceTask] = [:]
  /// The actual parent whose children are visible on the board. A Checkvist
  /// import can contain one root project whose title is identical to its list;
  /// that project is a transport wrapper, not useful work to show as the
  /// board's only card.
  private(set) var boardParentTaskID: String?
  private(set) var boardColumns: [WorkspaceKanbanColumn] = WorkspaceKanbanColumn.blitzitDefaults
  private(set) var boardTaskColumns: [String: String] = [:]
  private(set) var matrixPositions: [String: TaskMatrixPosition] = [:]
  var viewMode: WorkspaceViewMode = .board
  /// Virtual parent of every active list. The tasks remain stored in their
  /// own lists; this flag only changes which roots the views present.
  var isEverythingSelected = UserDefaults.standard.bool(forKey: WorkspaceViewModel.everythingScopeKey)
  var newTaskListID: String?
  var newKanbanColumnRequest = false
  var dailyProgressRevision = 0
  var selectedListID: String?
  var selectedFolderID: String?
  var expandedFolderIDs: Set<String> = []
  var scopeTaskID: String?
  var selectedTaskID: String?
  var isInspectorVisible = false
  var taskMoveRequest: WorkspaceTask?
  var dragDestinationListID: String?
  var showsFocusPanel = false
  /// Requests the always-on-top companion without coupling focus to a sheet.
  var focusFloatRequest = 0
  var showsKeyboardHelp = false
  var creationRequest: WorkspaceCreationKind?
  var creationParentFolderID: String?
  var sidebarEditor: WorkspaceSidebarEditor?
  var pendingSidebarDeletion: WorkspaceSidebarItem?
  var taskComposerFocusRequest = 0
  private(set) var keyboardFocusArea: WorkspaceFocusArea = .tasks
  private(set) var requestedFocusArea: WorkspaceFocusArea = .tasks
  /// Plain navigation keys only belong to the focused list/board surface.
  /// Buttons, menus, and other controls keep their native keyboard behavior.
  private(set) var keyboardNavigationSurfaceActive = false
  /// Incremented for every request, including a request for the already active
  /// region. SwiftUI observes this to make the native control first responder.
  var focusRequest = 0
  var activeFocusSession: FocusSession?
  private(set) var focusQueue: [FocusQueueTask] = []
  @ObservationIgnored var dailyTaskIDs: Set<String> = []
  /// The focus screen: one task, an estimate, and a way out. Presented over
  /// the workspace rather than as a view mode, because its whole job is to
  /// hide everything else.
  /// What finishing the current block did — a task closed, or a day's
  /// contribution logged. Held so the UI can say which, then cleared.
  var lastFocusOutcome: WorkspaceStore.FocusCompletionOutcome?

  var showsFocusScreen = false
  /// Minutes offered on the focus screen, seeded from the task's estimate.
  var focusEstimateMinutes = 25
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
  var selectedFolder: ListFolder? { folders.first { $0.id == selectedFolderID } }
  func list(for task: WorkspaceTask) -> TaskList? { lists.first { $0.id == task.listId } }

  var scopeTask: WorkspaceTask? {
    guard let scopeTaskID, let store else { return nil }
    return try? store.task(id: scopeTaskID)
  }

  /// Resolves a local drag payload only through the workspace store. A drop
  /// target never trusts an arbitrary identifier from outside the workspace.
  func task(withID id: String) -> WorkspaceTask? {
    guard let store else { return nil }
    return try? store.task(id: id)
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
    archivedLists = try store.lists(in: workspace.id, includingArchived: true).filter(\.isArchived)
    if isEverythingSelected {
      selectedListID = nil
      scopeTaskID = nil
    }
    if !isEverythingSelected && (selectedListID == nil || !lists.contains(where: { $0.id == selectedListID })) {
      // On the first desktop launch, put a migrated user straight into their
      // existing work rather than an empty Inbox. This also covers people who
      // ran an earlier preview that completed the import before the desktop
      // window became the default launch surface.
      selectedListID = importedList?.id
        ?? lists.first(where: { $0.name.hasPrefix("Imported from old Priority") })?.id
        ?? lists.first?.id
      if selectedList?.name.caseInsensitiveCompare("Inbox") == .orderedSame {
        viewMode = .outline
      }
    }
    if newTaskListID == nil || !lists.contains(where: { $0.id == newTaskListID }) {
      newTaskListID = selectedListID ?? lists.first?.id
    }
    try migrateLegacyDailiesIfNeeded(store: store)
    reloadOutline()
    reloadFocus()
    reloadDailies()
    reloadNextUp()
  }

  /// Brings both kinds of pre-existing daily into the new model, once.
  ///
  /// Plugin-era dailies stood alone; they become tasks in a Habits list with a
  /// daily attached. Tasks flagged under the old UserDefaults scheme keep their
  /// task and simply gain one. The old tick history is not carried over — it
  /// recorded that a day was ticked, not what was done, and the new schema's
  /// per-day rows would be inventing the second half.
  private func migrateLegacyDailiesIfNeeded(store: WorkspaceStore) throws {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.dailyMigrationKey) else { return }
    let seeds = legacyDailyDefinitions().map { daily in
      LegacyDailySeed(
        id: daily.id,
        title: daily.title,
        activeWeekdays: daily.activeWeekdays,
        intervalDays: daily.intervalDays,
        intervalAnchor: daily.intervalAnchor,
        archivedAt: daily.archivedAt,
        createdAt: daily.createdAt)
    }
    let progressIDs = defaults.stringArray(forKey: Self.dailyProgressTaskIDsKey) ?? []
    try store.importLegacyDailies(seeds, progressTaskIDs: progressIDs)
    defaults.set(true, forKey: Self.dailyMigrationKey)
  }

  /// Reads the plugin's own file through the plugin's own path, rather than
  /// rebuilding it here — `DailyLogService` documents that resolving it twice
  /// is two chances to disagree about where the history lives.
  private func legacyDailyDefinitions() -> [Daily] {
    DailyDefinitionsStore(directoryURL: DailyLogService.defaultStoreDirectoryURL()).load().dailies
  }

  func selectList(_ id: String) {
    guard lists.contains(where: { $0.id == id }) else { return }
    isEverythingSelected = false
    UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
    selectedListID = id
    newTaskListID = id
    selectedFolderID = nil
    scopeTaskID = nil
    selectedTaskID = nil
    isInspectorVisible = false
    viewMode = lists.first(where: { $0.id == id })?.name.caseInsensitiveCompare("Inbox") == .orderedSame
      ? .outline : .board
    reloadOutline()
  }

  func selectEverything() {
    if let selectedListID { newTaskListID = selectedListID }
    isEverythingSelected = true
    UserDefaults.standard.set(true, forKey: Self.everythingScopeKey)
    selectedListID = nil
    selectedFolderID = nil
    scopeTaskID = nil
    selectedTaskID = nil
    isInspectorVisible = false
    viewMode = .board
    reloadOutline()
  }

  func selectFolder(_ folder: ListFolder) {
    selectedFolderID = folder.id
    selectedTaskID = nil
    isInspectorVisible = false
  }

  func enterTask(_ task: WorkspaceTask) {
    if isEverythingSelected {
      isEverythingSelected = false
      UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
      selectedListID = task.listId
      newTaskListID = task.listId
    }
    scopeTaskID = task.id
    isInspectorVisible = false
    viewMode = .board
    reloadOutline()
  }

  func selectTask(_ task: WorkspaceTask) {
    selectedTaskID = task.id
  }

  func selectViewMode(_ mode: WorkspaceViewMode) {
    viewMode = mode
    if isEverythingSelected { reloadOutline() }
    if mode == .focus, activeFocusSession == nil, let task = selectedTask {
      startFocus(on: task)
    }
  }

  func leaveTaskScope() {
    guard let task = scopeTask else { return }
    scopeTaskID = task.parentTaskId
    selectedTaskID = task.id
    reloadOutline()
  }

  func requestTaskComposerFocus() {
    requestKeyboardFocus(.tasks)
    taskComposerFocusRequest += 1
  }

  func requestKeyboardFocus(_ area: WorkspaceFocusArea) {
    if area == .inspector { isInspectorVisible = true }
    requestedFocusArea = area
    keyboardFocusArea = area
    focusRequest += 1
  }

  func reportKeyboardFocus(_ area: WorkspaceFocusArea?) {
    keyboardNavigationSurfaceActive = area != nil
    if let area { keyboardFocusArea = area }
  }

  func toggleInspector() {
    if isInspectorVisible {
      isInspectorVisible = false
      requestKeyboardFocus(.tasks)
    } else {
      if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
      guard selectedTask != nil else { return }
      requestKeyboardFocus(.inspector)
    }
  }

  func requestMoveSelectedTask() {
    if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
    guard let task = selectedTask,
      lists.contains(where: { $0.id != task.listId })
    else { return }
    taskMoveRequest = task
  }

  func cycleKeyboardFocus(by offset: Int) {
    let areas: [WorkspaceFocusArea] = selectedTask == nil || !isInspectorVisible
      ? [.sidebar, .tasks] : [.sidebar, .tasks, .inspector]
    let current = areas.firstIndex(of: keyboardFocusArea) ?? 0
    let destination = (current + offset + areas.count) % areas.count
    requestKeyboardFocus(areas[destination])
  }

  func requestCreation(_ kind: WorkspaceCreationKind, in parentFolderID: String? = nil) {
    creationParentFolderID = parentFolderID
    creationRequest = kind
  }

  func requestListCreationForSelection() {
    requestCreation(.list, in: selectedFolderID)
  }

  func requestFolderCreationForSelection() {
    requestCreation(.folder, in: selectedFolderID)
  }


  func createList(named name: String, in folderId: String? = nil) {
    guard let store, let workspace else { return }
    do {
      let list = try store.createList(workspaceId: workspace.id, name: name, folderId: folderId)
      try load()
      isEverythingSelected = false
      UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
      selectedListID = list.id
      newTaskListID = list.id
      reloadOutline()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createFolder(named name: String, in parentFolderId: String? = nil) {
    guard let store, let workspace else { return }
    perform {
      _ = try store.createFolder(workspaceId: workspace.id, name: name, parentFolderId: parentFolderId)
      try load()
    }
  }

  func isFolderExpanded(_ folder: ListFolder) -> Bool {
    expandedFolderIDs.contains(folder.id)
  }

  func setFolderExpanded(_ folder: ListFolder, expanded: Bool) {
    if expanded {
      expandedFolderIDs.insert(folder.id)
    } else {
      expandedFolderIDs.remove(folder.id)
    }
  }

  func toggleFolderExpansion(_ folder: ListFolder) {
    setFolderExpanded(folder, expanded: !isFolderExpanded(folder))
  }

  func createTask(named title: String) {
    guard let store,
      let destinationID = isEverythingSelected ? newTaskListID : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return }
    perform {
      let parentID = isEverythingSelected
        ? try visibleRootParentTaskID(for: destinationList, store: store) : scopeTaskID
      _ = try store.createTask(listId: destinationID, title: title, parentTaskId: parentID)
      reloadOutline()
    }
  }

  /// Creates work in the currently visible board scope. This differs from the
  /// outline only for a transparent imported root project (see
  /// `boardParentTaskID`), where a new card belongs alongside the visible
  /// children rather than appearing above them as a second wrapper.
  func createBoardTask(named title: String, in column: WorkspaceKanbanColumn? = nil, atTop: Bool = false) {
    guard let store,
      let destinationID = isEverythingSelected ? newTaskListID : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return }
    perform {
      let parentID = isEverythingSelected
        ? try visibleRootParentTaskID(for: destinationList, store: store) : boardParentTaskID
      let task = try store.createTask(listId: destinationID, title: title, parentTaskId: parentID)
      if let column { try store.setKanbanColumn(column.id, for: task.id) }
      if atTop { try store.moveTaskToStart(id: task.id) }
      reloadOutline()
    }
  }

  func createSubtask(named title: String, under parent: WorkspaceTask) {
    guard let store else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    perform {
      _ = try store.createTask(listId: parent.listId, title: trimmed, parentTaskId: parent.id)
      reloadOutline()
    }
  }

  func descendants(of task: WorkspaceTask) -> [TaskOutlineItem] {
    if let cached = boardDescendants[task.id] { return cached }
    guard let store else { return [] }
    return (try? store.outline(in: task.listId, parentTaskId: task.id)) ?? []
  }

  func boardParent(of task: WorkspaceTask) -> WorkspaceTask? {
    boardTaskParents[task.id]
  }

  var currentBoardScopeTitle: String {
    if isEverythingSelected { return "Everything" }
    return scopeTask?.title ?? selectedList?.name ?? "Board"
  }

  func tasks(in column: WorkspaceKanbanColumn) -> [WorkspaceTask] {
    (boardTasks + boardCrossColumnTasks).filter { self.column(for: $0)?.id == column.id }
  }

  var todayTasks: [WorkspaceTask] {
    guard let today = boardColumns.first(where: { $0.id == "today" }) else { return [] }
    return tasks(in: today).filter { $0.status == .open }
  }

  func isTaskVisibleOnBoard(_ task: WorkspaceTask) -> Bool {
    (boardTasks + boardCrossColumnTasks).contains { $0.id == task.id }
  }

  func column(for task: WorkspaceTask) -> WorkspaceKanbanColumn? {
    let id = boardTaskColumns[task.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
    return boardColumns.first { $0.id == id } ?? boardColumns.first
  }

  func moveTask(_ task: WorkspaceTask, toKanbanColumn column: WorkspaceKanbanColumn) {
    guard let store else { return }
    perform {
      try store.setKanbanColumn(column.id, for: task.id)
      reloadBoard()
    }
  }

  func placeTask(_ task: WorkspaceTask, before target: WorkspaceTask) {
    guard let store, task.id != target.id else { return }
    guard task.listId == target.listId, task.parentTaskId == target.parentTaskId else {
      errorMessage = "To reorder these cards, they must be siblings in the same project. Drag to a column or list to move them."
      return
    }
    perform {
      if let column = column(for: target) { try store.setKanbanColumn(column.id, for: task.id) }
      try store.moveTaskBefore(id: task.id, targetId: target.id)
      reloadBoard()
    }
  }

  func addKanbanColumn(named name: String) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    var configurations = UserDefaults.standard.dictionary(forKey: Self.kanbanColumnsKey) as? [String: Data] ?? [:]
    var columns = boardColumns
    let baseID = title.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let id = uniqueColumnID(base: baseID.isEmpty ? "column" : baseID, in: columns)
    columns.append(WorkspaceKanbanColumn(id: id, title: title))
    configurations[boardConfigurationKey] = try? JSONEncoder().encode(columns)
    UserDefaults.standard.set(configurations, forKey: Self.kanbanColumnsKey)
    boardColumns = columns
  }

  func removeKanbanColumn(_ column: WorkspaceKanbanColumn) {
    guard boardColumns.count > 1 else { return }
    let fallback = boardColumns.first { $0.id != column.id } ?? WorkspaceKanbanColumn.blitzitDefaults[0]
    for task in tasks(in: column) { moveTask(task, toKanbanColumn: fallback) }
    var configurations = UserDefaults.standard.dictionary(forKey: Self.kanbanColumnsKey) as? [String: Data] ?? [:]
    let remaining = boardColumns.filter { $0.id != column.id }
    configurations[boardConfigurationKey] = try? JSONEncoder().encode(remaining)
    UserDefaults.standard.set(configurations, forKey: Self.kanbanColumnsKey)
    boardColumns = remaining
  }

  func matrixPosition(for task: WorkspaceTask) -> TaskMatrixPosition {
    matrixPositions[task.id] ?? TaskMatrixPosition(urgency: nil, importance: nil)
  }

  func setMatrixPosition(_ position: TaskMatrixPosition, for task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setMatrixPosition(position, for: task.id)
      reloadBoard()
    }
  }

  /// Today's dailies, joined to their tasks and contributions. Reloaded rather
  /// than computed, because every row needs a database round trip and the list
  /// is read on every render of the dailies surface.
  var dailyItems: [DailyItem] = []
  /// What the focus screen offers, and why. Nil when there is nothing to do —
  /// which is a real state worth rendering, not an error.
  var nextUp: ScoredNextUp?
  /// The runners-up, so "not that one" can be answered without leaving the
  /// screen. Deliberately short: a focus screen showing a backlog is a backlog.
  var nextUpAlternatives: [ScoredNextUp] = []
  /// Tasks passed over this sitting. Held in memory rather than persisted —
  /// skipping is a statement about right now, and should not survive a relaunch.
  @ObservationIgnored var skippedTaskIDs: Set<String> = []

  var visibleNavigationTasks: [WorkspaceTask] {
    switch viewMode {
    case .outline: outline.map(\.task)
    case .board: boardColumns.flatMap { tasks(in: $0) }
    case .dailies: dailyProgressTasks
    case .matrix: boardTasks
    case .focus:
      if let activeFocusTask { [activeFocusTask] + focusQueue.map(\.task) }
      else { selectedTask.map { [$0] } ?? [] }
    }
  }

  func moveTaskSelection(by offset: Int) {
    let visibleTasks = visibleNavigationTasks
    guard !visibleTasks.isEmpty else { return }
    guard let currentTaskID = selectedTaskID,
      let index = visibleTasks.firstIndex(where: { $0.id == currentTaskID })
    else {
      selectedTaskID = offset < 0 ? visibleTasks.last?.id : visibleTasks.first?.id
      return
    }
    selectedTaskID = visibleTasks[min(max(0, index + offset), visibleTasks.count - 1)].id
  }

  func selectAdjacentTask(by offset: Int) {
    moveTaskSelection(by: offset)
  }

  func selectTaskInAdjacentColumn(from task: WorkspaceTask, by offset: Int) {
    guard viewMode == .board, let current = column(for: task),
      let index = boardColumns.firstIndex(where: { $0.id == current.id })
    else { return }
    var destination = index + offset
    while boardColumns.indices.contains(destination) {
      if let nextTask = tasks(in: boardColumns[destination]).first {
        selectedTaskID = nextTask.id
        return
      }
      destination += offset
    }
  }

  func moveTaskToAdjacentColumn(_ task: WorkspaceTask, by offset: Int) {
    guard viewMode == .board, isTaskVisibleOnBoard(task), let column = column(for: task),
      let index = boardColumns.firstIndex(where: { $0.id == column.id })
    else { return }
    let destination = min(max(0, index + offset), boardColumns.count - 1)
    guard destination != index else { return }
    moveTask(task, toKanbanColumn: boardColumns[destination])
  }

  func moveSelectedTaskToAdjacentColumn(by offset: Int) {
    guard let task = selectedTask else { return }
    moveTaskToAdjacentColumn(task, by: offset)
  }

  func moveListSelection(by offset: Int) {
    guard !lists.isEmpty else { return }
    if isEverythingSelected {
      if offset > 0 { selectList(lists[0].id) }
      return
    }
    guard let selectedListID, let index = lists.firstIndex(where: { $0.id == selectedListID }) else {
      selectEverything()
      return
    }
    if index + offset < 0 {
      selectEverything()
    } else {
      selectList(lists[min(index + offset, lists.count - 1)].id)
    }
  }

  func cycleNewTaskDestination(by offset: Int) {
    guard isEverythingSelected, !lists.isEmpty else { return }
    let current = lists.firstIndex { $0.id == newTaskListID } ?? 0
    newTaskListID = lists[min(max(0, current + offset), lists.count - 1)].id
  }

  func moveFolderSelection(by offset: Int) {
    let ordered = orderedFolders
    guard !ordered.isEmpty else { return }
    guard let selectedFolderID, let index = ordered.firstIndex(where: { $0.id == selectedFolderID }) else {
      selectFolder(ordered.first!)
      return
    }
    selectFolder(ordered[min(max(0, index + offset), ordered.count - 1)])
  }

  private enum SidebarNavigationTarget: Equatable {
    case everything
    case list(String)
    case folder(String)
  }

  /// Mirrors the visible sidebar order: each folder, its immediate lists,
  /// nested folders, then the ungrouped section. This gives folders the same
  /// first-class arrow-key navigation as lists.
  private var sidebarNavigationTargets: [SidebarNavigationTarget] {
    var result: [SidebarNavigationTarget] = [.everything]
    var visited = Set<String>()
    func appendFolder(_ folder: ListFolder) {
      guard visited.insert(folder.id).inserted else { return }
      result.append(.folder(folder.id))
      guard expandedFolderIDs.contains(folder.id) else { return }
      for list in lists where list.folderId == folder.id {
        result.append(.list(list.id))
      }
      for child in folders where child.parentFolderId == folder.id {
        appendFolder(child)
      }
    }
    for folder in folders where folder.parentFolderId == nil { appendFolder(folder) }
    for list in lists where list.folderId == nil { result.append(.list(list.id)) }
    return result
  }

  func moveSidebarSelection(by offset: Int) {
    let targets = sidebarNavigationTargets
    guard !targets.isEmpty else { return }
    let current: SidebarNavigationTarget? = if let selectedFolderID {
      .folder(selectedFolderID)
    } else if isEverythingSelected {
      .everything
    } else if let selectedListID {
      .list(selectedListID)
    } else {
      nil
    }
    let index = current.flatMap { targets.firstIndex(of: $0) }
      ?? (offset < 0 ? targets.count : -1)
    let target = targets[min(max(0, index + offset), targets.count - 1)]
    switch target {
    case .everything: selectEverything()
    case .list(let id): selectList(id)
    case .folder(let id):
      if let folder = folders.first(where: { $0.id == id }) { selectFolder(folder) }
    }
  }

  private var orderedFolders: [ListFolder] {
    var result: [ListFolder] = []
    var visited = Set<String>()
    func appendChildren(of parentID: String?) {
      for folder in folders where folder.parentFolderId == parentID && visited.insert(folder.id).inserted {
        result.append(folder)
        appendChildren(of: folder.id)
      }
    }
    appendChildren(of: nil)
    return result
  }

  func enterSelectedTask() {
    guard let task = selectedTask else { return }
    enterTask(task)
    selectedTaskID = nil
  }

  func leaveSelectedTaskScope() {
    if scopeTaskID != nil {
      leaveTaskScope()
    } else if selectedTaskID == nil && !isEverythingSelected {
      selectEverything()
    } else {
      selectedTaskID = nil
      isInspectorVisible = false
    }
  }

  func toggleSelectedTask() {
    guard let task = selectedTask else { return }
    toggleTask(task)
  }

  func focusSelectedTask() {
    guard let task = selectedTask else { return }
    if activeFocusSession == nil {
      startFocus(on: task)
    } else {
      addToFocusQueue(task)
    }
  }

  func dismissKeyboardContext() {
    if showsKeyboardHelp {
      showsKeyboardHelp = false
    } else if isInspectorVisible {
      isInspectorVisible = false
      requestKeyboardFocus(.tasks)
    } else if scopeTaskID != nil {
      leaveTaskScope()
    } else {
      selectedTaskID = nil
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
    updateTask(task, title: title, notes: notes, dueAt: task.dueAt, estimateSeconds: task.estimateSeconds)
  }

  func updateTask(
    _ task: WorkspaceTask,
    title: String,
    notes: String,
    dueAt: Date?,
    estimateSeconds: Int?
  ) {
    guard let store else { return }
    perform {
      try store.updateTask(
        id: task.id, title: title, notes: notes, dueAt: dueAt, estimateSeconds: estimateSeconds)
      reloadOutline()
    }
  }

  func taskEditorMetadata(for task: WorkspaceTask) -> TaskEditorMetadata {
    guard let store else { return TaskEditorMetadata() }
    return (try? store.taskEditorMetadata(for: task.id)) ?? TaskEditorMetadata()
  }

  func updateTask(
    _ task: WorkspaceTask,
    title: String,
    notes: String,
    dueAt: Date?,
    estimateSeconds: Int?,
    metadata: TaskEditorMetadata
  ) {
    guard let store else { return }
    perform {
      try store.updateTask(
        id: task.id, title: title, notes: notes, dueAt: dueAt, estimateSeconds: estimateSeconds)
      try store.updateTaskEditorMetadata(taskId: task.id, metadata: metadata)
      reloadOutline()
    }
  }

  func moveTask(_ task: WorkspaceTask, toListId listId: String) {
    guard let store else { return }
    perform {
      try store.moveTask(id: task.id, toListId: listId)
      if isEverythingSelected || task.listId == selectedListID || listId == selectedListID {
        reloadOutline()
      }
      selectedTaskID = isEverythingSelected || listId == selectedListID ? task.id : nil
      if selectedTaskID == nil { isInspectorVisible = false }
    }
  }

  func moveTaskWithinSiblings(_ task: WorkspaceTask, by offset: Int) {
    guard let store else { return }
    perform {
      try store.moveTaskWithinSiblings(id: task.id, by: offset)
      reloadOutline()
    }
  }

  func indentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.indentTask(id: task.id)
      reloadOutline()
    }
  }

  func outdentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.outdentTask(id: task.id)
      reloadOutline()
    }
  }

  func deleteSelectedTask() {
    guard let store, let task = selectedTask else { return }
    perform {
      try store.deleteTask(id: task.id)
      selectedTaskID = nil
      isInspectorVisible = false
      if scopeTaskID == task.id { scopeTaskID = task.parentTaskId }
      reloadOutline()
      reloadFocus()
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
        selectList(importedList.id)
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Mirrors newly discovered Checkvist lists into the desktop sidebar once.
  ///
  /// The desktop workspace deliberately remains local-first: this creates a
  /// local copy of each remote list and its currently open task tree, rather
  /// than making sidebar edits unexpectedly mutate Checkvist. The persisted
  /// mapping prevents every app launch from adding another copy.
  func importCheckvistLists(_ snapshots: [(list: CheckvistList, tasks: [CheckvistTask])]) {
    guard let store, let workspace, !snapshots.isEmpty else { return }

    let defaults = UserDefaults.standard
    var localIDs = defaults.dictionary(forKey: Self.checkvistWorkspaceListIDsKey) as? [String: String] ?? [:]
    var changed = false

    do {
      for snapshot in snapshots {
        let remoteID = String(snapshot.list.id)
        if let localID = localIDs[remoteID], lists.contains(where: { $0.id == localID }) {
          continue
        }

        let sourcePrefix = "checkvist:\(remoteID):"
        let uniqueTasks = Dictionary(
          snapshot.tasks.map { ($0.id, $0) },
          uniquingKeysWith: { first, _ in first })
        let seeds = uniqueTasks.values.sorted { lhs, rhs in
          let lhsParent = lhs.parentId ?? 0
          let rhsParent = rhs.parentId ?? 0
          if lhsParent != rhsParent { return lhsParent < rhsParent }
          return (lhs.position ?? 0) < (rhs.position ?? 0)
        }.map { task in
          LegacyTaskSeed(
            sourceId: "\(sourcePrefix)\(task.id)",
            parentSourceId: task.parentId.map { "\(sourcePrefix)\($0)" },
            title: task.content,
            notes: task.notes?.map(\.content).joined(separator: "\n\n") ?? "",
            status: task.status == 0 ? .open : (task.status == 1 ? .completed : .cancelled),
            sortOrder: task.position ?? 0)
        }

        let localList: TaskList
        if seeds.isEmpty {
          localList = try store.createList(workspaceId: workspace.id, name: snapshot.list.name)
        } else if let imported = try store.importLegacyTasks(
          workspaceId: workspace.id, listName: snapshot.list.name, seeds: seeds)
        {
          localList = imported
        } else {
          continue
        }
        localIDs[remoteID] = localList.id
        changed = true
      }

      guard changed else { return }
      defaults.set(localIDs, forKey: Self.checkvistWorkspaceListIDsKey)
      try load()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadOutline() {
    guard let store else {
      outline = []
      boardTasks = []
      boardTaskColumns = [:]
      matrixPositions = [:]
      return
    }
    do {
      if isEverythingSelected {
        if viewMode == .outline {
          outline = try lists.flatMap { list in
            let parentID = try visibleRootParentTaskID(for: list, store: store)
            return try store.outline(in: list.id, parentTaskId: parentID)
          }
        } else {
          outline = []
        }
      } else if let selectedListID {
        outline = try store.outline(in: selectedListID, parentTaskId: scopeTaskID)
      } else {
        outline = []
      }
      reloadBoard()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var boardConfigurationKey: String {
    if isEverythingSelected { return "everything/root" }
    return "\(selectedListID ?? "none")/\(scopeTaskID ?? "root")"
  }

  private func reloadBoard() {
    guard let store else {
      boardTasks = []
      boardCrossColumnTasks = []
      boardDescendants = [:]
      boardTaskParents = [:]
      boardParentTaskID = nil
      return
    }
    do {
      if isEverythingSelected {
        boardParentTaskID = nil
        boardTasks = try workspace.map { try store.visibleRootTasks(in: $0.id) } ?? []
      } else if let selectedListID {
        let parentID: String?
        if let scopeTaskID {
          parentID = scopeTaskID
        } else if let list = selectedList {
          parentID = try visibleRootParentTaskID(for: list, store: store)
        } else {
          parentID = nil
        }
        boardParentTaskID = parentID
        boardTasks = try store.tasks(in: selectedListID, parentTaskId: parentID)
      } else {
        boardParentTaskID = nil
        boardTasks = []
      }
      let boardIDs = Set(boardTasks.map(\.id))
      var descendants: [String: [TaskOutlineItem]] = Dictionary(
        uniqueKeysWithValues: boardTasks.map { ($0.id, []) })
      var parents: [String: WorkspaceTask] = [:]
      for listID in Set(boardTasks.map(\.listId)) {
        var ancestors: [TaskOutlineItem] = []
        for item in try store.outline(in: listID) {
          while let last = ancestors.last, last.depth >= item.depth {
            ancestors.removeLast()
          }
          if let parent = ancestors.last?.task { parents[item.task.id] = parent }
          for ancestor in ancestors where boardIDs.contains(ancestor.id) {
            descendants[ancestor.id, default: []].append(
              TaskOutlineItem(task: item.task, depth: item.depth - ancestor.depth - 1))
          }
          ancestors.append(item)
        }
      }
      boardDescendants = descendants
      boardTaskParents = parents
      let boardTreeTasks = boardTasks + boardTasks.flatMap { root in
        descendants[root.id, default: []].map(\.task)
      }
      boardTaskColumns = Dictionary(uniqueKeysWithValues: boardTreeTasks.compactMap { task in
        (try? store.kanbanColumn(for: task.id)).map { (task.id, $0) }
      })
      boardCrossColumnTasks = boardTreeTasks.filter { task in
        guard !boardIDs.contains(task.id), let parent = parents[task.id] else { return false }
        let taskColumn = boardTaskColumns[task.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
        let parentColumn = boardTaskColumns[parent.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
        return taskColumn != parentColumn
      }
      let configurations = UserDefaults.standard.dictionary(forKey: Self.kanbanColumnsKey) as? [String: Data] ?? [:]
      var columns: [WorkspaceKanbanColumn]
      if let encoded = configurations[boardConfigurationKey],
        let decoded = try? JSONDecoder().decode([WorkspaceKanbanColumn].self, from: encoded), !decoded.isEmpty {
        columns = decoded
      } else {
        columns = WorkspaceKanbanColumn.blitzitDefaults
      }
      if isEverythingSelected {
        let usedColumnIDs = Set(boardTaskColumns.values)
        for list in lists {
          guard let encoded = configurations["\(list.id)/root"],
            let listColumns = try? JSONDecoder().decode([WorkspaceKanbanColumn].self, from: encoded)
          else { continue }
          for column in listColumns where usedColumnIDs.contains(column.id)
            && !columns.contains(where: { $0.id == column.id }) {
            columns.append(column)
          }
        }
      } else {
        let usedColumnIDs = Set(boardTaskColumns.values)
        let globalColumns = configurations["everything/root"]
          .flatMap { try? JSONDecoder().decode([WorkspaceKanbanColumn].self, from: $0) } ?? []
        for column in globalColumns + WorkspaceKanbanColumn.blitzitDefaults
          where usedColumnIDs.contains(column.id)
            && !columns.contains(where: { $0.id == column.id }) {
          columns.append(column)
        }
      }
      boardColumns = columns
      matrixPositions = Dictionary(uniqueKeysWithValues: boardTasks.map { task in
        (task.id, (try? store.matrixPosition(for: task.id)) ?? TaskMatrixPosition(urgency: nil, importance: nil))
      })
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Some Checkvist imports have a single transport root repeating the list
  /// name. Its children are the visible list roots in both single-list and
  /// Everything scopes, while their actual parent IDs remain unchanged.
  private func visibleRootParentTaskID(for list: TaskList, store: WorkspaceStore) throws -> String? {
    try store.visibleRootParentTaskID(for: list)
  }

  private func uniqueColumnID(base: String, in columns: [WorkspaceKanbanColumn]) -> String {
    guard columns.contains(where: { $0.id == base }) else { return base }
    var counter = 2
    while columns.contains(where: { $0.id == "\(base)-\(counter)" }) { counter += 1 }
    return "\(base)-\(counter)"
  }

  func reloadFocus() {
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

  func perform(_ work: () throws -> Void) {
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
