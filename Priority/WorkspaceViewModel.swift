import AppKit
import Foundation
import Observation
import PriorityCore
import PriorityWorkspace
import SwiftUI

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
  /// The right-hand rail of finished work. A region rather than a scroll view
  /// with a click target, because the app's premise is that anything you can
  /// reach you can reach from the keyboard.
  case done
}

/// Views of the same local task model, rather than separate applications.
enum WorkspaceViewMode: String, CaseIterable, Identifiable {
  case today
  case board
  case outline
  case matrix

  /// The places you can be. Today is first because it is the question the app
  /// exists to answer; the rest are projections of the same tasks, read when
  /// the answer looks wrong. Focus is an action on the day, not a place to
  /// navigate to, so it is not among them.
  ///
  /// There is deliberately no Dailies here. A daily is a requirement placed on
  /// an ordinary task — that it be contributed to each day — not a kind of item
  /// with a room of its own. Such a task appears in Today like anything else
  /// today has a claim on, badged for what it owes.
  static let planningModes: [WorkspaceViewMode] = [.today, .board, .outline, .matrix]

  var id: String { rawValue }
  var title: String {
    switch self {
    case .today: "Today"
    case .board: "Board"
    case .outline: "Outline"
    case .matrix: "Matrix"
    }
  }

  var symbolName: String {
    switch self {
    case .today: "sun.max"
    case .board: "rectangle.split.3x1"
    case .outline: "list.bullet.indent"
    case .matrix: "square.grid.2x2"
    }
  }

  /// Where the mode sits on the command-digit row, and what the View menu
  /// prints beside it.
  /// The catalogue entry that goes here, rather than the key itself. The digit
  /// used to be written out here as well as in the router, the toolbar tooltip
  /// and the menu — four copies of ⌘1.
  var command: WorkspaceCommandID? {
    switch self {
    case .today: .goToday
    case .board: .goBoard
    case .outline: .goOutline
    case .matrix: .goMatrix
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
  static let everythingScopeKey = "localWorkspaceEverythingScopeV1"
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
  /// The watch for writes made by another process. See
  /// `WorkspaceViewModel+ExternalWrites.swift`.
  @ObservationIgnored var externalWriteToken: Int?
  @ObservationIgnored var externalWriteTimer: Timer?
  let taskEditor = WorkspaceTaskEditor()

  private(set) var workspace: Workspace?
  private(set) var folders: [ListFolder] = []
  private(set) var lists: [TaskList] = []
  private(set) var archivedLists: [TaskList] = []
  private(set) var outline: [TaskOutlineItem] = [] {
    didSet {
      outlineByList = Dictionary(grouping: outline) { $0.task.listId }
      outlineOpenCount = outline.reduce(0) { $0 + ($1.task.status == .open ? 1 : 0) }
    }
  }
  /// The outline grouped by list and its open count, derived once per reload
  /// rather than on every render of the combined outline.
  private(set) var outlineByList: [String: [TaskOutlineItem]] = [:]
  private(set) var outlineOpenCount = 0
  private(set) var boardTasks: [WorkspaceTask] = []
  /// Bumped whenever `taskCache` is rebuilt, so a view that resolved a task
  /// by id re-resolves it. Written by `rebuildTaskCache()`.
  var taskContentRevision = 0
  @ObservationIgnored var taskCache: [String: WorkspaceTask] = [:]
  @ObservationIgnored var missingTaskIDs: Set<String> = []
  @ObservationIgnored var descendantCache: [String: [TaskOutlineItem]] = [:]
  /// The board's cards and everything beneath them, as the last refresh read
  /// them. Held so the task cache can be rebuilt without reading them again.
  @ObservationIgnored var boardTreeTasks: [WorkspaceTask] = []
  /// Board column layouts by scope key, as `kanbanBoardConfigurations`
  /// returned them. That call is a write transaction and a JSON decode per
  /// scope, so it is made once per load and again only when a layout changes.
  @ObservationIgnored var boardColumnConfigurations: [String: Data]?

  // The refresh machinery. See `WorkspaceViewModel+Refresh.swift`.
  @ObservationIgnored var pendingRefresh: WorkspaceRefresh = []
  @ObservationIgnored var refreshDepth = 0
  @ObservationIgnored var performFailed = false
  @ObservationIgnored var performShouldMirror = false
  /// Moves on every refresh, so a ranking read before it knows it is stale.
  @ObservationIgnored var writeEpoch = 0
  @ObservationIgnored var nextUpRequested = false
  @ObservationIgnored var nextUpLaunchQueued = false
  @ObservationIgnored var nextUpGeneration = 0
  @ObservationIgnored var listTreeCache: [String: WorkspaceListTree] = [:]
  /// The rows behind the day, as the last ranking read them.
  @ObservationIgnored var dayTaskSnapshot: [String: WorkspaceTask] = [:]
  /// The history menu's labels. Read after writes by `refreshHistoryLabels()`
  /// rather than queried each time the menu is drawn.
  var undoLabel: String?
  var redoLabel: String?
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
  var boardTasksByColumn: [String: [WorkspaceTask]] = [:]
  var boardColumnsByID: [String: WorkspaceKanbanColumn] = [:]
  var boardVisibleTaskIDs: Set<String> = []
  private(set) var matrixPositions: [String: TaskMatrixPosition] = [:]
  var viewMode: WorkspaceViewMode = .today
  /// Virtual parent of every active list. The tasks remain stored in their
  /// own lists; this flag only changes which roots the views present.
  var isEverythingSelected = UserDefaults.standard.bool(forKey: WorkspaceViewModel.everythingScopeKey)
  var newTaskListID: String?
  var listIcons = UserDefaults.standard.dictionary(forKey: "workspaceListIconsV1") as? [String: String] ?? [:]

  /// Whether the sidebar takes a column at all. Persisted, because a sidebar
  /// you collapsed is a decision about how you work rather than about this
  /// session — reopening the window to find it back is the annoying part.
  var isSidebarVisible = UserDefaults.standard.object(forKey: WorkspaceViewModel.sidebarVisibleKey) as? Bool ?? true {
    didSet { UserDefaults.standard.set(isSidebarVisible, forKey: Self.sidebarVisibleKey) }
  }

  /// The width the sidebar was last dragged to.
  ///
  /// `HSplitView` sizes a pane from its `idealWidth` and then forgets whatever
  /// you dragged it to, so the column reset to 185 on every launch. Recording
  /// the laid-out width here and feeding it back as the ideal is what makes
  /// the drag stick.
  var sidebarWidth: CGFloat = {
    let stored = UserDefaults.standard.double(forKey: WorkspaceViewModel.sidebarWidthKey)
    guard stored > 0 else { return WorkspaceViewModel.defaultSidebarWidth }
    return min(max(CGFloat(stored), WorkspaceViewModel.minSidebarWidth), WorkspaceViewModel.maxSidebarWidth)
  }() {
    didSet {
      guard sidebarWidth != oldValue else { return }
      UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }
  }

  /// Whether the done rail takes a column. Persisted for the sidebar's reason:
  /// whether you want your finished work on screen is a way of working, not a
  /// decision to make again every launch.
  var isDoneRailVisible = UserDefaults.standard.bool(forKey: WorkspaceViewModel.doneRailVisibleKey) {
    didSet { UserDefaults.standard.set(isDoneRailVisible, forKey: Self.doneRailVisibleKey) }
  }

  /// An explicit width with a handle of its own, for the sidebar's reason: a
  /// pane that takes a share of whatever the window has spare is a pane whose
  /// width you cannot set.
  var doneRailWidth: CGFloat = {
    let stored = UserDefaults.standard.double(forKey: WorkspaceViewModel.doneRailWidthKey)
    guard stored > 0 else { return WorkspaceViewModel.defaultDoneRailWidth }
    return min(max(CGFloat(stored), WorkspaceViewModel.minDoneRailWidth), WorkspaceViewModel.maxDoneRailWidth)
  }() {
    didSet {
      guard doneRailWidth != oldValue else { return }
      UserDefaults.standard.set(Double(doneRailWidth), forKey: Self.doneRailWidthKey)
    }
  }

  static let minDoneRailWidth: CGFloat = 180
  static let maxDoneRailWidth: CGFloat = 460
  static let defaultDoneRailWidth: CGFloat = 250
  private static let doneRailWidthKey = "localWorkspaceDoneRailWidthV1"

  static let minSidebarWidth: CGFloat = 140
  static let maxSidebarWidth: CGFloat = 420
  static let defaultSidebarWidth: CGFloat = 185
  private static let sidebarVisibleKey = "localWorkspaceSidebarVisibleV1"
  private static let sidebarWidthKey = "localWorkspaceSidebarWidthV1"

  /// Collapsing while the sidebar holds the keyboard hands focus to the tasks,
  /// rather than leaving it on a pane that is no longer on screen.
  func toggleSidebar() {
    isSidebarVisible.toggle()
    if !isSidebarVisible, keyboardFocusArea == .sidebar {
      requestKeyboardFocus(.tasks)
    }
  }

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
  /// Where the sidebar's keyboard cursor is, as a row id from
  /// `WorkspaceSidebarOutline`.
  ///
  /// Separate from `selectedListID` because two of the rows — Focus and the
  /// timeline — are not lists and landing on one must not change what the
  /// main pane is showing. It also fixes the pinned-list duplicate: the same
  /// list is drawn twice, and only a row id can say which of the two you are
  /// standing on.
  var sidebarCursorID: String?
  var expandedFolderIDs: Set<String> = []
  var scopeTaskID: String?
  var nestedLists: [TaskOutlineItem] = []
  var archivedNestedLists: [WorkspaceTask] = []
  var creationIsNested = false
  var creationTaskParentID: String?
  var creationTaskListID: String?
  var selectedTaskID: String? {
    didSet {
      let has = selectedTaskID != nil
      if hasSelectedTask != has { hasSelectedTask = has }
    }
  }
  /// Whether anything is selected, which changes far less often than what is.
  /// The window shell reads this, so moving the selection does not redraw it.
  private(set) var hasSelectedTask = false
  /// Stands for where every list, folder and nested list sits, so the sidebar
  /// can animate a move without building arrays to compare on each render.
  /// Set by `reloadNestedListsNow()`.
  var sidebarLayoutKey = 0
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
  /// Asks the app shell for the always-on-top companion. A counter rather than
  /// a flag: the button and the F key both just want it shown, again.
  ///
  /// The shell, not the window: the companion's whole job is to be the thing
  /// still on screen once the window is not, so it cannot be owned by a view
  /// that closes with it.
  var focusFloatRequest = 0 {
    didSet { onFocusFloatRequested?() }
  }
  /// Called when the floating companion is asked for.
  @ObservationIgnored var onFocusFloatRequested: (() -> Void)?
  /// Bumped when a block is started deliberately, to hand the session over to
  /// the tray and put the window away.
  ///
  /// Focus is for working somewhere else. Leaving the window up in front of
  /// the thing you just committed to doing means the first act of every block
  /// is getting rid of it — so the app does that itself, and the tray becomes
  /// the surface the session runs on.
  var focusHandoffRequest = 0 {
    didSet { onFocusHandoffRequested?() }
  }
  /// Called when a deliberate start should close the window and raise the tray.
  @ObservationIgnored var onFocusHandoffRequested: (() -> Void)?
  /// Whether finishing a block should stop and ask how it went. Read at the
  /// moment of asking rather than stored, so changing the preference takes
  /// effect on the next block rather than the next launch.
  @ObservationIgnored var asksHowEachBlockWent: () -> Bool = { true }
  /// Called when something is finished, wherever it was finished from. The
  /// celebration lives in the app shell, so the model reports the occasion
  /// rather than staging it.
  @ObservationIgnored var onCompletion: ((CompletionEvent) -> Void)?
  /// The command palette. Opens on ⌘K and is the one surface that lists every
  /// key the workspace answers to, whether or not it can run it for you.
  var showsCommandPalette = false
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
  /// The running block.
  ///
  /// This used to tell the app shell when a session ended, so the always-on-top
  /// strip could be taken down from outside any window. The tray is not taken
  /// down: finishing a block is the moment you want to see what is next, and
  /// the tray is the surface the scoring happened on.
  var activeFocusSession: FocusSession?
  /// What launch did with the block left over from last time. Read by the
  /// focus screen so a session that was closed out says so, rather than simply
  /// not being there.
  var staleFocusResolution: StaleFocusResolution = .keep
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
  /// Which surface asked the question, so the answer is offered where the
  /// block was finished. The summoned panel has to be able to close a block
  /// on its own — needing the window for it is exactly what stops the panel
  /// being usable as the only surface.
  var focusCompletionSurface: FocusCompletionSurface = .window
  /// The pending block, but only for the surface that asked.
  var windowFocusCompletion: PendingFocusCompletion? {
    focusCompletionSurface == .window ? pendingFocusCompletion : nil
  }
  var panelFocusCompletion: PendingFocusCompletion? {
    focusCompletionSurface == .panel ? pendingFocusCompletion : nil
  }
  /// What the last scored block earned, so the UI can show it and move on.
  var lastFocusAward: FocusAward?
  /// Written only by `reloadFocus()`; read by the panel and the prompt.
  var focusPoints: FocusPointsSummary = .zero
  var focusHistoryDate = Date.now
  /// Today's finished blocks, always today's. `focusHistory` follows the
  /// timeline's own day picker, so a surface that means "today" cannot read it
  /// — steering the timeline to last Tuesday would change what it said.
  private(set) var todayWorkBlocks: [FocusWorkBlock] = []
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

  /// How a role colour is resolved. Set by `AppDelegate` from the preferences
  /// manager, so every workspace surface can reach the theme through the one
  /// object it already has in the environment rather than each of them
  /// reaching for `AppCoordinator` — or, as they did, for SwiftUI's stock
  /// `.green` and `.orange`, which do not flip with the theme and are not the
  /// colours the app is set in.
  @ObservationIgnored var themeColorResolver: ((AppThemeColorToken) -> Color)?

  func themeColor(_ token: AppThemeColorToken) -> Color {
    themeColorResolver?(token) ?? token.fallback
  }

  init(legacyStore: LocalTaskStore) {
    self.legacyStore = legacyStore
    do {
      self.store = try WorkspaceStore()
      try self.store?.recoverInterruptedFocus()
      // And then settle it: a block paused on a day that is over is finished
      // here rather than restored as the running session. Without this every
      // quit left a paused block behind that nothing ever cleared.
      self.staleFocusResolution = try self.store?.resolveStaleFocusSession() ?? .keep
      try load()
      // Ranked here rather than in the background: the first screen is the
      // day, and it should not paint empty and then fill.
      reloadNextUpNow()
      restoreSuggestedContext()
      watchForExternalWrites()
    } catch {
      self.store = nil
      self.errorMessage = error.localizedDescription
    }
  }

  var selectedList: TaskList? { lists.first { $0.id == selectedListID } }
  /// Where quick capture lands. Found by role, so renaming it does not move it.
  var inboxList: TaskList? { lists.first { $0.systemRole == .inbox } }
  var selectedFolder: ListFolder? { folders.first { $0.id == selectedFolderID } }
  /// Reports a finished task to whatever is staging celebrations, counting the
  /// day's remaining work so the last one of the day can be marked as such.
  func celebrateCompletion(of task: WorkspaceTask) {
    guard let onCompletion else { return }
    let remaining = dayItems.filter { $0.task.id != task.id }.count + 1
    guard let event = completionEvent(for: task, remainingVisibleTaskCount: remaining) else { return }
    onCompletion(event)
  }

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
    // A folder scope has no selected list on purpose, so it must not be read
    // as "nothing is selected" and repaired into one on the next reload.
    let hasFolderScope = selectedFolderID.map { id in folders.contains { $0.id == id } } ?? false
    if !isEverythingSelected && !hasFolderScope
      && (selectedListID == nil || !lists.contains(where: { $0.id == selectedListID })) {
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
    // Rows can have changed anywhere, including a board's column layout.
    boardColumnConfigurations = nil
    reloadFocus()
    refresh([.outline, .sidebar, .dailies, .nextUp])
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
    // Any other way of choosing a row moves the keyboard cursor there too,
    // by letting it fall back to whatever is now selected.
    sidebarCursorID = nil

    guard lists.contains(where: { $0.id == id }) else { return }
    taskEditor.flush()
    leaveFullPaneScreens()
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
    // Any other way of choosing a row moves the keyboard cursor there too,
    // by letting it fall back to whatever is now selected.
    sidebarCursorID = nil

    taskEditor.flush()
    leaveFullPaneScreens()
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
    // Any other way of choosing a row moves the keyboard cursor there too,
    // by letting it fall back to whatever is now selected.
    sidebarCursorID = nil
    enterFolderScope(folder)
  }

  func enterTask(_ task: WorkspaceTask) {
    taskEditor.flush()
    if isEverythingSelected {
      isEverythingSelected = false
      UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
      selectedListID = task.listId
      newTaskListID = task.listId
    }
    // Going into a task means going into the list that holds it, so a folder
    // scope ends here the same way Everything does.
    if selectedFolderID != nil {
      selectedFolderID = nil
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
    if mode == .today { dayPresentationCount += 1 }
    viewMode = mode
    if isEverythingSelected { reloadOutline(refreshSidebar: false) }
  }

  func leaveTaskScope() {
    guard let task = scopeTask else { return }
    scopeTaskID = task.parentTaskId
    selectedTaskID = task.id
    reloadOutline(refreshSidebar: false)
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

  /// Today's dailies, joined to their tasks and contributions. Reloaded rather
  /// than computed, because every row needs a database round trip and the list
  /// is read on every render of the dailies surface.
  var dailyItems: [DailyItem] = []
  /// Today's work and what put each task there: the Today column, plus
  /// anything due today, overdue, or starting today. Derived on every
  /// `reloadNextUp()` rather than written into the column, so clearing the
  /// column still clears the plan and tomorrow's day is not yesterday's.
  var todayPlan: [DayPlanEntry] = []
  /// Today, resolved to tasks. Stored rather than computed: it is read on
  /// every render of the day and of the menu bar, and resolving it used to
  /// cost a query per row. Rebuilt by `rebuildDayItems()`.
  var dayItems: [DayItem] = []
  /// Tasks finished and time logged today, against the same for the week so
  /// far. Refreshed alongside the day rather than on a ticker — it only moves
  /// when work is finished or logged, which is exactly when the day reloads.
  var workProgress: WorkProgress = .empty
  /// What the done rail shows: tasks closed within its window, newest first.
  /// Loaded only while the rail is open — see `reloadCompleted()`.
  var completedTasks: [WorkspaceTask] = []
  /// The row the rail's cursor is on, or nil for "the newest thing finished".
  var doneCursorID: String?
  /// What the focus screen offers, and why. Nil when there is nothing to do —
  /// which is a real state worth rendering, not an error.
  var nextUp: ScoredNextUp?
  /// Everything worth doing, most important first. Focus mode presents this as
  /// a ladder: rung 0 at the foot, less important work above it.
  var focusLadder: [ScoredNextUp] = []
  /// Which rung the cursor is on. Climbing means accepting less priority.
  var focusLadderIndex = 0
  /// Whether the ladder carries hand-placed positions. Set with the ranking.
  var hasManualFocusOrder = false
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
  /// Bumped whenever Today is asked for afresh, so the pane resets its search
  /// field the way a fresh summon resets the panel's.
  var dayPresentationCount = 0
  /// Bumped when a key the day pane owns arrives while its field does not have
  /// the caret — after clicking a row, say. The pane keeps its own selection,
  /// so moving the outline's instead looks exactly like nothing happening.
  var dayFieldFocusRequest = 0

  var visibleNavigationTasks: [WorkspaceTask] {
    // Mid-`perform`, a scope change has only been marked. Whoever asks what is
    // on screen wants the answer after it, not before.
    if !pendingRefresh.isEmpty { flushPendingRefresh() }
    return switch viewMode {
    case .today: dayItems.map(\.task)
    case .outline: outline.map(\.task)
    case .board: boardColumns.flatMap { tasks(in: $0) }
    case .matrix: boardTasks
    }
  }

  func toggleTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setStatus(task.status == .open ? .completed : .open, for: task.id)
      if task.status == .open { celebrateCompletion(of: task) }
      // An ordinary task's status is not something the sidebar shows: its
      // counts include finished tasks, and only lists are drawn there.
      reloadOutline(refreshSidebar: task.isList)
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
      reloadOutline(refreshSidebar: task.isList)
    }
  }

  func indentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.indentTask(id: task.id)
      reloadOutline(refreshSidebar: task.isList)
    }
  }

  func outdentTask(_ task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.outdentTask(id: task.id)
      reloadOutline(refreshSidebar: task.isList)
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

  /// Marks the main pane stale; see `refresh(_:)`. Pass `refreshSidebar:
  /// false` when the change cannot have touched a list or a count.
  func reloadOutline(refreshSidebar: Bool = true) {
    refresh(refreshSidebar ? [.outline, .sidebar] : .outline)
  }

  func reloadBoard() {
    refresh(.board)
  }

  func reloadOutlineNow() {
    guard let store else {
      outline = []
      boardTasks = []
      boardTaskColumns = [:]
      matrixPositions = [:]
      return
    }
    do {
      var items: [TaskOutlineItem]
      if isEverythingSelected || folderScopeListIDs != nil {
        items = viewMode == .outline
          ? try actionableScopeTasks(store: store).map { TaskOutlineItem(task: $0, depth: 0) } : []
      } else if let selectedListID {
        let tree = try listTrees(for: [selectedListID], store: store)[selectedListID]
        let parentID = scopeTaskID ?? selectedList.flatMap {
          tree?.visibleRootParentTaskID(registeredRootId: $0.visibleRootTaskId)
        }
        items = tree?.visibleOutline(under: parentID) ?? []
      } else {
        items = []
      }
      if hidesCompletedTasks { items.removeAll { $0.task.status != .open } }
      if outline != items { outline = items }
      reloadBoardNow()
      // The rail is a view of the same writes. Hooked in here rather than at
      // every mutation because this is the one funnel they all pass through,
      // and it costs nothing while the rail is closed.
      reloadCompleted()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Every open, doable task in a combined scope, in sidebar order: the same
  /// answer as `WorkspaceStore.actionableTasks`, shaped from this refresh's
  /// shared reads.
  private func actionableScopeTasks(store: WorkspaceStore) throws -> [WorkspaceTask] {
    let open = lists.filter { $0.completedAt == nil }
    let scoped: [TaskList]
    if let ids = folderScopeListIDs {
      let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      scoped = ids.compactMap { byID[$0] }
    } else {
      scoped = open
    }
    let trees = try listTrees(for: scoped.map(\.id), store: store)
    return scoped.flatMap { trees[$0.id]?.actionableTasks(visibleRootTaskId: $0.visibleRootTaskId) ?? [] }
  }

  var boardConfigurationKey: String {
    if isEverythingSelected { return "everything/root" }
    if let selectedFolderID { return "folder:\(selectedFolderID)/root" }
    return "\(selectedListID ?? "none")/\(scopeTaskID ?? "root")"
  }

  func reloadBoardNow() {
    defer { rebuildBoardIndex() }
    guard let store else {
      boardTasks = []
      boardCrossColumnTasks = []
      boardDescendants = [:]
      boardTaskParents = [:]
      boardParentTaskID = nil
      boardTreeTasks = []
      return
    }
    do {
      var tasks: [WorkspaceTask]
      let parentTaskID: String?
      if isEverythingSelected || folderScopeListIDs != nil {
        parentTaskID = nil
        tasks = try actionableScopeTasks(store: store)
      } else if let selectedListID {
        let tree = try listTrees(for: [selectedListID], store: store)[selectedListID]
        parentTaskID = scopeTaskID ?? selectedList.flatMap {
          tree?.visibleRootParentTaskID(registeredRootId: $0.visibleRootTaskId)
        }
        tasks = tree?.children(of: parentTaskID) ?? []
      } else {
        parentTaskID = nil
        tasks = []
      }
      if boardParentTaskID != parentTaskID { boardParentTaskID = parentTaskID }
      tasks.removeAll { ($0.isList && $0.archivedAt != nil) || (hidesCompletedTasks && $0.status != .open) }
      let boardIDs = Set(tasks.map(\.id))
      var descendants: [String: [TaskOutlineItem]] = Dictionary(
        uniqueKeysWithValues: tasks.map { ($0.id, []) })
      var parents: [String: WorkspaceTask] = [:]
      let listIDs = Array(Set(tasks.map(\.listId)))
      let trees = try listTrees(for: listIDs, store: store)
      for listID in listIDs {
        var ancestors: [TaskOutlineItem] = []
        for item in trees[listID]?.visibleOutline() ?? [] {
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
      var treeIDs = Set<String>()
      let treeTasks = (tasks + tasks.flatMap { root in
        descendants[root.id, default: []].map(\.task)
      }).filter { treeIDs.insert($0.id).inserted }
      let metadata = try store.boardMetadata(for: treeTasks.map(\.id))
      let columnsByTask = metadata.columns
      let crossColumn = treeTasks.filter { task in
        if hidesCompletedTasks && task.status != .open { return false }
        guard !task.isList else { return false }
        guard !boardIDs.contains(task.id), let parent = parents[task.id] else { return false }
        let taskColumn = columnsByTask[task.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
        let parentColumn = columnsByTask[parent.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
        return taskColumn != parentColumn
      }
      let columns = try resolvedBoardColumns(usedColumnIDs: Set(columnsByTask.values), store: store)
      // Assigned only when they differ, so a refresh that changed nothing on
      // the board does not redraw every card.
      boardTreeTasks = treeTasks
      if boardTasks != tasks { boardTasks = tasks }
      if boardDescendants != descendants { boardDescendants = descendants }
      if boardTaskParents != parents { boardTaskParents = parents }
      if boardTaskColumns != columnsByTask { boardTaskColumns = columnsByTask }
      if boardCrossColumnTasks != crossColumn { boardCrossColumnTasks = crossColumn }
      if boardColumns != columns { boardColumns = columns }
      if matrixPositions != metadata.positions { matrixPositions = metadata.positions }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// The current scope's columns, plus any column a card on it is filed under
  /// that the scope's own layout does not list.
  private func resolvedBoardColumns(usedColumnIDs: Set<String>, store: WorkspaceStore) throws -> [WorkspaceKanbanColumn] {
    let key = boardConfigurationKey
    // The store call also seeds a layout for a scope that has none, so it is
    // made again for a scope this cache has not seen.
    if boardColumnConfigurations?[key] == nil {
      let legacy = UserDefaults.standard.dictionary(forKey: Self.kanbanColumnsKey) as? [String: Data] ?? [:]
      boardColumnConfigurations = try store.kanbanBoardConfigurations(legacy: legacy, currentKey: key)
    }
    let configurations = boardColumnConfigurations ?? [:]
    func decode(_ key: String) -> [WorkspaceKanbanColumn]? {
      configurations[key].flatMap { try? JSONDecoder().decode([WorkspaceKanbanColumn].self, from: $0) }
    }
    var columns: [WorkspaceKanbanColumn]
    if let decoded = decode(key), !decoded.isEmpty {
      columns = decoded
    } else {
      columns = WorkspaceKanbanColumn.blitzitDefaults
    }
    if isEverythingSelected {
      for list in lists {
        guard let listColumns = decode("\(list.id)/root") else { continue }
        for column in listColumns where usedColumnIDs.contains(column.id)
          && !columns.contains(where: { $0.id == column.id }) {
          columns.append(column)
        }
      }
    } else {
      let globalColumns = decode("everything/root") ?? []
      for column in globalColumns + WorkspaceKanbanColumn.blitzitDefaults
        where usedColumnIDs.contains(column.id)
          && !columns.contains(where: { $0.id == column.id }) {
        columns.append(column)
      }
    }
    return columns
  }

  /// Some Checkvist imports have a single transport root repeating the list
  /// name. Its children are the visible list roots in both single-list and
  /// Everything scopes, while their actual parent IDs remain unchanged.
  func visibleRootParentTaskID(for list: TaskList, store: WorkspaceStore) throws -> String? {
    try store.visibleRootParentTaskID(for: list)
  }

  func uniqueColumnID(base: String, in columns: [WorkspaceKanbanColumn]) -> String {
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
      if let today = Calendar.current.dateInterval(of: .day, for: .now) {
        todayWorkBlocks = try store.focusWorkBlocks(in: today)
      }
      if let day = Calendar.current.dateInterval(of: .day, for: focusHistoryDate) {
        focusHistory = try store.focusWorkBlocks(in: day)
        focusHistoryAwards = Dictionary(
          try store.focusAwards(onDayOf: focusHistoryDate).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      }
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
