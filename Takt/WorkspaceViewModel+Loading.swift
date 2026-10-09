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
      let now = Date()
      items.removeAll { hidesCompletion(of: $0.task, now: now) }
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
    // Read outside a refresh, so nothing else would empty the trees it
    // shared, and the next refresh would take them as current.
    listTreeCache = [:]
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
    // Everything's board is every list's open work: every tree read, walked
    // and every card's metadata fetched, on each edit. Today sits on
    // Everything and never draws it, so it is set aside until a view that
    // does is shown (`viewModeDidChange`). Emptied rather than left as it
    // was, so nothing reads an old board as current.
    if !force, isEverythingSelected || folderScopeListIDs != nil, !isBoardOnScreen {
      clearBoard()
      if boardParentTaskID != nil { boardParentTaskID = nil }
      // The columns are kept, for the Today column a task can be filed in
      // from Today. Without the cards, only the layout's own.
      if let columns = try? resolvedBoardColumns(usedColumnIDs: [], store: store), boardColumns != columns {
        boardColumns = columns
      }
      boardIsStale = true
      return
    }
    boardIsStale = false
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
      let now = Date()
      tasks.removeAll { ($0.isList && $0.archivedAt != nil) || hidesCompletion(of: $0, now: now) }
      let boardIDs = Set(tasks.map(\.id))
      let listIDs = Array(Set(tasks.map(\.listId)))
      let trees = try listTrees(for: listIDs, store: store)
      // Every level beneath every card, the nested cards' own trees included,
      // in one walk of rows already read — never a query per card.
      let board = WorkspaceBoardTrees(cardIDs: boardIDs, trees: listIDs.compactMap { trees[$0] })
      // A card's tree loses its finished rows as the outline does, once their
      // few seconds are up. Row by row, as there: an open task under a closed
      // one stays on show.
      let descendants = board.descendants.mapValues { rows in
        rows.filter { !hidesCompletion(of: $0.task, now: now) }
      }
      let parents = board.parents
      var treeIDs = Set<String>()
      let treeTasks = (tasks + tasks.flatMap { root in
        descendants[root.id, default: []].map(\.task)
      }).filter { treeIDs.insert($0.id).inserted }
      let metadata = try store.boardMetadata(for: treeTasks.map(\.id))
      let columnsByTask = metadata.columns
      // A subtask nobody filed is in whatever column its parent is in. It
      // used to count as being in the first column, so moving a card out of
      // Backlog left every one of its subtasks behind there as a card of its
      // own — as though each had been filed in Backlog on purpose.
      var effectiveColumns: [String: String] = [:]
      func effectiveColumn(of task: WorkspaceTask) -> String {
        if let known = effectiveColumns[task.id] { return known }
        let column = columnsByTask[task.id]
          ?? parents[task.id].map { effectiveColumn(of: $0) }
          ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
        effectiveColumns[task.id] = column
        return column
      }
      let crossColumn = treeTasks.filter { task in
        if hidesCompletion(of: task, now: now) { return false }
        guard !task.isList else { return false }
        guard !boardIDs.contains(task.id), let parent = parents[task.id],
          let filed = columnsByTask[task.id]
        else { return false }
        return filed != effectiveColumn(of: parent)
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

  /// Empties the cards and what was read about them, assigning only what
  /// is not already empty.
  private func clearBoard() {
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
  static let completedLingerInterval: TimeInterval = 3

  /// Whether a finished task is kept off the pane. One finished within the
  /// last few seconds still shows, and the soonest of those to expire is
  /// noted so a reload can be scheduled for it.
  func hidesCompletion(of task: WorkspaceTask, now: Date) -> Bool {
    guard hidesCompletedTasks, task.status != .open else { return false }
    // Completions from before `completedAt` was recorded are long past.
    guard let completedAt = task.completedAt else { return true }
    let expiry = completedAt.addingTimeInterval(Self.completedLingerInterval)
    guard expiry > now else { return true }
    nextCompletionExpiry = min(nextCompletionExpiry ?? expiry, expiry)
    return false
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

}
