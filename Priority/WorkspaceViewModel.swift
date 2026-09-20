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

struct WorkspaceItemMoveRequest: Identifiable {
  let payload: String
  let title: String
  let sourceListID: String
  let taskID: String?
  var id: String { payload }
}

/// One place the global capture field can file a task. A nested list remains
/// in its owning physical list and is represented by its task as the parent.
struct QuickCaptureDestination: Identifiable, Equatable {
  let id: String
  let listID: String
  let parentTaskID: String?
  let title: String
  let path: String
  let depth: Int
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
  /// Names the service a task was imported from, and so which identifiers its
  /// `sourceId` values belong to. Stored on the task, hence not free to change.
  static let checkvistSourceSystem = "checkvist"
  static let legacyOfflineSourceSystem = "priority-offline"

  /// Internal rather than private so `WorkspaceViewModel+Dailies.swift` —
  /// the same type, split only for size — can reach it.
  @ObservationIgnored var store: WorkspaceStore?
  @ObservationIgnored private let legacyStore: LocalTaskStore
  /// Title, task id, list name, due date, all-day → the created event's id,
  /// which is what lets Priority notice later that it was cleared.
  @ObservationIgnored var googleCalendarEventCreator:
    ((String, String, String, Date?, Bool) async throws -> String?)?
  /// Called with a task id and the calendar event now standing for it.
  @ObservationIgnored var onGoogleCalendarEventCreated: ((String, String) -> Void)?
  /// Called after any local write, so the Google Tasks mirror can push it.
  /// Coalesced on the far side — this fires far more often than it syncs.
  @ObservationIgnored var onLocalWrite: (() -> Void)?
  let taskEditor = WorkspaceTaskEditor()

  private(set) var workspace: Workspace?
  private(set) var folders: [ListFolder] = []
  private(set) var lists: [TaskList] = []
  private(set) var archivedLists: [TaskList] = []
  private(set) var outline: [TaskOutlineItem] = []
  private(set) var boardTasks: [WorkspaceTask] = []
  private(set) var taskContentRevision = 0
  @ObservationIgnored private var taskCache: [String: WorkspaceTask] = [:]
  @ObservationIgnored private var missingTaskIDs: Set<String> = []
  @ObservationIgnored private var descendantCache: [String: [TaskOutlineItem]] = [:]
  var listTaskCounts: [String: Int] = [:]
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
  private var boardTasksByColumn: [String: [WorkspaceTask]] = [:]
  private var boardColumnsByID: [String: WorkspaceKanbanColumn] = [:]
  private var boardVisibleTaskIDs: Set<String> = []
  private(set) var matrixPositions: [String: TaskMatrixPosition] = [:]
  var viewMode: WorkspaceViewMode = .board
  /// Virtual parent of every active list. The tasks remain stored in their
  /// own lists; this flag only changes which roots the views present.
  var isEverythingSelected = UserDefaults.standard.bool(forKey: WorkspaceViewModel.everythingScopeKey)
  var newTaskListID: String?
  var listIcons = UserDefaults.standard.dictionary(forKey: "workspaceListIconsV1") as? [String: String] ?? [:]

  static let availableListIcons: [(symbol: String, label: String)] = [
    ("list.bullet", "List"), ("tray", "Inbox"), ("briefcase", "Work"),
    ("graduationcap", "Study"), ("hammer", "Projects"), ("house", "Home"),
    ("heart", "Health"), ("figure.run", "Fitness"), ("book", "Reading"),
    ("music.note", "Music"), ("sailboat", "Sailing"), ("star", "Goals"),
    ("person.2", "People"), ("calendar", "Plans"), ("lightbulb", "Ideas"),
    ("leaf", "Habits"), ("airplane", "Travel"), ("gamecontroller", "Fun")
  ]

  func icon(for list: TaskList) -> String {
    listIcons[list.id] ?? (list.systemRole == .inbox ? "tray" : "list.bullet")
  }

  func setIcon(_ symbol: String, for list: TaskList) {
    listIcons[list.id] = symbol
    UserDefaults.standard.set(listIcons, forKey: "workspaceListIconsV1")
  }
  var newKanbanColumnRequest = false
  var dailyProgressRevision = 0
  var selectedListID: String?
  var selectedFolderID: String?
  var expandedFolderIDs: Set<String> = []
  var scopeTaskID: String?
  var nestedLists: [TaskOutlineItem] = []
  var archivedNestedLists: [WorkspaceTask] = []
  var creationIsNested = false
  var creationTaskParentID: String?
  var creationTaskListID: String?
  var selectedTaskID: String?
  var focusedBoardColumnID: String?

  var activeBoardColumnID: String? {
    if let task = selectedTask, let column = column(for: task) { return column.id }
    return boardColumns.first(where: { $0.id == focusedBoardColumnID })?.id
      ?? boardColumns.first?.id
  }
  var isInspectorVisible = false
  var taskMoveRequest: WorkspaceItemMoveRequest?
  var taskQuickEditRequest: WorkspaceTaskQuickEditRequest?
  var dragDestinationListID: String?
  /// Asks the view for the always-on-top companion. A counter rather than a
  /// flag: the button and the F key both just want it shown, again.
  var focusFloatRequest = 0
  var showsKeyboardHelp = false
  var showsListNavigator = false
  var showsSearch = false
  var searchQuery = "" { didSet { refreshSearchResults() } }
  var searchIncludesCompleted = false { didSet { refreshSearchResults() } }
  /// Written only by `refreshSearchResults()`; internal rather than
  /// `private(set)` so that method can live in `WorkspaceViewModel+Search.swift`.
  var searchResults: [TaskSearchResult] = []
  var selectedSearchResultID: String?
  var creationRequest: WorkspaceCreationKind?
  var creationParentFolderID: String?
  var sidebarEditor: WorkspaceSidebarEditor?
  /// The list or folder currently showing a rename field, by its own id.
  /// Lists and folders both carry UUIDs, so one field serves both.
  var renamingSidebarItemID: String?
  var pendingSidebarDeletion: WorkspaceSidebarItem?
  var taskComposerFocusRequest = 0
  /// The normal composer is deliberately lightweight. These fields are only
  /// active for global capture, where destination and start day can be chosen
  /// without taking your hands off the keyboard.
  var isQuickCaptureActive = false
  var quickCaptureDestinationID: String?
  var quickCaptureStartDayOffset: Int?
  var desktopShortcutSequence = DesktopShortcutSequence()
  var hidesCompletedTasks = false
  var taskInsertionReference: WorkspaceTask?
  var taskInsertionAbove = false
  var taskInsertionIsChild = false
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
  /// A finished block waiting to be told how it went. Set the instant Done is
  /// pressed — the clock stops when the work stops, not when the judgement
  /// arrives — and cleared when the block is scored or the prompt is dropped.
  var pendingFocusCompletion: PendingFocusCompletion?
  /// What the last scored block earned, so the UI can show it and move on.
  var lastFocusAward: FocusAward?
  /// Written only by `reloadFocus()`; read by the panel and the prompt.
  var focusPoints: FocusPointsSummary = .zero
  var focusHistoryDate = Date.now
  private(set) var focusHistory: [FocusWorkBlock] = []
  /// What the blocks in `focusHistory` were scored, keyed by block id — an
  /// award carries the block's own id. Blocks finished without a judgement
  /// have no entry, which is the difference the timeline draws.
  private(set) var focusHistoryAwards: [String: FocusAward] = [:]
  var showsFocusScreen = false
  /// Whether the timeline has the main pane. Held beside `showsFocusScreen`
  /// and mutually exclusive with it: both are takeovers of the same pane.
  var showsTimelineScreen = false
  /// Minutes offered on the focus screen, seeded from the task's estimate.
  var focusEstimateMinutes: Double = 25
  var errorMessage: String?

  init(legacyStore: LocalTaskStore) {
    self.legacyStore = legacyStore
    do {
      self.store = try WorkspaceStore()
      try self.store?.recoverInterruptedFocus()
      try load()
      restoreSuggestedContext()
    } catch {
      self.store = nil
      self.errorMessage = error.localizedDescription
    }
  }

  var selectedList: TaskList? { lists.first { $0.id == selectedListID } }
  /// Where quick capture lands. Found by role, so renaming it does not move it.
  var inboxList: TaskList? { lists.first { $0.systemRole == .inbox } }
  var selectedFolder: ListFolder? { folders.first { $0.id == selectedFolderID } }
  func list(for task: WorkspaceTask) -> TaskList? { lists.first { $0.id == task.listId } }

  var scopeTask: WorkspaceTask? {
    guard let scopeTaskID else { return nil }
    return task(withID: scopeTaskID)
  }

  /// Resolves a local drag payload only through the workspace store. A drop
  /// target never trusts an arbitrary identifier from outside the workspace.
  func task(withID id: String) -> WorkspaceTask? {
    _ = taskContentRevision
    if let cached = taskCache[id] { return cached }
    guard !missingTaskIDs.contains(id), let store else { return nil }
    guard let task = try? store.task(id: id) else {
      missingTaskIDs.insert(id)
      return nil
    }
    taskCache[id] = task
    return task
  }

  var selectedTask: WorkspaceTask? {
    guard let selectedTaskID else { return nil }
    return task(withID: selectedTaskID)
  }

  var activeFocusTask: WorkspaceTask? {
    guard let taskID = activeFocusSession?.activeTaskId else { return nil }
    return task(withID: taskID)
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
      scopeTaskID = nil
      selectedTaskID = nil
      isInspectorVisible = false
      // On the first desktop launch, put a migrated user straight into their
      // existing work rather than an empty Inbox. This also covers people who
      // ran an earlier preview that completed the import before the desktop
      // window became the default launch surface.
      selectedListID = importedList?.id
        ?? lists.first(where: { $0.name.hasPrefix("Imported from old Priority") })?.id
        ?? lists.first?.id
      if selectedList?.systemRole == .inbox {
        viewMode = .outline
      }
    }
    if newTaskListID == nil || !lists.contains(where: { $0.id == newTaskListID }) {
      newTaskListID = selectedListID ?? lists.first?.id
    }
    if let selectedFolderID, !folders.contains(where: { $0.id == selectedFolderID }) {
      self.selectedFolderID = nil
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
    taskEditor.flush()
    dismissFocusScreen()
    isEverythingSelected = false
    UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
    selectedListID = id
    newTaskListID = id
    selectedFolderID = nil
    scopeTaskID = nil
    focusedBoardColumnID = nil
    taskInsertionReference = nil
    desktopShortcutSequence.reset()
    selectedTaskID = nil
    isInspectorVisible = false
    // The inbox is a queue to empty, not a board to plan, so it opens as a
    // flat outline whatever the last list was shown as.
    viewMode = lists.first(where: { $0.id == id })?.systemRole == .inbox ? .outline : .board
    reloadOutline(refreshSidebar: false)
  }

  func selectEverything() {
    taskEditor.flush()
    dismissFocusScreen()
    if let selectedListID { newTaskListID = selectedListID }
    isEverythingSelected = true
    UserDefaults.standard.set(true, forKey: Self.everythingScopeKey)
    selectedListID = nil
    selectedFolderID = nil
    scopeTaskID = nil
    focusedBoardColumnID = nil
    taskInsertionReference = nil
    desktopShortcutSequence.reset()
    selectedTaskID = nil
    isInspectorVisible = false
    viewMode = .board
    reloadOutline(refreshSidebar: false)
  }

  func selectFolder(_ folder: ListFolder) {
    dismissFocusScreen()
    selectedFolderID = folder.id
    selectedTaskID = nil
    isInspectorVisible = false
  }

  func enterTask(_ task: WorkspaceTask) {
    taskEditor.flush()
    if isEverythingSelected {
      isEverythingSelected = false
      UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
      selectedListID = task.listId
      newTaskListID = task.listId
    }
    selectedListID = task.listId
    newTaskListID = task.listId
    selectedFolderID = nil
    scopeTaskID = task.id
    focusedBoardColumnID = nil
    isInspectorVisible = false
    viewMode = .board
    reloadOutline(refreshSidebar: false)
  }

  func selectTask(_ task: WorkspaceTask) {
    guard selectedTaskID != task.id else { return }
    taskEditor.flush()
    selectedTaskID = task.id
  }

  func selectViewMode(_ mode: WorkspaceViewMode) {
    viewMode = mode
    if isEverythingSelected { reloadOutline(refreshSidebar: false) }
    if mode == .focus, activeFocusSession == nil, let task = selectedTask {
      startFocus(on: task)
    }
  }

  func leaveTaskScope() {
    guard let task = scopeTask else { return }
    scopeTaskID = task.parentTaskId
    selectedTaskID = task.id
    reloadOutline(refreshSidebar: false)
  }

  /// Captures into the inbox from anywhere: the global hotkey, with no
  /// assumption about what was on screen when it was pressed.
  ///
  /// Selecting the inbox rather than typing into whatever list happened to be
  /// open is the point — a thought caught mid-task belongs in the inbox, not
  /// filed into the project the user was looking at by accident.
  func beginQuickCapture() {
    // Explicitly, rather than relying on `selectList` to do it: the focus
    // screen can be up while the inbox is already the selected list.
    dismissFocusScreen()
    if let inbox = inboxList, selectedListID != inbox.id || isEverythingSelected {
      selectList(inbox.id)
    }
    isQuickCaptureActive = true
    quickCaptureDestinationID = inboxList?.id ?? lists.first?.id
    quickCaptureStartDayOffset = nil
    requestTaskComposerFocus()
  }

  var quickCaptureDestinations: [QuickCaptureDestination] {
    lists.flatMap { list -> [QuickCaptureDestination] in
      var result = [QuickCaptureDestination(
        id: list.id, listID: list.id, parentTaskID: nil, title: list.name,
        path: list.name, depth: 0)]
      result += nestedLists.filter { $0.task.listId == list.id }.map { item in
        var components = [item.task.title]
        var parentID = item.task.parentTaskId
        var visited = Set<String>()
        while let id = parentID, visited.insert(id).inserted, let parent = task(withID: id) {
          if parent.isList && parent.id != list.visibleRootTaskId { components.append(parent.title) }
          parentID = parent.parentTaskId
        }
        let path = ([list.name] + components.reversed()).joined(separator: " › ")
        return QuickCaptureDestination(
          id: item.task.id, listID: list.id, parentTaskID: item.task.id,
          title: item.task.title, path: path, depth: item.depth + 1)
      }
      return result
    }
  }

  var quickCaptureDestination: QuickCaptureDestination? {
    let destinations = quickCaptureDestinations
    return destinations.first { $0.id == quickCaptureDestinationID }
      ?? destinations.first { destination in
        lists.first(where: { $0.id == destination.listID })?.systemRole == .inbox
      }
      ?? destinations.first
  }

  var quickCaptureStartDate: Date? {
    guard let offset = quickCaptureStartDayOffset else { return nil }
    let start = Calendar.current.startOfDay(for: .now)
    return Calendar.current.date(byAdding: .day, value: offset, to: start)
  }

  var quickCaptureStartLabel: String {
    guard let offset = quickCaptureStartDayOffset, let date = quickCaptureStartDate else {
      return "Any day"
    }
    if offset == 1 { return "Tomorrow" }
    if offset == 2 { return "In 2 days" }
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
  }

  func moveQuickCaptureDestination(by offset: Int) {
    let destinations = quickCaptureDestinations
    guard !destinations.isEmpty else { return }
    let current = destinations.firstIndex { $0.id == quickCaptureDestination?.id } ?? 0
    let next = (current + offset + destinations.count) % destinations.count
    quickCaptureDestinationID = destinations[next].id
  }

  func moveQuickCaptureStartDay(by offset: Int) {
    let current = quickCaptureStartDayOffset ?? 0
    let next = max(0, current + offset)
    quickCaptureStartDayOffset = next == 0 ? nil : next
  }

  func cancelQuickCapture() {
    isQuickCaptureActive = false
    quickCaptureDestinationID = nil
    quickCaptureStartDayOffset = nil
  }

  func submitQuickCapture(named title: String) {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, let store, let destination = quickCaptureDestination else { return }
    perform {
      let parentID: String?
      if let nestedParent = destination.parentTaskID {
        parentID = nestedParent
      } else if let list = lists.first(where: { $0.id == destination.listID }) {
        parentID = try visibleRootParentTaskID(for: list, store: store)
      } else {
        parentID = nil
      }
      let task = try store.createTask(
        listId: destination.listID, title: normalized, parentTaskId: parentID,
        startAt: quickCaptureStartDate)
      selectedTaskID = destination.listID == selectedListID ? task.id : nil
      cancelQuickCapture()
      reloadOutline()
    }
  }

  func requestTaskComposerFocus() {
    if !isQuickCaptureActive {
      quickCaptureDestinationID = nil
      quickCaptureStartDayOffset = nil
    }
    taskInsertionReference = nil
    requestKeyboardFocus(.tasks)
    taskComposerFocusRequest += 1
  }

  func requestRelativeTaskComposerFocus(above: Bool = false, child: Bool = false) {
    let reference = selectedTask
    requestTaskComposerFocus()
    taskInsertionReference = reference
    taskInsertionAbove = above
    taskInsertionIsChild = child
  }

  func requestKeyboardFocus(_ area: WorkspaceFocusArea) {
    desktopShortcutSequence.reset()
    if area == .tasks && selectedTaskID == nil && !(viewMode == .board && focusedBoardColumnID != nil) {
      selectedTaskID = visibleNavigationTasks.first?.id
    }
    if area == .sidebar { taskInsertionReference = nil }
    if area == .inspector { isInspectorVisible = true }
    requestedFocusArea = area
    keyboardFocusArea = area
    focusRequest += 1
  }

  func reportKeyboardFocus(_ area: WorkspaceFocusArea?) {
    if area != keyboardFocusArea { desktopShortcutSequence.reset() }
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
    if keyboardFocusArea == .sidebar {
      if let scope = scopeTask, scope.isList {
        requestMove(scope)
      } else if let list = selectedList, !list.isSystemList {
        taskMoveRequest = WorkspaceItemMoveRequest(payload: WorkspaceTaskDrag.listPrefix + list.id,
          title: list.name, sourceListID: list.id, taskID: nil)
      }
      return
    }
    if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
    guard let task = selectedTask else { return }
    requestMove(task)
  }

  func requestMove(_ task: WorkspaceTask) {
    taskMoveRequest = WorkspaceItemMoveRequest(payload: task.id, title: task.title,
      sourceListID: task.listId, taskID: task.id)
  }

  func cycleKeyboardFocus(by offset: Int) {
    let areas: [WorkspaceFocusArea] = selectedTask == nil || !isInspectorVisible
      ? [.sidebar, .tasks] : [.sidebar, .tasks, .inspector]
    let current = areas.firstIndex(of: keyboardFocusArea) ?? 0
    let destination = (current + offset + areas.count) % areas.count
    requestKeyboardFocus(areas[destination])
  }

  func requestCreation(_ kind: WorkspaceCreationKind, in parentFolderID: String? = nil) {
    creationIsNested = false
    creationParentFolderID = parentFolderID
    creationRequest = kind
  }

  func requestListCreationForSelection() {
    if keyboardFocusArea == .tasks, !isEverythingSelected, selectedListID != nil {
      requestNestedListCreation(under: scopeTask)
    } else {
      requestCreation(.list, in: selectedFolderID)
    }
  }

  func requestFolderCreationForSelection() {
    requestCreation(.folder, in: selectedFolderID)
  }

  func createList(named name: String, in folderId: String? = nil) {
    guard let store, let workspace else { return }
    do {
      let list = try store.createList(workspaceId: workspace.id, name: name, folderId: folderId)
      try load()
      selectList(list.id)
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
    if taskInsertionReference != nil { createRelativeTask(named: title); return }
    guard let store,
      let destinationID = isEverythingSelected ? newTaskListID : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return }
    perform {
      let parentID = isEverythingSelected
        ? try visibleRootParentTaskID(for: destinationList, store: store) : scopeTaskID
      let task = try store.createTask(listId: destinationID, title: title, parentTaskId: parentID)
      selectedTaskID = task.id
      reloadOutline()
    }
  }

  private func createRelativeTask(named title: String) {
    guard let store, let reference = taskInsertionReference else { return }
    perform {
      let task = try store.createTask(listId: reference.listId, title: title,
        parentTaskId: taskInsertionIsChild ? reference.id : reference.parentTaskId,
        kanbanColumn: viewMode == .board ? column(for: reference)?.id : nil,
        adjacentTaskId: taskInsertionIsChild ? nil : reference.id, above: taskInsertionAbove)
      if taskInsertionIsChild { scopeTaskID = reference.id }
      selectedTaskID = task.id
      taskInsertionReference = task
      taskInsertionAbove = false
      taskInsertionIsChild = false
      reloadOutline()
    }
  }

  /// Creates work in the currently visible board scope. This differs from the
  /// outline only for a transparent imported root project (see
  /// `boardParentTaskID`), where a new card belongs alongside the visible
  /// children rather than appearing above them as a second wrapper.
  func createBoardTask(named title: String, in column: WorkspaceKanbanColumn? = nil, atTop: Bool = false) {
    if column == nil && taskInsertionReference != nil { createRelativeTask(named: title); return }
    guard let store,
      let destinationID = isEverythingSelected ? newTaskListID : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return }
    let column = column ?? boardColumns.first { $0.id == activeBoardColumnID }
    perform {
      let parentID = isEverythingSelected
        ? try visibleRootParentTaskID(for: destinationList, store: store) : boardParentTaskID
      let task = try store.createTask(listId: destinationID, title: title, parentTaskId: parentID,
        kanbanColumn: column?.id, atTop: atTop)
      selectedTaskID = task.id
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
    _ = taskContentRevision
    if let cached = boardDescendants[task.id] { return cached }
    if let cached = descendantCache[task.id] { return cached }
    guard let store else { return [] }
    let items = (try? store.outline(in: task.listId, parentTaskId: task.id)) ?? []
    descendantCache[task.id] = items
    return items
  }

  func boardParent(of task: WorkspaceTask) -> WorkspaceTask? {
    boardTaskParents[task.id]
  }

  var currentBoardScopeTitle: String {
    if isEverythingSelected { return "Everything" }
    return scopeTask?.title ?? selectedList?.name ?? "Board"
  }

  func tasks(in column: WorkspaceKanbanColumn) -> [WorkspaceTask] {
    boardTasksByColumn[column.id, default: []]
  }

  var todayTasks: [WorkspaceTask] {
    guard let today = boardColumns.first(where: { $0.id == "today" }) else { return [] }
    return tasks(in: today).filter { $0.status == .open }
  }

  func isTaskVisibleOnBoard(_ task: WorkspaceTask) -> Bool {
    boardVisibleTaskIDs.contains(task.id)
  }

  func column(for task: WorkspaceTask) -> WorkspaceKanbanColumn? {
    let id = boardTaskColumns[task.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
    return boardColumnsByID[id] ?? boardColumns.first
  }

  private func rebuildBoardIndex() {
    boardColumnsByID = Dictionary(boardColumns.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
    let tasks = boardTasks + boardCrossColumnTasks
    boardVisibleTaskIDs = Set(tasks.map(\.id))
    boardTasksByColumn = Dictionary(grouping: tasks) { task in
      column(for: task)?.id ?? ""
    }
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
      try store.moveTaskBefore(id: task.id, targetId: target.id, kanbanColumn: column(for: target)?.id)
      reloadBoard()
    }
  }

  func addKanbanColumn(named name: String) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    guard let store else { return }
    var columns = boardColumns
    let baseID = title.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let id = uniqueColumnID(base: baseID.isEmpty ? "column" : baseID, in: columns)
    columns.append(WorkspaceKanbanColumn(id: id, title: title))
    perform {
      try store.setKanbanBoardColumns(columns, for: boardConfigurationKey, label: "Add Board Column")
      reloadOutline()
    }
  }

  func removeKanbanColumn(_ column: WorkspaceKanbanColumn) {
    guard boardColumns.count > 1 else { return }
    let fallback = boardColumns.first { $0.id != column.id } ?? WorkspaceKanbanColumn.blitzitDefaults[0]
    guard let store else { return }
    let remaining = boardColumns.filter { $0.id != column.id }
    perform {
      try store.setKanbanBoardColumns(remaining, for: boardConfigurationKey,
        movingTaskIDs: tasks(in: column).map(\.id), toColumn: fallback.id, label: "Remove Board Column")
      reloadOutline()
    }
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
  /// Everything worth doing, most important first. Focus mode presents this as
  /// a ladder: rung 0 at the foot, less important work above it.
  var focusLadder: [ScoredNextUp] = []
  /// Which rung the cursor is on. Climbing means accepting less priority.
  var focusLadderIndex = 0
  var focusConditions: [TaskCondition] = []
  var taskLoggedSeconds: [String: Int] = [:]
  var taskPlanningByID: [String: TaskPlanning] = [:]
  var focusContext = FocusContext()
  var suggestedContextIDs: Set<String> = []
  var contextExpiresAt: Date?
  var availableUntil: Date?
  var blockedFocusTasks: [BlockedFocusTask] = []
  var nextFocusEvaluationAt: Date?
  var focusStartOverride: FocusStartOverride?
  var allowsQueueResume = false
  var lastFocusCheckpointAt = Date.distantPast
  var focusExpiryPromptedBlockID: String?
  var lastFocusClockAt = Date.now
  var lastFocusUptime = ProcessInfo.processInfo.systemUptime
  var lastFocusTimeZone = TimeZone.current.identifier
  /// The task committed to but not yet started — the step between "this one"
  /// and "go", where the estimate is decided.
  var stagedTaskID: String?
  /// Bumped when something asks for the current rung to be ticked off. The
  /// focus screen watches this and runs the celebration, because the mutation
  /// has to wait on an animation the model cannot see.
  var focusCompletionRequest = 0

  var visibleNavigationTasks: [WorkspaceTask] {
    switch viewMode {
    case .outline: outline.map(\.task)
    case .board: boardColumns.flatMap { tasks(in: $0) }
    case .dailies: dailyProgressTasks
    case .matrix: boardTasks
    case .focus:
      if let activeFocusTask { [activeFocusTask] + focusQueue.map(\.task) } else { selectedTask.map { [$0] } ?? [] }
    }
  }

  func moveTaskSelection(by offset: Int) {
    let visibleTasks = viewMode == .board
      ? boardColumns.first(where: { $0.id == activeBoardColumnID }).map { tasks(in: $0) } ?? []
      : visibleNavigationTasks
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
    focusAdjacentBoardColumn(from: column(for: task)?.id, by: offset)
  }

  func focusAdjacentBoardColumn(from columnID: String? = nil, by offset: Int) {
    guard viewMode == .board,
      let index = boardColumns.firstIndex(where: { $0.id == (columnID ?? activeBoardColumnID) })
    else { return }
    let destination = index + offset
    guard boardColumns.indices.contains(destination) else {
      if destination < 0 { returnToCurrentListInSidebar() }
      return
    }
    let column = boardColumns[destination]
    focusedBoardColumnID = column.id
    selectedTaskID = tasks(in: column).first?.id
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
    case nestedList(String)
    case folder(String)
  }

  /// Mirrors the visible sidebar order: Everything, Inbox, pinned shortcuts,
  /// folders and their contents, then the ungrouped lists.
  private var sidebarNavigationTargets: [SidebarNavigationTarget] {
    var result: [SidebarNavigationTarget] = [.everything]
    var visited = Set<String>()
    func appendList(_ list: TaskList) {
      result.append(.list(list.id))
      result += nestedLists.filter { $0.task.listId == list.id }.map { .nestedList($0.id) }
    }
    func appendFolder(_ folder: ListFolder) {
      guard visited.insert(folder.id).inserted else { return }
      result.append(.folder(folder.id))
      guard expandedFolderIDs.contains(folder.id) else { return }
      for list in lists where list.folderId == folder.id && list.systemRole != .inbox {
        appendList(list)
      }
      for child in folders where child.parentFolderId == folder.id {
        appendFolder(child)
      }
    }
    if let inbox = inboxList { appendList(inbox) }
    result += promotedLists.map { .nestedList($0.id) }
    for folder in folders where folder.parentFolderId == nil { appendFolder(folder) }
    for list in lists where list.folderId == nil && list.systemRole != .inbox { appendList(list) }
    return result
  }

  func moveSidebarSelection(by offset: Int) {
    let targets = sidebarNavigationTargets
    guard !targets.isEmpty else { return }
    let current: SidebarNavigationTarget? = if let selectedFolderID {
      .folder(selectedFolderID)
    } else if isEverythingSelected {
      .everything
    } else if let scope = scopeTask, scope.isList {
      .nestedList(scope.id)
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
    case .nestedList(let id):
      if let task = task(withID: id) { selectNestedList(task) }
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

  func enterTaskSurfaceFromSidebar() {
    if viewMode == .board {
      let backlog = boardColumns.first { $0.id == "backlog" } ?? boardColumns.first
      focusedBoardColumnID = backlog?.id
      selectedTaskID = backlog.flatMap { tasks(in: $0).first?.id }
    } else {
      selectedTaskID = visibleNavigationTasks.first?.id
    }
    requestKeyboardFocus(.tasks)
  }

  func returnToCurrentListInSidebar() {
    selectedFolderID = nil
    var folderID = selectedList?.folderId
    var visited = Set<String>()
    while let id = folderID, visited.insert(id).inserted,
      let folder = folders.first(where: { $0.id == id }) {
      setFolderExpanded(folder, expanded: true)
      folderID = folder.parentFolderId
    }
    requestKeyboardFocus(.sidebar)
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
      try reloadNestedLists()
      reloadOutline()
      reloadNextUp()
    }
  }

  func moveTask(_ task: WorkspaceTask, toListId listId: String) {
    guard let store else { return }
    perform {
      try store.moveTask(id: task.id, toListId: listId, toVisibleRoot: true)
      if let scopeTaskID, let scope = try store.task(id: scopeTaskID), scope.listId != selectedListID {
        self.scopeTaskID = nil
      }
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
      ImportedTaskSeed(
        sourceId: "\(sourcePrefix)\(task.id)",
        parentSourceId: task.parentId.map { "\(sourcePrefix)\($0)" },
        title: task.content,
        notes: task.notes?.map(\.content).joined(separator: "\n\n") ?? "",
        status: task.status == 0 ? .open : (task.status == 1 ? .completed : .cancelled),
        sortOrder: task.position ?? 0)
    }

    do {
      let outcome = try store.importTasks(
        workspaceId: workspace.id,
        listName: "Imported from Checkvist — \(listID)",
        sourceSystem: Self.checkvistSourceSystem,
        seeds: seeds)
      migratedListIDs.insert(listID)
      defaults.set(Array(migratedListIDs).sorted(), forKey: Self.checkvistMigrationKeysKey)
      try load()
      if let outcome {
        selectList(outcome.list.id)
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
          ImportedTaskSeed(
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
        } else if let outcome = try store.importTasks(
          workspaceId: workspace.id, listName: snapshot.list.name,
          sourceSystem: Self.checkvistSourceSystem, seeds: seeds)
        {
          localList = outcome.list
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

  func reloadOutline(refreshSidebar: Bool = true) {
    guard let store else {
      outline = []
      boardTasks = []
      boardTaskColumns = [:]
      matrixPositions = [:]
      return
    }
    do {
      if refreshSidebar { try reloadNestedLists() }
      if isEverythingSelected {
        if viewMode == .outline {
          outline = try workspace.map { try store.actionableTasks(in: $0.id).map { TaskOutlineItem(task: $0, depth: 0) } } ?? []
        } else {
          outline = []
        }
      } else if let selectedListID {
        let parentID = try scopeTaskID ?? selectedList.flatMap {
          try visibleRootParentTaskID(for: $0, store: store)
        }
        outline = try store.visibleOutline(in: selectedListID, parentTaskId: parentID)
      } else {
        outline = []
      }
      if hidesCompletedTasks { outline.removeAll { $0.task.status != .open } }
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
    defer { rebuildBoardIndex() }
    taskCache.removeAll(keepingCapacity: true)
    missingTaskIDs.removeAll(keepingCapacity: true)
    descendantCache.removeAll(keepingCapacity: true)
    defer { taskContentRevision += 1 }
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
        boardTasks = try workspace.map { try store.actionableTasks(in: $0.id) } ?? []
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
      boardTasks.removeAll { ($0.isList && $0.archivedAt != nil) || (hidesCompletedTasks && $0.status != .open) }
      let boardIDs = Set(boardTasks.map(\.id))
      var descendants: [String: [TaskOutlineItem]] = Dictionary(
        uniqueKeysWithValues: boardTasks.map { ($0.id, []) })
      var parents: [String: WorkspaceTask] = [:]
      for listID in Set(boardTasks.map(\.listId)) {
        var ancestors: [TaskOutlineItem] = []
        for item in try store.visibleOutline(in: listID) {
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
      var treeIDs = Set<String>()
      let boardTreeTasks = (boardTasks + boardTasks.flatMap { root in
        descendants[root.id, default: []].map(\.task)
      }).filter { treeIDs.insert($0.id).inserted }
      let metadata = try store.boardMetadata(for: boardTreeTasks.map(\.id))
      boardTaskColumns = metadata.columns
      taskCache = Dictionary(uniqueKeysWithValues: boardTreeTasks.map { ($0.id, $0) })
      boardCrossColumnTasks = boardTreeTasks.filter { task in
        if hidesCompletedTasks && task.status != .open { return false }
        guard !task.isList else { return false }
        guard !boardIDs.contains(task.id), let parent = parents[task.id] else { return false }
        let taskColumn = boardTaskColumns[task.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
        let parentColumn = boardTaskColumns[parent.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
        return taskColumn != parentColumn
      }
      let legacy = UserDefaults.standard.dictionary(forKey: Self.kanbanColumnsKey) as? [String: Data] ?? [:]
      let configurations = try store.kanbanBoardConfigurations(legacy: legacy, currentKey: boardConfigurationKey)
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
      matrixPositions = metadata.positions
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
      focusPoints = try store.focusPointsSummary()
      if let day = Calendar.current.dateInterval(of: .day, for: focusHistoryDate) {
        focusHistory = try store.focusWorkBlocks(in: day)
        focusHistoryAwards = Dictionary(
          try store.focusAwards(onDayOf: focusHistoryDate).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func perform(_ work: () throws -> Void) {
    do {
      try work()
      if let store { taskEditor.refresh(store: store) }
      errorMessage = nil
      // Every local write funnels through here, which makes it the one place
      // the Google Tasks mirror has to be told about. It coalesces.
      onLocalWrite?()
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
      ImportedTaskSeed(
        sourceId: String(task.id),
        parentSourceId: task.parentId.map(String.init),
        title: task.content,
        notes: task.notes?.map(\.content).joined(separator: "\n\n") ?? "",
        status: task.status == 0 ? .open : (task.status == 1 ? .completed : .cancelled),
        sortOrder: task.position ?? 0)
    }
    let date = ISO8601DateFormatter().string(from: .now).prefix(10)
    let outcome = try store.importTasks(
      workspaceId: workspace.id, listName: "Imported from old Priority — \(date)",
      sourceSystem: Self.legacyOfflineSourceSystem, seeds: seeds)
    defaults.set(true, forKey: Self.legacyMigrationKey)
    return outcome?.list
  }
}
