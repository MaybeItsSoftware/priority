import Foundation
import Observation
import TaktCore

@MainActor
@Observable final class TaskListViewModel {
  // MARK: - Dependencies
  @ObservationIgnored private let repository: TaskRepository
  @ObservationIgnored private let preferencesStore: PreferencesStore
  /// The five app-only managers this used to name concretely. Weak because
  /// `AppCoordinator` owns this view model, so a strong reference back would be
  /// a retain cycle — the same shape as `TaskMutationHost` and `SyncHost`.
  @ObservationIgnored weak var host: TaskListViewModelHost?

  // MARK: - State
  var hideFuture: Bool = false {
    didSet { invalidateCaches() }
  }

  // The three view-shaping selections below own their own persistence: each
  // `didSet` writes through to `PreferencesStore`. (Previously the persistence
  // lived on `AppCoordinator`'s forwarder setters; moving it here lets those
  // forwarders be pure pass-throughs and eventually deleted.) Assignments made
  // in `init` deliberately don't fire these observers, so loading the persisted
  // value on launch doesn't write it straight back.
  var rootTaskView: RootTaskView = .all {
    didSet {
      preferencesStore.set(rootTaskView.rawValue, for: .rootTaskView)
      invalidateCaches()
    }
  }

  var selectedRootDueBucketRawValue: Int = -1 {
    didSet {
      preferencesStore.set(selectedRootDueBucketRawValue, for: .selectedRootDueBucketRawValue)
      invalidateCaches()
    }
  }

  var selectedRootTag: String = "" {
    didSet {
      preferencesStore.set(selectedRootTag, for: .selectedRootTag)
      invalidateCaches()
    }
  }

  /// Typed wrapper over `selectedRootDueBucketRawValue` (−1 == "no selection").
  /// Lived on `AppCoordinator` previously; moved here so the raw forwarder can
  /// be deleted and views read the selection from its real owner.
  var selectedRootDueBucket: RootDueBucket? {
    get { RootDueBucket(rawValue: selectedRootDueBucketRawValue) }
    set { selectedRootDueBucketRawValue = newValue?.rawValue ?? -1 }
  }

  /// When true, non-kanban menus (Due, Tags, Priority, Eisenhower) show the entire
  /// subtree under `currentParentId` (siblings of the selection plus all of their
  /// descendants), matching kanban filtering. When false, they show only direct
  /// children of `currentParentId`. The All view is unaffected.
  var showChildrenInMenus: Bool = true {
    didSet { invalidateCaches() }
  }

  @ObservationIgnored private var cacheStorage = CacheState()

  /// Bumped by `invalidateCaches()`, and read by every accessor that touches
  /// the derived cache.
  ///
  /// This is the cache's observability, and it has to be a stored observable
  /// property because `cacheStorage` is `@ObservationIgnored`. Without it, a
  /// SwiftUI view reading the cache while it happened to be *clean* registered
  /// no dependency at all — `ensureVisibleTasksCacheValid()` returns at its
  /// guard without touching anything observable — and so never updated again.
  /// Whether that happened depended on call ordering: any non-view reader
  /// that got there first cleared the dirty flag and took the view's tracking
  /// with it.
  ///
  /// It replaces a hand-maintained list of `_ = repository.x` touches in
  /// `visibleTasks`, which had the same intent but covered only one of the
  /// fifteen accessors and had already fallen behind its own inputs — the
  /// priority queues drive row *ordering* and were missing from it.
  private(set) var cacheVersion: Int = 0

  /// Up-to-date view of the derived caches.
  ///
  /// Reading this rebuilds lazily if anything has invalidated since the last
  /// read, so external callers can't observe a stale snapshot. Previously
  /// `invalidateCaches()` rebuilt eagerly, which kept those readers correct
  /// only by accident and made every single mutation of `tasks` — plus each
  /// priority/eisenhower/timer write that follows it — pay for a full
  /// recompute. Internal code should use `cacheStorage` directly to avoid
  /// re-entering the validity check on hot paths.
  ///
  /// Reading this from a view also subscribes that view to the cache, via
  /// `cacheVersion` — see its doc comment for why that is not automatic.
  var cache: CacheState {
    ensureVisibleTasksCacheValid()
    return cacheStorage
  }

  init(
    repository: TaskRepository,
    preferencesStore: PreferencesStore,
    host: TaskListViewModelHost? = nil
  ) {
    self.repository = repository
    self.preferencesStore = preferencesStore
    self.host = host

    // Load persisted view-shaping state. These assignments run inside `init`,
    // so the `didSet` write-throughs above don't fire.
    self.rootTaskView =
      RootTaskView(rawValue: preferencesStore.int(.rootTaskView, default: 1)) ?? .due
    self.selectedRootDueBucketRawValue = preferencesStore.int(
      .selectedRootDueBucketRawValue, default: -1)
    self.selectedRootTag = preferencesStore.string(.selectedRootTag)
  }

  // MARK: - Host reads

  // Named rather than inlined so the `host?.x ?? default` dance appears once
  // each. The defaults describe an unattached view model, which only exists
  // during construction.

  private var hostCurrentParentId: Int { host?.currentParentId ?? 0 }
  private var hostCurrentSiblingIndex: Int { host?.currentSiblingIndex ?? 0 }
  private var hostIsSearchFilterActive: Bool { host?.isSearchFilterActive ?? false }
  private var hostSearchText: String { host?.searchText ?? "" }
  private var hostTimerElapsedByTaskId: [Int: TimeInterval] {
    host?.timerElapsedByTaskId ?? [:]
  }
  private var hostShowsBreadcrumbContext: Bool { host?.showsTaskBreadcrumbContext ?? false }

  /// Marks the derived caches stale. The rebuild is deferred to the next read
  /// of `cache` (or of any accessor that calls
  /// `ensureVisibleTasksCacheValid`), so a burst of writes — e.g. a delete,
  /// which touches `tasks`, both priority queues and the eisenhower levels —
  /// costs one recompute instead of one per write.
  func invalidateCaches() {
    cacheStorage.invalidate()
    // Wrapping rather than trapping: the value is only ever compared for
    // change, so it has no meaning to preserve at the boundary.
    cacheVersion &+= 1
  }

  func ensureVisibleTasksCacheValid() {
    // Read before the guard, deliberately. This is what registers a reading
    // view's dependency on the cache even when there is nothing to rebuild.
    _ = cacheVersion
    guard cacheStorage.dirty, !cacheStorage.isRebuilding else { return }
    cacheStorage.isRebuilding = true
    defer { cacheStorage.isRebuilding = false }

    let tasks = repository.tasks
    cacheStorage.taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    cacheStorage.tagsByTaskId = TaskFilterEngine.extractTagsByTaskId(tasks: tasks)
    cacheStorage.rootDueBucket = TaskFilterEngine.computeRootDueBuckets(tasks: tasks)
    // Completed tasks keep their slot in the queue so that reopening one puts
    // it back where it was, but they must not take a *number*: the ranks on
    // screen are 1…n over the tasks actually open, with the held slots skipped.
    let openIds = Set(tasks.map(\.id))
    var rankByTaskId: [Int: Int] = [:]
    for (_, ids) in repository.priorityTaskIdsByParentId {
      for (idx, id) in ids.filter({ openIds.contains($0) }).enumerated() {
        rankByTaskId[id] = idx + 1
      }
    }
    var absoluteRankByTaskId: [Int: Int] = [:]
    for (idx, id) in repository.absolutePriorityTaskIds.filter({ openIds.contains($0) })
      .enumerated()
    {
      absoluteRankByTaskId[id] = idx + 1
    }
    cacheStorage.priorityRank = rankByTaskId
    cacheStorage.absolutePriorityRank = absoluteRankByTaskId
    cacheStorage.priorityPath = Self.computePriorityPaths(
      rankByTaskId: rankByTaskId,
      taskById: cacheStorage.taskById
    )
    cacheStorage.dirty = false
    let visibility = computeVisibility()
    // Children revealed by expansion are ordered the same way the view orders
    // its own rows, so an expanded subtree reads like the list it sits in.
    let rows = TaskOutlineBuilder.flatten(
      base: visibility.tasks,
      tasks: tasks,
      expandedTaskIds: repository.expandedTaskIds,
      sortChildren: { children in
        children.sorted { lhs, rhs in
          TaskFilterEngine.compareByPriorityThenPosition(
            lhs,
            rhs,
            priorityRankById: self.cacheStorage.priorityRank,
            absolutePriorityRankById: self.cacheStorage.absolutePriorityRank
          )
        }
      }
    )
    cacheStorage.visibleTasks = rows.map(\.task)
    cacheStorage.outlineDepths = rows.map(\.depth)
    cacheStorage.remainderStartIndex = visibility.remainderStartIndex
    let nodes = tasks.map { TimerNode(id: $0.id, parentId: $0.parentId) }
    cacheStorage.childCount = TimerStore.childCountByTaskId(nodes: nodes)
    cacheStorage.rolledUpElapsed = TimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: hostTimerElapsedByTaskId)
    cacheStorage.rootLevelTagNames = computeRootLevelTagNames(limit: 30)
  }

  private func computeVisibility() -> TaskVisibilityEngine.Result<CheckvistTask> {
    let tasks = repository.tasks
    let currentParentId = hostCurrentParentId
    let currentLevelTasks = tasks.filter { ($0.parentId ?? 0) == currentParentId }
    let isRootLevel = currentParentId == 0
    let isSearchFilterActive = hostIsSearchFilterActive
    let shouldShowRootScopeSection = !isSearchFilterActive

    return TaskVisibilityEngine.compute(
      in: .init(
        tasks: tasks,
        currentLevelTasks: currentLevelTasks,
        currentParentId: currentParentId,
        isSearchFilterActive: isSearchFilterActive,
        searchText: hostSearchText,
        hideFuture: hideFuture,
        shouldShowRootScopeSection: shouldShowRootScopeSection,
        isRootLevel: isRootLevel,
        rootTaskView: rootTaskView,
        showChildrenInMenus: showChildrenInMenus,
        selectedRootDueBucket: RootDueBucket(rawValue: selectedRootDueBucketRawValue),
        selectedRootTag: selectedRootTag,
        taskById: cacheStorage.taskById,
        isDescendant: { task, rootId in
          TaskFilterEngine.isDescendant(task, of: rootId, taskById: self.cacheStorage.taskById)
        },
        taskMatchesActiveRootScope: { [weak self] task in
          self?.taskMatchesActiveRootScope(task) ?? false
        },
        isAbsolutePrioritized: { [weak self] task in
          self?.cacheStorage.absolutePriorityRank[task.id] != nil
        },
        compareByPriorityThenPosition: { lhs, rhs in
          TaskFilterEngine.compareByPriorityThenPosition(
            lhs,
            rhs,
            priorityRankById: self.cacheStorage.priorityRank,
            absolutePriorityRankById: self.cacheStorage.absolutePriorityRank
          )
        },
        compareByRootDueBucket: { lhs, rhs in
          TaskFilterEngine.compareByRootDueBucket(
            lhs, rhs, rootDueBucketById: self.cacheStorage.rootDueBucket)
        },
        hasAnyTag: { [weak self] task in
          self?.hasAnyTag(task) ?? false
        },
        hasTag: { [weak self] task, tag in
          self?.hasTag(task, tag: tag) ?? false
        },
        rootDueBucket: { [weak self] task in
          self?.rootDueBucket(for: task) ?? .noDueDate
        }
      ))
  }
  private func computeRootLevelTagNames(limit: Int) -> [String] {
    var counts: [String: Int] = [:]
    for tags in cacheStorage.tagsByTaskId.values {
      for tag in tags {
        counts[tag, default: 0] += 1
      }
    }
    return
      counts
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
      }
      .prefix(limit)
      .map(\.key)
  }

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    if let cached = cacheStorage.rootDueBucket[task.id] { return cached }
    return TaskFilterEngine.classifyDueBucket(task: task)
  }

  private func hasAnyTag(_ task: CheckvistTask) -> Bool {
    cacheStorage.tagsByTaskId[task.id] != nil
  }

  private func hasTag(_ task: CheckvistTask, tag: String) -> Bool {
    guard let tags = cacheStorage.tagsByTaskId[task.id] else { return false }
    let normalized: String
    if tag.hasPrefix("#") || tag.hasPrefix("@") {
      normalized = tag.lowercased()
    } else {
      normalized = "#\(tag.lowercased())"
    }
    return tags.contains(normalized)
  }

  private func taskMatchesActiveRootScope(_ task: CheckvistTask) -> Bool {
    switch rootTaskView {
    case .all: return true
    case .due:
      let bucket = rootDueBucket(for: task)
      if selectedRootDueBucketRawValue != -1 {
        return bucket == RootDueBucket(rawValue: selectedRootDueBucketRawValue)
      }
      return bucket != .noDueDate
    case .tags:
      if selectedRootTag.isEmpty { return hasAnyTag(task) }
      return hasTag(task, tag: selectedRootTag)
    case .priority:
      return cacheStorage.absolutePriorityRank[task.id] != nil || cacheStorage.priorityRank[task.id] != nil
    case .kanban:
      return true
    case .eisenhower:
      return true
    case .daily:
      // Unreachable in practice: `TaskVisibilityEngine` returns an empty list
      // for Daily before any per-task scoping runs, because the view renders
      // the log rather than the task list. Matches `.kanban` / `.eisenhower`.
      return true
    }
  }

  // MARK: - View-derived badge / section helpers
  // Consolidated from `AppCoordinator+TaskScoping` (Phase 3 follow-up): these read
  // purely from the rebuilt `cache` (+ `repository`/`navigationState`/`quickEntry`
  // this VM already owns), so they belong with the cache rather than forwarded
  // through the coordinator. Views read them via `@Environment(TaskListViewModel.self)`.

  func priorityRank(for task: CheckvistTask) -> Int? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.priorityRank[task.id]
  }

  func absolutePriorityRank(for task: CheckvistTask) -> Int? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.absolutePriorityRank[task.id]
  }

  func priorityPath(for task: CheckvistTask) -> String? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.priorityPath[task.id]
  }

  func priorityBadgeLabel(for task: CheckvistTask) -> String? {
    if let absolute = absolutePriorityRank(for: task) {
      return "A\(absolute)"
    }
    if let scoped = priorityPath(for: task) {
      return "P\(scoped)"
    }
    return nil
  }

  func eisenhowerBadgeLabel(for task: CheckvistTask) -> String? {
    guard let level = repository.taskEisenhowerLevels[task.id],
      MatrixGeometry.isPlaced(urgency: level.urgency, importance: level.importance)
    else { return nil }
    return "M(\(formatEisenhowerCoordinate(level.urgency)),\(formatEisenhowerCoordinate(level.importance)))"
  }

  private func formatEisenhowerCoordinate(_ value: Double) -> String {
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(format: "%.1f", value)
  }

  /// Exposes the boundary (if any) at which non-matching "remainder" tasks begin
  /// within `visibleTasks`. Computed by `TaskVisibilityEngine` for due/tags/priority
  /// root views.
  var remainderStartIndex: Int? {
    ensureVisibleTasksCacheValid()
    return cacheStorage.remainderStartIndex
  }

  var isRootLevel: Bool { hostCurrentParentId == 0 }

  var shouldShowRootScopeSection: Bool { !hostIsSearchFilterActive }

  var rootScopeShowsFilterControls: Bool {
    guard shouldShowRootScopeSection && isRootLevel else { return false }
    switch rootTaskView {
    case .due, .tags:
      return true
    case .all, .priority, .kanban, .eisenhower, .daily:
      return false
    }
  }

  private var shouldShowDueSectionHeaders: Bool {
    isRootLevel && shouldShowRootScopeSection && rootTaskView == .due
      && selectedRootDueBucket == nil
  }

  func rootDueSectionHeader(atVisibleIndex index: Int, visibleTasks: [CheckvistTask]) -> String? {
    guard shouldShowDueSectionHeaders, visibleTasks.indices.contains(index) else { return nil }
    // Due-bucket section headers only apply to the matching portion of the list.
    // Remainder tasks get their own header via `remainderSectionHeader`.
    if let remainderStart = remainderStartIndex, index >= remainderStart { return nil }
    // Expanded children belong to the row above them, not to a bucket of their
    // own — a subtask due next month must not push a "Next month" header into
    // the middle of today's section.
    guard outlineDepth(atVisibleIndex: index) == 0 else { return nil }
    let currentBucket = rootDueBucket(for: visibleTasks[index])
    guard let previousIndex = (0..<index).reversed().first(where: { outlineDepth(atVisibleIndex: $0) == 0 })
    else { return currentBucket.title }
    let previousBucket = rootDueBucket(for: visibleTasks[previousIndex])
    return previousBucket == currentBucket ? nil : currentBucket.title
  }

  /// Returns the header title to display just before the task at the given index, or
  /// nil when no remainder header belongs there. Only the boundary index produces a
  /// header.
  func remainderSectionHeader(atVisibleIndex index: Int) -> String? {
    guard let start = remainderStartIndex, index == start else { return nil }
    switch rootTaskView {
    case .due:
      return start == 0 ? "All tasks" : "Other tasks"
    case .tags:
      return start == 0 ? "Untagged" : "Other tasks"
    case .priority:
      return start == 0 ? "Unprioritised" : "Other tasks"
    case .all, .kanban, .eisenhower, .daily:
      return nil
    }
  }

  func rootDueSectionCount(in visibleTasks: [CheckvistTask]) -> Int {
    guard shouldShowDueSectionHeaders, !visibleTasks.isEmpty else { return 0 }
    var total = 0
    var previousBucket: RootDueBucket?
    for (index, task) in visibleTasks.enumerated() {
      // Mirrors `rootDueSectionHeader`: only top-level rows start a section.
      guard outlineDepth(atVisibleIndex: index) == 0 else { continue }
      let bucket = rootDueBucket(for: task)
      if bucket != previousBucket {
        total += 1
        previousBucket = bucket
      }
    }
    return total
  }

  func rootLevelTagNames(limit: Int = 8) -> [String] {
    ensureVisibleTasksCacheValid()
    return Array(cacheStorage.rootLevelTagNames.prefix(limit))
  }

  /// Returns true if task is a descendant of the given parentId (or IS at that level).
  ///
  /// Ensures the cache first: `taskById` has to reflect the *current* task list
  /// or callers such as `subtreeBlockRange` compute a wrong range. This used to
  /// be correct only because `invalidateCaches()` rebuilt eagerly.
  func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
    ensureVisibleTasksCacheValid()
    return TaskFilterEngine.isDescendant(task, of: rootId, taskById: cacheStorage.taskById)
  }

  /// Computes a hierarchical priority path per ranked task. For each ranked task, walks
  /// from the root of its ancestor chain down to itself; each ancestor contributes its
  /// own rank-in-parent-scope or "=" if unranked in that scope.
  static func computePriorityPaths(
    rankByTaskId: [Int: Int],
    taskById: [Int: CheckvistTask]
  ) -> [Int: String] {
    var result: [Int: String] = [:]
    for taskId in rankByTaskId.keys {
      guard let task = taskById[taskId] else { continue }
      var chain: [CheckvistTask] = []
      var cursor: CheckvistTask? = task
      // See `TaskFilterEngine.isDescendant` for why the visited set is here.
      var seen: Set<Int> = []
      while let current = cursor, seen.insert(current.id).inserted {
        chain.append(current)
        if let pid = current.parentId, pid != 0, let parent = taskById[pid] {
          cursor = parent
        } else {
          cursor = nil
        }
      }
      chain.reverse()  // root-first
      let segments: [String] = chain.map { node in
        if let rank = rankByTaskId[node.id] { return String(rank) }
        return "="
      }
      result[taskId] = segments.joined(separator: ".")
    }
    return result
  }

  // MARK: - Task Scoping & Timing Helpers

  /// Tasks visible at the current level, sorted by position
  var currentLevelTasks: [CheckvistTask] {
    repository.tasks.filter { ($0.parentId ?? 0) == hostCurrentParentId }
  }

  var currentTask: CheckvistTask? {
    // The board and its selection went with the legacy surface, and
    // `visibleTasks` is empty here by design, so there is nothing to select.
    if rootTaskView == .kanban {
      return nil
    }
    // The matrix, likewise, is not the task list: `visibleTasks` is empty here
    // by design, so the index below would have nothing to index into. A
    // selected task that has since been completed or deleted leaves the plot,
    // and leaves the selection with it.
    if rootTaskView == .eisenhower {
      ensureVisibleTasksCacheValid()
      guard let id = host?.matrixSelectedTaskId, let task = cacheStorage.taskById[id],
        task.status == 0
      else { return nil }
      return task
    }
    let level = visibleTasks
    guard !level.isEmpty else { return nil }
    let clampedIndex = min(max(hostCurrentSiblingIndex, 0), level.count - 1)
    return level[clampedIndex]
  }

  var currentTaskText: String { currentTask?.content ?? "" }

  /// Breadcrumb chain from root down to (but not including) current task
  var breadcrumbs: [CheckvistTask] {
    ensureVisibleTasksCacheValid()
    var result: [CheckvistTask] = []
    var parentId = hostCurrentParentId
    // See `TaskFilterEngine.isDescendant` for why the visited set is here.
    var seen: Set<Int> = []
    while parentId != 0, seen.insert(parentId).inserted {
      if let parent = cacheStorage.taskById[parentId] {
        result.append(parent)
        parentId = parent.parentId ?? 0
      } else {
        break
      }
    }
    result.reverse()
    return result
  }

  /// Children of the currently focused task
  var currentTaskChildren: [CheckvistTask] {
    guard let task = currentTask else { return [] }
    return repository.tasks.filter { ($0.parentId ?? 0) == task.id }
  }

  /// `visibleTasks` with its indent levels — what the outline actually is.
  var outlineRows: [TaskOutlineRow] {
    let tasks = visibleTasks
    ensureVisibleTasksCacheValid()
    let depths = cacheStorage.outlineDepths
    return tasks.enumerated().map { index, task in
      TaskOutlineRow(task: task, depth: index < depths.count ? depths[index] : 0)
    }
  }

  func outlineDepth(atVisibleIndex index: Int) -> Int {
    ensureVisibleTasksCacheValid()
    guard cacheStorage.outlineDepths.indices.contains(index) else { return 0 }
    return cacheStorage.outlineDepths[index]
  }

  func isExpanded(_ task: CheckvistTask) -> Bool {
    repository.expandedTaskIds.contains(task.id)
  }

  var visibleTasks: [CheckvistTask] {
    // The `_ = repository.x` roll-call that used to sit here is gone:
    // `ensureVisibleTasksCacheValid()` reads `cacheVersion`, which every one of
    // those inputs bumps through `CacheInvalidationBus`. One dependency, and it
    // cannot fall behind the set of things the rebuild actually reads.
    ensureVisibleTasksCacheValid()
    return cacheStorage.visibleTasks
  }

  func shouldShowBreadcrumbPath(for task: CheckvistTask, depth: Int = 0) -> Bool {
    // An expanded child sits directly under its parent, so its path is on
    // screen already; repeating it above every subtask is noise.
    guard depth == 0 else { return false }
    let pid = task.parentId ?? 0
    if isRootLevel && shouldShowRootScopeSection && rootTaskView != .all {
      return pid != 0
    }
    if isSearchFilterActive {
      return pid != hostCurrentParentId
    }
    if hostShowsBreadcrumbContext {
      return pid != 0
    }
    return false
  }

  var isSearchFilterActive: Bool { hostIsSearchFilterActive }

  func subtreeBlockRange(for taskId: Int, in flatTasks: [CheckvistTask]) -> Range<Int>? {
    ensureVisibleTasksCacheValid()
    guard let start = flatTasks.firstIndex(where: { $0.id == taskId }) else { return nil }

    var end = start + 1
    while end < flatTasks.count {
      let candidate = flatTasks[end]
      if isDescendant(candidate, of: taskId) {
        end += 1
      } else {
        break
      }
    }
    return start..<end
  }

  func totalElapsed(forTaskId taskId: Int) -> TimeInterval {
    rolledUpElapsedByTaskId()[taskId] ?? 0
  }

  func totalElapsed(for task: CheckvistTask) -> TimeInterval {
    totalElapsed(forTaskId: task.id)
  }

  func childCountByTaskId() -> [Int: Int] {
    ensureVisibleTasksCacheValid()
    return cacheStorage.childCount
  }

  func rolledUpElapsedByTaskId() -> [Int: TimeInterval] {
    // Touch the observable dictionary so SwiftUI re-renders on per-second
    // ticks. Without this, callers only read the @ObservationIgnored cache
    // and never establish a dependency on `hostTimerElapsedByTaskId`.
    _ = hostTimerElapsedByTaskId
    ensureVisibleTasksCacheValid()
    return cacheStorage.rolledUpElapsed
  }
}
