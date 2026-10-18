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
      // After the board, which reads a combined scope the outline left alone.
      let buried = currentScope.flatMap { scopeCache.entry(for: $0) }
        .map { WorkspaceScopeShaping.buriedStarts($0.read, now: Date()) } ?? [:]
      if buriedStarts != buried { buriedStarts = buried }
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
      let column = self.viewMode == .board ? self.activeBoardColumnID : nil
      let before = self.selectionOrder(inBoardColumn: column)
      // A start has arrived: the read put that task in the buried section,
      // so it is read again for the task to come back to its place.
      if let scope = self.currentScope, let entry = self.scopeCache.entry(for: scope),
        Set(WorkspaceScopeShaping.buriedStarts(entry.read, now: Date()).keys) != Set(self.buriedStarts.keys)
      {
        self.scopeCache.removeAll()
      }
      self.reloadOutline(refreshSidebar: false)
      self.keepSelectionAfterExpiry(previousOrder: before, boardColumn: column)
    }
  }

  /// The rows the selection is among, as drawn. On the board that is the
  /// column the keys are in, its cards with the subtask rows drawn on them:
  /// the cards of every column alone left out a subtask row, so one ticked
  /// off there lost the selection and the next arrow started from the top.
  private func selectionOrder(inBoardColumn columnID: String?) -> [String] {
    guard let columnID, let column = boardColumns.first(where: { $0.id == columnID }) else {
      return visibleNavigationTasks.map(\.id)
    }
    return boardRowIDs(in: column)
  }

  /// The row that took the gone one's place — see `SelectionSuccessor` —
  /// with the board's keys kept in the column they were walking.
  private func keepSelectionAfterExpiry(previousOrder: [String], boardColumn: String?) {
    guard let selectedTaskID else { return }
    let remaining = Set(selectionOrder(inBoardColumn: boardColumn))
    guard
      let successor = SelectionSuccessor.successor(
        of: selectedTaskID, previousOrder: previousOrder, remaining: remaining,
        parentOf: { [self] in task(withID: $0)?.parentTaskId })
    else { return }
    if let boardColumn { focusedBoardColumnID = boardColumn }
    self.selectedTaskID = successor
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
    // Kept per stamp: going back to a board reads its columns again only if
    // something was written since — for Everything that was 2 ms of every
    // switch to it, more than the rest of a resident switch. Kept a minute at
    // most too, since a rule column's matches turn on the time.
    let now = Date()
    let key = BoardColumnsMemoKey(
      store: ObjectIdentifier(store), stamp: try store.changeStamp(), board: boardConfigurationKey,
      listIDs: boardScopeListIDs, minute: Int(now.timeIntervalSinceReferenceDate / 60))
    if let memo = boardColumnsMemos[key.board], memo.key == key { return memo.read }
    let read = try store.boardColumns(key: key.board, listIDs: key.listIDs, now: now)
    // Only the boards read since the last write are worth holding.
    boardColumnsMemos = boardColumnsMemos.filter { $0.value.key.isCurrent(with: key) }
    boardColumnsMemos[key.board] = (key, read)
    return read
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

}

/// What a board's columns were read for. See `readBoardColumns(store:)`.
struct BoardColumnsMemoKey: Equatable {
  let store: ObjectIdentifier
  let stamp: WorkspaceChangeStamp
  let board: String
  let listIDs: [String]
  let minute: Int

  /// Read at the same stamp and minute as `other`, whatever the board.
  func isCurrent(with other: BoardColumnsMemoKey) -> Bool {
    store == other.store && stamp == other.stamp && minute == other.minute
  }
}
