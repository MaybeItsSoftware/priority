import Foundation
import TaktCore
import TaktWorkspace

/// Reading the main pane's outline and board out of the store. Split from
/// `WorkspaceViewModel.swift` for size — it is the same type, and these are
/// what `WorkspaceViewModel+Refresh.swift` calls when a scope is stale.
extension WorkspaceViewModel {
  private static let kanbanColumnsKey = "localWorkspaceKanbanColumnsV1"

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
    nextCompletionExpiry = nil
    defer { scheduleCompletionExpiry() }
    do {
      var items: [TaskOutlineItem] = []
      // A combined scope's outline is only gathered while the outline is
      // showing; a single list's always is.
      if let scope = currentScope, !isMultiListScope || viewMode == .outline {
        try ensureScopeRead(scope, store: store)
        if let shaped = scopeCache.outline(for: scope, options: scopeShapeOptions, now: Date()) {
          items = shaped.items
          noteCompletionExpiry(shaped.expiry)
        }
      }
      if outline != items { outline = items }
      // The `defer` above schedules the expiry once for both.
      reloadBoardNow(schedulesCompletionExpiry: false)
      // The rail is a view of the same writes. Hooked in here rather than at
      // every mutation because this is the one funnel they all pass through,
      // and it costs nothing while the rail is closed.
      reloadCompleted()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  var boardConfigurationKey: String {
    // A filter list is Everything narrowed, so it keeps Everything's columns.
    if isEverythingSelected || selectedFilterListID != nil { return "everything/root" }
    if let selectedFolderID { return "folder:\(selectedFolderID)/root" }
    return "\(selectedListID ?? "none")/\(scopeTaskID ?? "root")"
  }

  /// Whether the main pane is drawing the board's cards: the board itself,
  /// or the matrix, which places the same cards.
  var isBoardOnScreen: Bool { viewMode == .board || viewMode == .matrix }

  /// Called when the view mode changes. A board set aside while Today or the
  /// outline was showing is read now that it is wanted — inside a block, with
  /// the block's refresh; outside one, on the next turn, unless the change
  /// arrives with a reload of its own first, as every scope change does.
  func viewModeDidChange() {
    guard boardIsStale, isBoardOnScreen else { return }
    pendingRefresh.insert(.board)
    guard refreshDepth == 0 else { return }
    Task { @MainActor [weak self] in self?.flushPendingRefresh() }
  }

  /// Reads a board set aside, for a caller that wants its cards whatever is
  /// on screen — the Today column's order when focus starts from Today.
  func loadBoardIfStale() {
    guard boardIsStale else { return }
    reloadBoardNow(force: true)
  }

  /// - Parameters:
  ///   - schedulesCompletionExpiry: false when the outline reload that called
  ///     this schedules it itself, so one reload arms one timer.
  ///   - force: reads a combined scope's board even when nothing on screen
  ///     draws it.
  func reloadBoardNow(schedulesCompletionExpiry: Bool = true, force: Bool = false) {
    defer {
      rebuildBoardIndex()
      if schedulesCompletionExpiry { scheduleCompletionExpiry() }
    }
    guard let store else {
      clearBoard()
      boardParentTaskID = nil
      boardIsStale = false
      return
    }
    // Everything's board is every list's open work: thousands of cards and
    // their trees crossing from the core on each edit. Today sits on
    // Everything and never draws it, so it is set aside until a view that
    // does is shown (`viewModeDidChange`). Emptied rather than left as it
    // was, so nothing reads an old board as current.
    if !force, isEverythingSelected || folderScopeListIDs != nil, !isBoardOnScreen {
      clearBoard()
      if boardParentTaskID != nil { boardParentTaskID = nil }
      // The columns are kept, for the Today column a task can be filed in
      // from Today. Without the cards, only the layout's own.
      if let read = try? readBoardColumns(store: store) { applyBoardColumns(read) }
      boardIsStale = true
      return
    }
    boardIsStale = false
    do {
      var shape = WorkspaceBoardShape.empty
      var generation: Int?
      if let scope = currentScope {
        try ensureScopeRead(scope, store: store)
        if let shaped = scopeCache.board(for: scope, options: scopeShapeOptions, now: Date()) {
          shape = shaped.board
          generation = shaped.generation
          noteCompletionExpiry(shaped.expiry)
        }
      }
      let columnRead = try readBoardColumns(store: store)
      // The shape on screen already, kept: nothing to compare, nothing to
      // assign. Otherwise assigned only where it differs, so a refresh that
      // changed nothing on the board does not redraw every card.
      if generation == nil || generation != boardShapeGeneration {
        if boardParentTaskID != shape.parentTaskID { boardParentTaskID = shape.parentTaskID }
        boardTreeTasks = shape.treeTasks
        if boardTasks != shape.cards { boardTasks = shape.cards }
        if boardDescendants != shape.descendants { boardDescendants = shape.descendants }
        if boardTaskParents != shape.parents { boardTaskParents = shape.parents }
        if boardTaskColumns != shape.columns { boardTaskColumns = shape.columns }
        if boardCrossColumnTasks != shape.crossColumnTasks { boardCrossColumnTasks = shape.crossColumnTasks }
        if matrixPositions != shape.positions { matrixPositions = shape.positions }
      }
      applyBoardColumns(columnRead)
      boardShapeGeneration = generation
    } catch {
      boardShapeGeneration = nil
      errorMessage = error.localizedDescription
    }
  }

  /// Empties the cards and what was read about them, assigning only what
  /// is not already empty.
  private func clearBoard() {
    boardShapeGeneration = nil
    boardTreeTasks = []
    if !boardTasks.isEmpty { boardTasks = [] }
    if !boardCrossColumnTasks.isEmpty { boardCrossColumnTasks = [] }
    if !boardDescendants.isEmpty { boardDescendants = [:] }
    if !boardTaskParents.isEmpty { boardTaskParents = [:] }
    if !boardTaskColumns.isEmpty { boardTaskColumns = [:] }
    if !matrixPositions.isEmpty { matrixPositions = [:] }
  }

  /// How long a task you have just ticked off stays put before it goes, so
  /// the tick is seen and a mis-tick can be taken back where it happened.
  static let completedLingerInterval = WorkspaceScopeShaping.completedLingerInterval

  /// Keeps the soonest lingering completion the pane has to reload for.
  func noteCompletionExpiry(_ expiry: Date?) {
    guard let expiry else { return }
    nextCompletionExpiry = min(nextCompletionExpiry ?? expiry, expiry)
  }

  /// One pending reload for the soonest lingering completion. Keeping the
  /// selection on the row's neighbour rather than dropping it: the task you
  /// were on disappearing should not lose your place in the list.
  func scheduleCompletionExpiry() {
    completionExpiryTask?.cancel()
    guard let expiry = nextCompletionExpiry else {
      completionExpiryTask = nil
      return
    }
    completionExpiryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(max(expiry.timeIntervalSinceNow, 0) + 0.05)) } catch { return }
      guard let self else { return }
      let before = self.visibleNavigationTasks.map(\.id)
      self.reloadOutline(refreshSidebar: false)
      self.keepSelectionAfterExpiry(previousOrder: before)
    }
  }

  private func keepSelectionAfterExpiry(previousOrder: [String]) {
    guard let selectedTaskID else { return }
    let visible = visibleNavigationTasks.map(\.id)
    guard !visible.contains(selectedTaskID), let index = previousOrder.firstIndex(of: selectedTaskID) else { return }
    let remaining = Set(visible)
    let after = previousOrder[(index + 1)...].first { remaining.contains($0) }
    let before = previousOrder[..<index].last { remaining.contains($0) }
    self.selectedTaskID = after ?? before
  }

  /// The current scope's columns as the core resolves them: the board's own
  /// layout, its list's or the default; less the columns an entered card
  /// hides; plus any column a card here is filed under that the layout does
  /// not list. With where rule columns and the floor put each task.
  func readBoardColumns(store: WorkspaceStore) throws -> WorkspaceBoardColumns {
    // The old preferences' layouts are imported once per load; the call
    // also drops the stock copies older builds seeded for every scope.
    if boardColumnConfigurations == nil {
      let legacy = UserDefaults.standard.dictionary(forKey: Self.kanbanColumnsKey) as? [String: Data] ?? [:]
      boardColumnConfigurations = try store.kanbanBoardConfigurations(legacy: legacy, currentKey: boardConfigurationKey)
    }
    return try store.boardColumns(key: boardConfigurationKey, listIDs: boardScopeListIDs)
  }

  /// The lists the board draws from.
  var boardScopeListIDs: [String] {
    switch currentScope {
    case .list(let id): [id]
    case .combined(let ids), .filter(_, let ids): ids
    case nil: []
    }
  }

  /// Assigns only what changed, as the rest of the board does.
  func applyBoardColumns(_ read: WorkspaceBoardColumns) {
    if boardColumnRead != read { boardColumnRead = read }
    if boardColumns != read.columns { boardColumns = read.columns }
    if boardColumnPlacements != read.placements { boardColumnPlacements = read.placements }
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

}
