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

  var isRootLevel: Bool { hostCurrentParentId == 0 }

  /// Returns true if task is a descendant of the given parentId (or IS at that level).
  ///
  /// Ensures the cache first: `taskById` has to reflect the *current* task list
  /// or callers such as `subtreeBlockRange` compute a wrong range. This used to
  /// be correct only because `invalidateCaches()` rebuilt eagerly.
  func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
    ensureVisibleTasksCacheValid()
    return TaskFilterEngine.isDescendant(task, of: rootId, taskById: cacheStorage.taskById)
  }

  // MARK: - Task Scoping

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

  var visibleTasks: [CheckvistTask] {
    // The `_ = repository.x` roll-call that used to sit here is gone:
    // `ensureVisibleTasksCacheValid()` reads `cacheVersion`, which every one of
    // those inputs bumps through `CacheInvalidationBus`. One dependency, and it
    // cannot fall behind the set of things the rebuild actually reads.
    ensureVisibleTasksCacheValid()
    return cacheStorage.visibleTasks
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
}
