import AppKit
import Foundation
import Observation
import PriorityCore
import PrioritySync
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
  static let everythingScopeKey = "localWorkspaceEverythingScopeV1"
  /// Names the service a task was imported from, and so which identifiers its
  /// `sourceId` values belong to. Stored on the task, hence not free to change.
  static let checkvistSourceSystem = "checkvist"
  static let legacyOfflineSourceSystem = "priority-offline"

  /// Internal rather than private so `WorkspaceViewModel+Dailies.swift` —
  /// the same type, split only for size — can reach it.
  @ObservationIgnored var store: WorkspaceStore?
  @ObservationIgnored let legacyStore: LocalTaskStore
  /// Title, task id, list name, due date, all-day → the created event's id,
  /// which is what lets Priority notice later that it was cleared.
  @ObservationIgnored var googleCalendarEventCreator:
    ((String, String, String, Date?, Bool) async throws -> String?)?
  /// Called with a task id and the calendar event now standing for it.
  @ObservationIgnored var onGoogleCalendarEventCreated: ((String, String) -> Void)?
  /// Opens the Diagnostics sheet, which the coordinator owns rather than the
  /// workspace.
  @ObservationIgnored var onShowDiagnostics: (() -> Void)?
  /// Puts a passing line in the status bar, which reads the coordinator's
  /// `statusMessage` rather than anything on the workspace. For feedback a
  /// key owes when what it did is not visible where you are looking.
  @ObservationIgnored var onStatusMessage: ((String) -> Void)?
  /// Called after any local write, so the Google Tasks mirror can push it.
  /// Coalesced on the far side — this fires far more often than it syncs.
  @ObservationIgnored var onLocalWrite: (() -> Void)?
  /// The watch for writes made by another process. See
  /// `WorkspaceViewModel+ExternalWrites.swift`.
  /// Nil until the store opens. Observed, so the status bar follows it.
  var syncSession: SyncSession?
  @ObservationIgnored var externalWriteToken: Int?
  @ObservationIgnored var externalWriteTimer: Timer?
  @ObservationIgnored var externalWriteCheckInFlight = false
  let taskEditor = WorkspaceTaskEditor()

  private(set) var workspace: Workspace?
  private(set) var folders: [ListFolder] = []
  private(set) var lists: [TaskList] = []
  private(set) var archivedLists: [TaskList] = []
  /// The outline and board state below is written only by
  /// `WorkspaceViewModel+Loading.swift`; internal rather than `private(set)`
  /// so that file can.
  var outline: [TaskOutlineItem] = [] {
    didSet {
      outlineByList = Dictionary(grouping: outline) { $0.task.listId }
      outlineOpenCount = outline.reduce(0) { $0 + ($1.task.status == .open ? 1 : 0) }
      let parents = TaskOutlineFolding.parentIDs(outline)
      if outlineParentIDs != parents { outlineParentIDs = parents }
      refoldOutline()
    }
  }
  /// The outline as drawn: `outline` with every folded task's branch taken
  /// out. What the pane lists and what the arrow keys walk.
  private(set) var outlineRows: [TaskOutlineItem] = []
  /// The outline's rows that have subtasks, folded or not.
  private(set) var outlineParentIDs: Set<String> = []
  /// The outline grouped by list and its open count, derived once per reload
  /// rather than on every render of the combined outline.
  private(set) var outlineByList: [String: [TaskOutlineItem]] = [:]
  private(set) var outlineOpenCount = 0
  var boardTasks: [WorkspaceTask] = []
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
  var boardCrossColumnTasks: [WorkspaceTask] = []
  var boardDescendants: [String: [TaskOutlineItem]] = [:]
  var boardTaskParents: [String: WorkspaceTask] = [:]
  /// The actual parent whose children are visible on the board. A Checkvist
  /// import can contain one root project whose title is identical to its list;
  /// that project is a transport wrapper, not useful work to show as the
  /// board's only card.
  var boardParentTaskID: String?
  var boardColumns: [WorkspaceKanbanColumn] = WorkspaceKanbanColumn.blitzitDefaults
  var boardTaskColumns: [String: String] = [:]
  var boardTasksByColumn: [String: [WorkspaceTask]] = [:]
  var boardColumnsByID: [String: WorkspaceKanbanColumn] = [:]
  var boardVisibleTaskIDs: Set<String> = []
  var matrixPositions: [String: TaskMatrixPosition] = [:]
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

  /// Whether the right dock — the inspector and the done rail, as tabs — takes
  /// a column. Persisted for the sidebar's reason: whether you want it on
  /// screen is a way of working, not a decision to make again every launch.
  /// Until the dock existed, this was the done rail's own flag, and its value
  /// carries over.
  var isRightDockVisible = UserDefaults.standard.object(forKey: WorkspaceViewModel.rightDockVisibleKey) as? Bool
    ?? UserDefaults.standard.bool(forKey: WorkspaceViewModel.doneRailVisibleKey) {
    didSet { UserDefaults.standard.set(isRightDockVisible, forKey: Self.rightDockVisibleKey) }
  }

  /// Which of the dock's tabs is showing. Persisted with the dock.
  var rightDockTab = WorkspaceDockTab(
    rawValue: UserDefaults.standard.string(forKey: WorkspaceViewModel.rightDockTabKey) ?? "") ?? .done {
    didSet { UserDefaults.standard.set(rightDockTab.rawValue, forKey: Self.rightDockTabKey) }
  }

  /// An explicit width with a handle of its own, for the sidebar's reason: a
  /// pane that takes a share of whatever the window has spare is a pane whose
  /// width you cannot set. Seeded from the done rail's old width.
  var rightDockWidth: CGFloat = {
    let defaults = UserDefaults.standard
    let stored = defaults.double(forKey: WorkspaceViewModel.rightDockWidthKey)
    let legacy = defaults.double(forKey: WorkspaceViewModel.doneRailWidthKey)
    let width = stored > 0 ? stored : legacy
    guard width > 0 else { return WorkspaceViewModel.defaultRightDockWidth }
    return min(max(CGFloat(width), WorkspaceViewModel.minRightDockWidth), WorkspaceViewModel.maxRightDockWidth)
  }() {
    didSet {
      guard rightDockWidth != oldValue else { return }
      UserDefaults.standard.set(Double(rightDockWidth), forKey: Self.rightDockWidthKey)
    }
  }

  static let minRightDockWidth: CGFloat = 210
  static let maxRightDockWidth: CGFloat = 480
  static let defaultRightDockWidth: CGFloat = 280
  private static let rightDockVisibleKey = "localWorkspaceRightDockVisibleV1"
  private static let rightDockTabKey = "localWorkspaceRightDockTabV1"
  private static let rightDockWidthKey = "localWorkspaceRightDockWidthV1"
  private static let doneRailWidthKey = "localWorkspaceDoneRailWidthV1"

  static let minSidebarWidth: CGFloat = 140
  static let maxSidebarWidth: CGFloat = 420
  static let defaultSidebarWidth: CGFloat = 185
  private static let sidebarVisibleKey = "localWorkspaceSidebarVisibleV1"
  private static let sidebarWidthKey = "localWorkspaceSidebarWidthV1"
  private static let leftDockTabKey = "localWorkspaceLeftDockTabV1"

  /// Which of the left dock's tabs is showing: the lists, or the agent.
  /// Persisted with the dock, for the right dock's reason. Whether the dock
  /// is open at all is still `isSidebarVisible`, a name kept from when the
  /// sidebar was all it held, so that setting carries over.
  var leftDockTab = WorkspaceLeftDockTab(
    rawValue: UserDefaults.standard.string(forKey: WorkspaceViewModel.leftDockTabKey) ?? "") ?? .lists {
    didSet { UserDefaults.standard.set(leftDockTab.rawValue, forKey: Self.leftDockTabKey) }
  }

  /// The agent panel's thread. See `WorkspaceAgentSession`.
  let agent = WorkspaceAgentSession()
  /// Asks the agent panel's message field for the keyboard.
  var agentInputFocusRequest = 0
  /// The agent panel's field or one of its approval cards has the keyboard.
  /// The window's key monitor reads it to leave keys to the panel — Return on
  /// a card approves it, and must not open a task behind it instead.
  @ObservationIgnored var agentHoldsKeyboard = false

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
  /// The bottom dock, which holds the progress graph. Persisted like the
  /// other docks, so it is only ever put away on purpose.
  var isBottomDockVisible = UserDefaults.standard.bool(forKey: WorkspaceViewModel.bottomDockVisibleKey) {
    didSet { UserDefaults.standard.set(isBottomDockVisible, forKey: Self.bottomDockVisibleKey) }
  }
  var bottomDockHeight: CGFloat = {
    let stored = UserDefaults.standard.double(forKey: WorkspaceViewModel.bottomDockHeightKey)
    return stored > 0
      ? min(max(CGFloat(stored), WorkspaceViewModel.minBottomDockHeight), WorkspaceViewModel.maxBottomDockHeight)
      : 180
  }() {
    didSet {
      guard bottomDockHeight != oldValue else { return }
      UserDefaults.standard.set(Double(bottomDockHeight), forKey: Self.bottomDockHeightKey)
    }
  }
  var progressPeriod = TaskProgressPeriod(
    rawValue: UserDefaults.standard.string(forKey: WorkspaceViewModel.progressPeriodKey) ?? "") ?? .month {
    didSet { UserDefaults.standard.set(progressPeriod.rawValue, forKey: Self.progressPeriodKey) }
  }
  static let minBottomDockHeight: CGFloat = 120
  static let maxBottomDockHeight: CGFloat = 420
  private static let bottomDockVisibleKey = "localWorkspaceBottomDockVisibleV1"
  private static let bottomDockHeightKey = "localWorkspaceBottomDockHeightV1"
  private static let progressPeriodKey = "localWorkspaceProgressPeriodV1"
  /// Tasks whose subtasks are folded away — in the outline, on a board card,
  /// and on the subtask rows drawn on one; one set, so a branch put away in
  /// one view stays put away in the other. On the model rather than the row,
  /// because the arrow keys walk the rows that are showing and have to know
  /// which ones are not. Persisted, as Checkvist keeps a fold.
  var foldedTaskIDs = Set(UserDefaults.standard.stringArray(forKey: WorkspaceViewModel.foldedTasksKey) ?? []) {
    didSet {
      guard foldedTaskIDs != oldValue else { return }
      UserDefaults.standard.set(Array(foldedTaskIDs).sorted(), forKey: Self.foldedTasksKey)
      refoldOutline()
    }
  }
  private static let foldedTasksKey = "localWorkspaceFoldedTasksV1"

  private func refoldOutline() {
    let rows = TaskOutlineFolding.visible(outline, folded: foldedTaskIDs)
    if outlineRows != rows { outlineRows = rows }
  }

  /// The column the arrow keys are in. A subtask row counts as being in the
  /// column of the card it is drawn on, not the column its own card would
  /// sit in; and the column the keys were last walking wins, since a subtask
  /// can be both a row on its parent's card and a card elsewhere.
  var activeBoardColumnID: String? {
    let focused = boardColumns.first(where: { $0.id == focusedBoardColumnID })
    if let selectedTaskID {
      if let focused, boardRowIDs(in: focused).contains(selectedTaskID) { return focused.id }
      if let columnID = boardColumnID(forTaskID: selectedTaskID) { return columnID }
      if let owner = boardCardID(owning: selectedTaskID), let columnID = boardColumnID(forTaskID: owner) {
        return columnID
      }
    }
    return focused?.id ?? boardColumns.first?.id
  }
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
  /// The palette, search, the list finder and the rest of what used to be
  /// sheets. One at a time, by construction — see `WorkspaceOverlay.swift`.
  var activeOverlay: WorkspaceOverlay?
  @ObservationIgnored var overlayKeyHandler: WorkspaceOverlayKeyHandler?
  /// Where the overlay's card is, in the window content's top-left space.
  /// The window's mouse monitor reads it to tell a click on the card from a
  /// click beside it; see `MainWindowController`.
  @ObservationIgnored var overlayPanelFrame: CGRect?
  var searchQuery = "" { didSet { refreshSearchResults() } }
  var searchIncludesCompleted = false { didSet { refreshSearchResults() } }
  /// Written only by `refreshSearchResults()`; internal rather than
  /// `private(set)` so that method can live in `WorkspaceViewModel+Search.swift`.
  var searchResults: [TaskSearchResult] = []
  var selectedSearchResultID: String?
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
  /// Not observed: it moves on every key, and nothing should redraw for that.
  /// What the status bar shows is `pendingKeyPrefix`, which moves only when
  /// the half-typed sequence does.
  @ObservationIgnored var desktopShortcutSequence = DesktopShortcutSequence() {
    didSet {
      let prefix = desktopShortcutSequence.prefix
      if pendingKeyPrefix != prefix { pendingKeyPrefix = prefix }
    }
  }
  /// The first key of a two-letter sequence, held while the second is awaited.
  private(set) var pendingKeyPrefix = ""
  var hidesCompletedTasks = false
  var taskInsertionReference: WorkspaceTask?
  var taskInsertionAbove = false
  var taskInsertionIsChild = false
  /// Written only by `WorkspaceViewModel+KeyboardFocus.swift`; internal rather
  /// than `private(set)` so those methods can live there.
  var keyboardFocusArea: WorkspaceFocusArea = .tasks
  var requestedFocusArea: WorkspaceFocusArea = .tasks
  /// Plain navigation keys only belong to the focused list/board surface.
  /// Buttons, menus, and other controls keep their native keyboard behavior.
  var keyboardNavigationSurfaceActive = false
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
  /// Told after rows changed under the app — a sync pull or another
  /// process's write — beside the reload of the task tree. The theme library
  /// and the synced choice of theme listen here.
  @ObservationIgnored var onWorkspaceChangedElsewhere: (() -> Void)?

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
      startSync()
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
}
