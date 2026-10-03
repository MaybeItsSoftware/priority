import Foundation
import OSLog
import Observation
import PriorityCore

/// Provides read-only access to task data that KanbanManager needs for filtering and sorting.
/// The coordinator conforms to this; KanbanManager never references the coordinator directly.
@MainActor
protocol KanbanTaskDataSource: AnyObject {
  var tasks: [CheckvistTask] { get }
  var currentParentId: Int { get set }
  var hideFuture: Bool { get }
  /// The global scope toggle. The board used to ignore it entirely and read
  /// the whole tree, which is why the same key meant different things on
  /// this tab than on Due or Tags.
  var showChildrenInMenus: Bool { get }
  var currentSiblingIndex: Int { get set }
  var rootTaskView: RootTaskView { get }
  var cache: CacheState { get }
  func ensureVisibleTasksCacheValid()
  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket
  func absolutePriorityRank(for task: CheckvistTask) -> Int?
  func priorityRank(for task: CheckvistTask) -> Int?
  func priorityPath(for task: CheckvistTask) -> String?
  func childCountByTaskId() -> [Int: Int]
}

/// Describes the outcome of a kanban move so the coordinator can apply the actual task mutation.
enum KanbanMoveOutcome {
  case update(task: CheckvistTask, newContent: String?, newDue: String?)
  /// A drop into a quadrant column. The board writes the same axis the
  /// matrix view writes, so the two surfaces cannot disagree.
  case place(task: CheckvistTask, urgency: Double, importance: Double)
  case error(String)
}

@MainActor
@Observable class KanbanManager {
  @ObservationIgnored private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "kanban")
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let cacheInvalidationBus: CacheInvalidationBus
  @ObservationIgnored weak var dataSource: KanbanTaskDataSource?

  var kanbanColumns: [KanbanColumn] {
    didSet {
      saveKanbanColumns(kanbanColumns)
      cacheInvalidationBus.invalidate()
    }
  }
  var kanbanFocusedColumnIndex: Int = 0 {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// Task ID of the selected card in kanban view. Decoupled from currentSiblingIndex
  /// so selection survives task-list refreshes and view switches.
  var kanbanSelectedTaskId: Int? {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// When true, kanban shows only subtasks of `currentParentId`
  var kanbanFilterSubtasks: Bool = false {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// When set, kanban shows the full subtree under this task ID (excluding the root task itself).
  /// This overrides `kanbanFilterSubtasks`.
  var kanbanFilterParentId: Int? {
    didSet { cacheInvalidationBus.invalidate() }
  }
  /// Column ID currently showing the inline add field (nil = none).
  /// Rows per top-level goal, columns per state.
  ///
  /// A single row of columns says what state a task is in but never what it is
  /// for, which is the wrong trade for a tree that is mostly goal structure.
  var swimlanesByGoal: Bool {
    didSet {
      preferencesStore.set(swimlanesByGoal, for: .kanbanSwimlanesByGoal)
      cacheInvalidationBus.invalidate()
    }
  }

  var addingToColumnId: UUID?
  /// Text for the inline add field.
  var addText: String = ""
  /// Per-column manual order overlay. Maps column UUID string → ordered task IDs.
  /// Tasks listed here are sorted by this list within their column, taking
  /// precedence over the column's natural sort order. Tasks not in the list
  /// fall back to the column's natural sort. Lets users nudge cards up/down
  /// without mutating their underlying date/priority/etc.
  var manualOrderByColumnId: [String: [Int]] {
    didSet {
      saveManualOrders(manualOrderByColumnId)
      cacheInvalidationBus.invalidate()
    }
  }

  init(
    preferencesStore: PreferencesStore,
    cacheInvalidationBus: CacheInvalidationBus = CacheInvalidationBus()
  ) {
    self.preferencesStore = preferencesStore
    self.cacheInvalidationBus = cacheInvalidationBus
    let storedKanbanJson = preferencesStore.string(.kanbanColumns)
    if !storedKanbanJson.isEmpty,
      let data = storedKanbanJson.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([KanbanColumn].self, from: data),
      !decoded.isEmpty
    {
      // Migration: Change Backlog .catchAll to .tag("backlog")
      var migrated = decoded
      for i in 0..<migrated.count where migrated[i].name.lowercased() == "backlog" {
        migrated[i].conditions = migrated[i].conditions.map { cond in
          if case .catchAll = cond { return .tag("backlog") }
          return cond
        }
      }
      self.kanbanColumns = migrated
    } else {
      self.kanbanColumns = KanbanColumn.defaults
    }

    self.swimlanesByGoal = preferencesStore.bool(.kanbanSwimlanesByGoal, default: false)

    let storedManualOrdersJson = preferencesStore.string(.kanbanManualOrderByColumnId)
    if !storedManualOrdersJson.isEmpty,
      let data = storedManualOrdersJson.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String: [Int]].self, from: data)
    {
      self.manualOrderByColumnId = decoded
    } else {
      self.manualOrderByColumnId = [:]
    }
  }

  private func saveManualOrders(_ orders: [String: [Int]]) {
    guard let data = try? JSONEncoder().encode(orders),
      let json = String(data: data, encoding: .utf8)
    else { return }
    preferencesStore.set(json, for: .kanbanManualOrderByColumnId)
  }

  // MARK: - Task filtering for kanban columns

  /// Returns tasks that belong to the given column within the active kanban scope.
  /// Column membership uses first-match semantics: a task belongs to the first column
  /// (in `allColumns` order) whose conditions it satisfies.
  func tasksForKanbanColumn(_ column: KanbanColumn, allColumns: [KanbanColumn]) -> [CheckvistTask] {
    guard let ds = dataSource else { return [] }
    ds.ensureVisibleTasksCacheValid()
    var pool: [CheckvistTask]
    if let parentId = kanbanFilterParentId {
      pool = subtreeTasks(in: ds.tasks, rootId: parentId, taskById: ds.cache.taskById)
    } else if kanbanFilterSubtasks && ds.currentParentId != 0 {
      pool = subtreeTasks(in: ds.tasks, rootId: ds.currentParentId, taskById: ds.cache.taskById)
    } else {
      // The board honours the same global toggle as every other view. It used
      // to read `ds.tasks` unconditionally — the whole tree, scope ignored —
      // so drilling into a goal changed the list, the matrix and the due view
      // but left the board showing everything.
      pool = TaskScopeResolver.scoped(
        ds.tasks,
        currentLevelTasks: ds.tasks.filter { ($0.parentId ?? 0) == ds.currentParentId },
        parentId: ds.currentParentId,
        mode: TaskScopeResolver.mode(showChildrenInMenus: ds.showChildrenInMenus),
        isDescendant: { task, parentId in
          TaskFilterEngine.isDescendant(task, of: parentId, taskById: ds.cache.taskById)
        }
      )
    }

    // Discriminate: exclude completed tasks
    pool = pool.filter { $0.status == 0 }
    
    if ds.hideFuture {
      pool = pool.filter { task in
        guard let dueDate = task.dueDate else { return true }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return true }
        return Calendar.current.startOfDay(for: dueDate) <= Calendar.current.startOfDay(for: tomorrow)
      }
    }    
    // Resolved once for the whole pool. `columnForTask` builds its own inputs,
    // so calling it per task made a column cost the tree over again for every
    // card in it.
    guard let inputs = membershipInputs() else { return [] }
    let eligible = pool.filter { task in
      KanbanFilter.column(for: task, in: allColumns, inputs: inputs)?.id == column.id
    }
    let naturallySorted = sortedForKanban(eligible, sortOrder: column.sortOrder)
    return applyManualOrder(naturallySorted, column: column)
  }

  /// The board's rows. Empty when swimlanes are off, which is how the view
  /// tells the two layouts apart without asking twice.
  ///
  /// Built from every task the current scope covers rather than per column, so
  /// a lane exists whenever the goal has *any* work — a lane whose cards all
  /// sit in one column still shows its other columns as empty, which is the
  /// comparison the layout is for.
  func swimlanes() -> [KanbanSwimlane<CheckvistTask>] {
    guard swimlanesByGoal, let ds = dataSource else { return [] }
    ds.ensureVisibleTasksCacheValid()
    let columns = kanbanColumns
    guard let inputs = membershipInputs() else { return [] }
    let placed = ds.tasks.filter { task in
      task.status == 0 && KanbanFilter.column(for: task, in: columns, inputs: inputs) != nil
    }
    return KanbanSwimlanes.lanes(
      for: placed,
      taskById: ds.cache.taskById,
      unassignedTitle: "No goal"
    )
  }

  /// Reorders `tasks` so any task listed in the column's manual override comes
  /// first in the order specified there. Tasks not present in the override
  /// retain the natural-sort order they came in with.
  private func applyManualOrder(_ tasks: [CheckvistTask], column: KanbanColumn)
    -> [CheckvistTask]
  {
    guard let order = manualOrderByColumnId[column.id.uuidString] else { return tasks }
    return KanbanManualOrder.apply(order, to: tasks, id: \.id)
  }

  /// Move `taskId` one slot up or down in the column's manual order. The task
  /// is added to the override (if not present) using its current visible
  /// position as the starting rank. No underlying task attribute is changed —
  /// this is purely a per-user, per-column display preference.
  @MainActor func nudgeTaskInColumn(taskId: Int, in column: KanbanColumn, direction: Int) {
    // Anchor the override to the current visible order, so it mirrors what the
    // user could see immediately before the move.
    let visible = tasksForKanbanColumn(column, allColumns: kanbanColumns).map(\.id)
    guard
      let order = KanbanManualOrder.nudgingTask(
        taskId, direction: direction, inVisibleOrder: visible)
    else { return }
    manualOrderByColumnId[column.id.uuidString] = order
  }

  /// Place `taskId` immediately before whatever currently sits at
  /// `visibleIndex` in `column` — the mouse's half of the manual order, where
  /// `nudgeTaskInColumn` is the keyboard's.
  ///
  /// A drag inserts; a nudge only ever swaps a neighbouring pair. Both write
  /// nothing but the overlay, so a card moved inside a column keeps its due
  /// date, priority and position untouched.
  ///
  /// The task need not already be in the column: a card dragged in from
  /// another one is inserted at the requested slot, so the overlay is already
  /// correct by the time the condition write lands it here.
  @MainActor func moveTaskInColumn(
    taskId: Int, in column: KanbanColumn, toPositionBefore visibleIndex: Int
  ) {
    let visible = tasksForKanbanColumn(column, allColumns: kanbanColumns).map(\.id)
    let order = KanbanManualOrder.movingTask(
      taskId, toPositionBefore: visibleIndex, inVisibleOrder: visible)
    guard order != visible else { return }
    manualOrderByColumnId[column.id.uuidString] = order
  }

  /// Drop a task from every column's manual order. Used when a task is
  /// completed/deleted so stale IDs don't accumulate.
  @MainActor func clearManualOrderEntries(forTaskIds removed: Set<Int>) {
    guard let updated = KanbanManualOrder.removing(taskIds: removed, from: manualOrderByColumnId)
    else { return }
    manualOrderByColumnId = updated
  }

  private func subtreeTasks(in tasks: [CheckvistTask], rootId: Int, taskById: [Int: CheckvistTask])
    -> [CheckvistTask]
  {
    KanbanFilter.subtreeTasks(in: tasks, rootId: rootId, taskById: taskById)
  }

  /// Returns the first column (in order) that a task matches.
  /// Only a *specific* condition (tag or due bucket) claims a task; `.catchAll`
  /// answers false, so it collects what no earlier column took.
  func columnForTask(_ task: CheckvistTask, in columns: [KanbanColumn]) -> KanbanColumn? {
    guard let inputs = membershipInputs() else { return nil }
    return KanbanFilter.column(for: task, in: columns, inputs: inputs)
  }

  /// Assembled once per query rather than per condition. Three call sites used
  /// to build their own argument list, which is how two of them would end up
  /// answering the same question differently.
  ///
  /// Cheap enough to build per query, but only since the inheritance
  /// resolution moved into the cache. It used to walk every task's ancestor
  /// chain right here — and every caller below looped over tasks calling it,
  /// so a board render resolved the whole tree a couple of thousand times.
  private func membershipInputs() -> KanbanFilter.MembershipInputs<CheckvistTask>? {
    guard let ds = dataSource else { return nil }
    // Inherited coordinates count here exactly as they do on the matrix — it is
    // literally the same resolution, read from the same cache. If the board
    // read only own-coordinates, placing a goal would fill the matrix and leave
    // every quadrant column empty: two views disagreeing about where the same
    // task is.
    var eisenhower: [Int: (urgency: Double, importance: Double)] = [:]
    for (taskId, level) in ds.cache.effectiveEisenhowerLevels {
      eisenhower[taskId] = (urgency: level.urgency, importance: level.importance)
    }
    var priorities: [Int: Int] = [:]
    for task in ds.tasks {
      // Absolute rank wins where both exist, matching the board's sort.
      if let rank = ds.absolutePriorityRank(for: task) ?? ds.priorityRank(for: task) {
        priorities[task.id] = rank
      }
    }
    return KanbanFilter.MembershipInputs(
      tagsByTaskId: ds.cache.tagsByTaskId,
      dueBucket: { ds.rootDueBucket(for: $0) },
      eisenhowerByTaskId: eisenhower,
      priorityRankByTaskId: priorities,
      childCountByTaskId: ds.childCountByTaskId()
    )
  }

  private func taskMatchesKanbanColumn(
    _ task: CheckvistTask,
    column: KanbanColumn,
    includeCatchAll: Bool = true
  ) -> Bool {
    guard let inputs = membershipInputs() else { return false }
    return KanbanFilter.matchesColumn(
      task, column: column, includeCatchAll: includeCatchAll, inputs: inputs)
  }

  func taskMatchesCondition(_ task: CheckvistTask, condition: KanbanColumnCondition) -> Bool {
    guard let inputs = membershipInputs() else { return false }
    return KanbanFilter.matches(task, condition: condition, inputs: inputs)
  }

  // Note: sortedForKanban implementation moved to extension at the bottom of this file.

  // MARK: - Current kanban task

  /// The currently selected task in the focused kanban column.
  var currentKanbanTask: CheckvistTask? {
    let board = boardTasks()
    let placement = KanbanSelection.clamp(currentPlacement, in: board.grid)
    guard let selectedId = placement.selectedTaskId,
      let found = KanbanSelection.locate(selectedId, in: board.grid)
    else { return nil }
    return board.tasks[found.column][found.row]
  }

  // MARK: - Selection plumbing

  /// The board as `KanbanSelection` wants it: one row of task ids per column,
  /// in display order, alongside the tasks themselves.
  ///
  /// Built once per operation. The selection code used to re-filter and re-sort
  /// every column inside every lookup — `nextKanbanTask` alone called
  /// `tasksForKanbanColumn` once per column to resolve focus and then again to
  /// read the column it settled on.
  private func boardTasks() -> (tasks: [[CheckvistTask]], grid: [[Int]]) {
    let columns = kanbanColumns
    let tasks = columns.map { tasksForKanbanColumn($0, allColumns: columns) }
    return (tasks, tasks.map { $0.map(\.id) })
  }

  private var currentPlacement: KanbanSelection.Placement {
    KanbanSelection.Placement(
      focusedColumnIndex: kanbanFocusedColumnIndex,
      selectedTaskId: kanbanSelectedTaskId,
      siblingIndex: dataSource?.currentSiblingIndex ?? 0)
  }

  private func apply(_ placement: KanbanSelection.Placement) {
    kanbanFocusedColumnIndex = placement.focusedColumnIndex
    kanbanSelectedTaskId = placement.selectedTaskId
    dataSource?.currentSiblingIndex = placement.siblingIndex
  }

  // MARK: - Moving tasks between columns

  /// Computes the move for the currently selected task one column in `direction`.
  /// Returns nil if no move is possible, `.error` if the target has no writable condition,
  /// or `.success` with the mutation to apply.
  @MainActor func computeMoveCurrentTask(direction: Int) -> KanbanMoveOutcome? {
    guard let ds = dataSource, ds.rootTaskView == .kanban else { return nil }
    let columns = kanbanColumns
    guard !columns.isEmpty, let task = currentKanbanTask else { return nil }

    let currentColIndex = kanbanFocusedColumnIndex

    // Display is reversed, so visual right = lower array index.
    let targetIndex = currentColIndex - direction
    guard columns.indices.contains(targetIndex) else { return nil }
    let targetColumn = columns[targetIndex]

    if let placement = quadrantPlacement(for: task, targetColumn: targetColumn) {
      kanbanFocusedColumnIndex = targetIndex
      ds.currentSiblingIndex = 0
      kanbanSelectedTaskId = task.id
      return placement
    }

    guard
      let (newContent, newDue) = applyColumnConditions(
        to: task, targetColumn: targetColumn, allColumns: columns)
    else {
      return .error("Can't move task into \"\(targetColumn.name)\" — no writable condition.")
    }

    // Shift focused column to follow the task
    kanbanFocusedColumnIndex = targetIndex
    ds.currentSiblingIndex = 0
    kanbanSelectedTaskId = task.id

    if newContent != task.content || newDue != task.due {
      return .update(
        task: task,
        newContent: newContent != task.content ? newContent : nil,
        newDue: newDue != task.due ? newDue : nil
      )
    }
    return nil
  }

  /// Computes the move for a specific task to a target column.
  @MainActor func computeMoveTask(id taskId: Int, toColumn targetColumn: KanbanColumn)
    -> KanbanMoveOutcome?
  {
    guard let ds = dataSource else { return nil }
    let columns = kanbanColumns
    guard let task = ds.cache.taskById[taskId] else { return nil }
    if let placement = quadrantPlacement(for: task, targetColumn: targetColumn) {
      return placement
    }
    guard
      let (newContent, newDue) = applyColumnConditions(
        to: task, targetColumn: targetColumn, allColumns: columns)
    else {
      return .error("Can't move task into \"\(targetColumn.name)\" — no writable condition.")
    }
    if newContent != task.content || newDue != task.due {
      return .update(
        task: task,
        newContent: newContent != task.content ? newContent : nil,
        newDue: newDue != task.due ? newDue : nil
      )
    }
    return nil
  }

  /// A move into a quadrant column, if that is what this column is.
  ///
  /// Answered before the content/due path because a placement cannot be
  /// expressed as either — the coordinate lives in Priority's own store, not in
  /// the task's text or its due date.
  private func quadrantPlacement(
    for task: CheckvistTask, targetColumn: KanbanColumn
  ) -> KanbanMoveOutcome? {
    let quadrant = targetColumn.conditions.compactMap { condition -> MatrixQuadrant? in
      guard case .matrixQuadrant(let raw) = condition else { return nil }
      return MatrixQuadrant(rawValue: raw)
    }.first
    guard let quadrant else { return nil }
    let point = quadrant.representativeCoordinate
    return .place(task: task, urgency: point.urgency, importance: point.importance)
  }

  /// Computes the new content and due string needed to make `task` satisfy `targetColumn`.
  /// Returns nil if no writable condition exists.
  private func applyColumnConditions(
    to task: CheckvistTask,
    targetColumn: KanbanColumn,
    allColumns: [KanbanColumn]
  ) -> (content: String, due: String?)? {
    var content = task.content
    var due: String? = task.due

    // Strip tags that belong to other tag-based columns so there's no ambiguity.
    let otherColumnTags: [String] =
      allColumns
      .filter { $0.id != targetColumn.id }
      .flatMap { col in
        col.conditions.compactMap {
          if case .tag(let t) = $0 { return t } else { return nil }
        }
      }
    for tag in otherColumnTags {
      let escapedTag = NSRegularExpression.escapedPattern(for: tag)
      if let regex = try? NSRegularExpression(pattern: "(?i)(?:^|\\s)#\(escapedTag)\\b") {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        content = regex.stringByReplacingMatches(in: content, range: range, withTemplate: "")
      }
      content =
        content
        .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }

    // Determine if the task's current column is due-bucket based.
    let currentColumn = columnForTask(task, in: allColumns)
    let sourceIsDueBased =
      currentColumn?.conditions.contains(where: {
        if case .dueBucket = $0 { return true }
        return false
      }) ?? false

    // Preserve due when moving into a due-based column that already matches the task's bucket.
    // This avoids clobbering an existing date/time (e.g. moving within "Next 7 Days").
    if let ds = dataSource {
      let targetDueBuckets = targetColumn.conditions.compactMap { condition -> RootDueBucket? in
        guard case .dueBucket(let raw) = condition else { return nil }
        return RootDueBucket(rawValue: raw)
      }
      let existingDue = task.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !targetDueBuckets.isEmpty, !existingDue.isEmpty {
        let currentBucket = ds.rootDueBucket(for: task)
        if targetDueBuckets.contains(currentBucket) {
          return (content, due)
        }
      }
    }

    // Find the first writable condition in the target column.
    guard let writableCondition = targetColumn.conditions.first(where: { $0.isWritable }) else {
      return nil
    }

    switch writableCondition {
    case .tag(let name):
      if !content.lowercased().contains("#\(name.lowercased())") {
        content = "\(content) #\(name)"
      }
      // Strip due date when moving out of a due-bucket column into a tag column.
      if sourceIsDueBased {
        due = ""
      }

    case .dueBucket(let raw):
      guard let bucket = RootDueBucket(rawValue: raw) else { return nil }
      switch bucket {
      case .today:
        due = CommandEngine.resolveDueDate("today")
      case .tomorrow:
        due = CommandEngine.resolveDueDate("tomorrow")
      case .nextSevenDays:
        // Pick a date 3 days out — comfortably inside the 7-day window.
        let cal = Calendar.current
        let target = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: Date()))!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        due = fmt.string(from: target)
      case .noDueDate:
        due = ""
      default:
        return nil  // non-writable bucket
      }

    case .catchAll:
      // Strip the due date so the task doesn't accidentally match a due-bucket column.
      due = ""

    case .matrixQuadrant, .priorityAtLeast, .leafOnly, .unplacedOnMatrix:
      // A quadrant move is answered by `quadrantPlacement` before this runs, and
      // the other three are not writable, so `isWritable` never selects them.
      // Unreachable rather than unhandled.
      return nil
    }

    return (content, due)
  }

  // MARK: - Column focus navigation (no task move)

  @MainActor func focusKanbanColumn(direction: Int) {
    guard let ds = dataSource, ds.rootTaskView == .kanban else { return }
    guard
      let placement = KanbanSelection.focusColumn(
        from: kanbanFocusedColumnIndex, direction: direction, in: boardTasks().grid)
    else { return }
    apply(placement)
  }

  @MainActor func nextKanbanTask() {
    guard let placement = KanbanSelection.next(from: currentPlacement, in: boardTasks().grid)
    else { return }
    apply(placement)
  }

  @MainActor func previousKanbanTask() {
    guard let placement = KanbanSelection.previous(from: currentPlacement, in: boardTasks().grid)
    else { return }
    apply(placement)
  }

  // MARK: - Scope drill in/out

  /// Drills the kanban into the selected task's subtree so its children become
  /// the new sibling-pool. Selection moves to the first child if any.
  @MainActor func enterSelectedTaskAsScope() {
    guard let task = currentKanbanTask else { return }
    kanbanFilterParentId = task.id
    dataSource?.currentParentId = task.id
    // The board is re-read *after* the scope changes, so this is the new
    // subtree. No children leaves the scope drilled with nothing selected, so
    // the user sees an empty board rather than being silently bounced back.
    apply(KanbanSelection.firstAvailable(in: boardTasks().grid))
  }

  /// Pops the kanban scope up one level. If we're at root, restores selection to
  /// what was previously the parent task (so navigation feels reversible).
  @MainActor func exitToParentScope() {
    guard let ds = dataSource else { return }
    let currentScopeId: Int? =
      kanbanFilterParentId
      ?? (ds.currentParentId == 0 ? nil : ds.currentParentId)
    guard let currentFilterId = currentScopeId else { return }
    let parentTask = ds.cache.taskById[currentFilterId]
    let newParentId = parentTask?.parentId ?? 0
    kanbanFilterSubtasks = false
    kanbanFilterParentId = newParentId == 0 ? nil : newParentId
    ds.currentParentId = newParentId

    // Re-select the task we just popped out of so the user has context,
    // falling back to the first card on the board.
    let placement = KanbanSelection.select(
      parentTask?.id, in: boardTasks().grid, fallbackColumnIndex: kanbanFocusedColumnIndex)
    // An empty board leaves the selection alone rather than clearing it, as it
    // always has — `clampKanbanSelection` is what tidies a stale one.
    guard placement.selectedTaskId != nil else { return }
    apply(placement)
  }

  // MARK: - Scope navigation helpers

  /// Whether the current selection is at the first task in the focused column (or there are
  /// no tasks at all). Used by the keyboard router to decide whether UP arrow should enter
  /// the scope row instead of navigating within the column.
  var isAtTopOfFocusedColumn: Bool {
    KanbanSelection.isAtTopOfFocusedColumn(currentPlacement, in: boardTasks().grid)
  }

  // MARK: - Selection clamping

  /// Re-validate kanbanSelectedTaskId after task mutations (complete, delete, reorder).
  /// If the selected task no longer exists in any column, pick the nearest task in the
  /// focused column so the selection doesn't jump to an unrelated task.
  @MainActor func clampKanbanSelection() {
    guard dataSource != nil else { return }
    let placement = currentPlacement
    let clamped = KanbanSelection.clamp(placement, in: boardTasks().grid)
    // A still-valid selection comes back untouched; writing it anyway would
    // fire the observation bus on every mutation for no change.
    guard clamped != placement else { return }
    apply(clamped)
  }

  // MARK: - Kanban column persistence

  func loadKanbanColumns() -> [KanbanColumn] {
    guard
      let data = preferencesStore.string(.kanbanColumns).data(using: .utf8),
      !data.isEmpty,
      let decoded = try? JSONDecoder().decode([KanbanColumn].self, from: data),
      !decoded.isEmpty
    else {
      return KanbanColumn.defaults
    }
    return decoded
  }

  func saveKanbanColumns(_ columns: [KanbanColumn]) {
    guard let data = try? JSONEncoder().encode(columns),
      let json = String(data: data, encoding: .utf8)
    else { return }
    preferencesStore.set(json, for: .kanbanColumns)
  }

  // MARK: - Inline add

  /// Returns (content, due) with column attributes applied to raw user input.
  func contentAndDueForNewTask(rawContent: String, in column: KanbanColumn) -> (content: String, due: String?) {
    var content = rawContent
    var due: String?

    guard let condition = column.conditions.first(where: { $0.isWritable }) else {
      return (content, due)
    }

    switch condition {
    case .tag(let name):
      if !content.lowercased().contains("#\(name.lowercased())") {
        content = "\(content) #\(name)"
      }
    case .dueBucket(let raw):
      if let bucket = RootDueBucket(rawValue: raw) {
        switch bucket {
        case .today:
          due = CommandEngine.resolveDueDate("today")
        case .tomorrow:
          due = CommandEngine.resolveDueDate("tomorrow")
        case .nextSevenDays:
          let cal = Calendar.current
          let target = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: Date()))!
          let fmt = DateFormatter()
          fmt.locale = Locale(identifier: "en_US_POSIX")
          fmt.dateFormat = "yyyy-MM-dd"
          due = fmt.string(from: target)
        default:
          break
        }
      }
    case .catchAll:
      break

    case .matrixQuadrant, .priorityAtLeast, .leafOnly, .unplacedOnMatrix:
      // Inline-add into one of these columns creates an ordinary task, which
      // then may not match the column it was typed into.
      //
      // A quadrant placement is keyed by task id, and at this point the task
      // only has an optimistic one that `reconcileEisenhowerLevels` discards
      // when the real id arrives — so placing here would look right for a
      // second and then silently vanish. Better to create the task honestly and
      // let it be dragged onto the board.
      break
    }

    return (content, due)
  }
}

// MARK: - Kanban Sorting Extension

extension KanbanManager {
  /// The board's orderings live in `KanbanFilter` (pure, in `PriorityCore`, and
  /// covered by `corelogic-tests/KanbanFilterTests.swift`). This gathers the
  /// ranks and tags they need from the data source once, rather than letting a
  /// comparator reach through it O(n log n) times.
  func sortedForKanban(
    _ tasks: [CheckvistTask],
    sortOrder: KanbanSortOrder
  ) -> [CheckvistTask] {
    guard let ds = dataSource else { return tasks }
    let cache = ds.cache
    return KanbanFilter.sorted(
      tasks,
      sortOrder: sortOrder,
      inputs: .init(
        absolutePriorityRank: cache.absolutePriorityRank,
        priorityRank: cache.priorityRank,
        tagsByTaskId: cache.tagsByTaskId
      )
    )
  }
}
