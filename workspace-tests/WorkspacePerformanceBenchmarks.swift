import Foundation
import TaktCore
import TaktRustCore
import XCTest

@testable import TaktWorkspace

/// Timings for the reads the desktop makes on its hot paths, against a seeded
/// workspace of several thousand tasks. Opt-in, because seeding takes a while:
///
///     TAKT_PERF=1 swift test -c release --filter WorkspacePerformanceBenchmarks
///
/// The seeded file is kept in the temporary directory and reused by later runs
/// (delete `takt-perf-*.sqlite` there to reseed). It never touches the user's
/// own database. Each line printed is the median and the minimum of several
/// runs, in milliseconds.
final class WorkspacePerformanceBenchmarks: XCTestCase {
  static let listCount = 40
  static let rootsPerList = 25
  static let childrenPerRoot = 3
  static let grandchildrenPerChild = 1

  static var databaseURL: URL {
    let count = listCount * rootsPerList * (1 + childrenPerRoot * (1 + grandchildrenPerChild))
    return FileManager.default.temporaryDirectory.appendingPathComponent("takt-perf-\(count).sqlite")
  }

  override func setUpWithError() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["TAKT_PERF"] == "1", "set TAKT_PERF=1 to run")
  }

  /// Seeds once; a later run reuses the file.
  static func seededStore() throws -> WorkspaceStore {
    let url = databaseURL
    let fresh = !FileManager.default.fileExists(atPath: url.path)
    let store = try WorkspaceStore(databaseURL: url)
    guard fresh else { return store }
    let started = Date()
    let workspace = try store.bootstrapIfNeeded()
    var folders: [ListFolder] = []
    for index in 0..<4 {
      folders.append(try store.createFolder(workspaceId: workspace.id, name: "Folder \(index)"))
    }
    let now = Date()
    var completed: [String] = []
    var columned: [String] = []
    for listIndex in 0..<listCount {
      let list = try store.createList(
        workspaceId: workspace.id, name: "List \(listIndex)",
        folderId: listIndex % 3 == 0 ? nil : folders[listIndex % folders.count].id)
      for rootIndex in 0..<rootsPerList {
        let root = try store.createTask(
          listId: list.id, title: "Root \(listIndex).\(rootIndex) plan the thing",
          kind: rootIndex == 0 ? .list : .task,
          dueAt: rootIndex % 5 == 0 ? now.addingTimeInterval(Double(rootIndex - 10) * 86_400) : nil,
          estimateSeconds: rootIndex % 4 == 0 ? 1_800 : nil,
          tags: rootIndex % 6 == 0 ? ["home"] : [],
          priority: rootIndex % 7 == 0 ? 1 : nil)
        if rootIndex % 2 == 0 { columned.append(root.id) }
        for childIndex in 0..<childrenPerRoot {
          let child = try store.createTask(
            listId: list.id, title: "Child \(childIndex) of \(rootIndex)", parentTaskId: root.id)
          if childIndex == 0 && rootIndex % 3 == 0 { completed.append(child.id) }
          for grandIndex in 0..<grandchildrenPerChild {
            _ = try store.createTask(
              listId: list.id, title: "Grandchild \(grandIndex) of \(childIndex)", parentTaskId: child.id)
          }
        }
      }
    }
    try store.setKanbanColumn("doing", for: columned)
    for id in completed { try store.setStatus(.completed, for: id) }
    print("PERF seeded \(databaseURL.lastPathComponent) in \(Int(Date().timeIntervalSince(started)))s")
    return store
  }

  /// Median and minimum of `runs` calls, in milliseconds.
  @discardableResult
  func time(_ label: String, runs: Int = 9, _ body: () throws -> Void) rethrows -> Double {
    var samples: [Double] = []
    try body()  // warm
    for _ in 0..<runs {
      let start = DispatchTime.now().uptimeNanoseconds
      try body()
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    samples.sort()
    let median = samples[samples.count / 2]
    print(String(format: "PERF %-58@ median %8.2f ms  min %8.2f ms", label as NSString, median, samples[0]))
    return median
  }

  func testHotPathReads() throws {
    let store = try Self.seededStore()
    let workspace = try store.bootstrapIfNeeded()
    let lists = try store.lists(in: workspace.id)
    let listIDs = lists.map(\.id)
    let list = lists.first { $0.name == "List 5" } ?? lists[0]
    let raw = try CoreWorkspace.open(path: Self.databaseURL.path)

    var taskCount = 0
    try time("store.listTrees(all lists)  [sidebar, Everything]") {
      taskCount = try store.listTrees(in: listIDs).values.reduce(0) { $0 + $1.tasks.count }
    }
    print("PERF   tasks in workspace: \(taskCount), lists: \(lists.count)")
    try time("  core.tasksInLists(all) FFI only, no Swift records") { _ = try raw.tasksInLists(listIds: listIDs) }
    let rows = try raw.tasksInLists(listIds: listIDs)
    try time("  WorkspaceTask(row) conversion only") { _ = rows.map(WorkspaceTask.init) }
    let trees = try store.listTrees(in: listIDs)
    try time("  WorkspaceSidebarIndex(lists:trees:)") { _ = WorkspaceSidebarIndex(lists: lists, trees: trees) }
    let indexA = WorkspaceSidebarIndex(lists: lists, trees: trees)
    let indexB = WorkspaceSidebarIndex(lists: lists, trees: trees)
    try time("  sidebar index == (diff of nestedLists/counts)") { _ = indexA == indexB }

    try time("store.listTrees(one list)  [list switch, outline]") { _ = try store.listTrees(in: [list.id]) }
    let tree = try store.listTrees(in: [list.id])[list.id]!
    try time("  tree.visibleOutline(under: nil)") { _ = tree.visibleOutline(under: nil) }
    let outline = tree.visibleOutline(under: nil)
    let outlineCopy = tree.visibleOutline(under: nil)
    try time("  outline == outline (VM didSet diff)") { _ = outline == outlineCopy }
    try time("  TaskOutlineFolding.parentIDs+visible") {
      _ = TaskOutlineFolding.parentIDs(outline)
      _ = TaskOutlineFolding.visible(outline, folded: [])
    }

    // The board for one list: its cards, their trees, their metadata.
    let cards = tree.children(of: nil)
    let boardTrees = WorkspaceBoardTrees(cardIDs: Set(cards.map(\.id)), trees: [tree])
    try time("  WorkspaceBoardTrees(one list)") { _ = WorkspaceBoardTrees(cardIDs: Set(cards.map(\.id)), trees: [tree]) }
    let treeIDs = cards.map(\.id) + boardTrees.descendants.values.flatMap { $0.map(\.id) }
    try time("  store.boardMetadata(\(treeIDs.count) ids)") { _ = try store.boardMetadata(for: treeIDs) }

    // Everything's board: every list's actionable tasks.
    try time("Everything actionable (all trees + filter)") {
      let all = try store.listTrees(in: listIDs)
      _ = lists.flatMap { all[$0.id]?.actionableTasks(visibleRootTaskId: $0.visibleRootTaskId) ?? [] }
    }
    let actionable = lists.flatMap { trees[$0.id]?.actionableTasks(visibleRootTaskId: $0.visibleRootTaskId) ?? [] }
    print("PERF   actionable tasks in Everything: \(actionable.count)")
    try time("  WorkspaceBoardTrees(Everything)") {
      _ = WorkspaceBoardTrees(cardIDs: Set(actionable.map(\.id)), trees: Array(trees.values))
    }
    let allEverythingIDs = actionable.map(\.id)
    try time("  store.boardMetadata(Everything \(allEverythingIDs.count) ids)") {
      _ = try store.boardMetadata(for: allEverythingIDs)
    }

    // Per-refresh small reads.
    try time("store.undoableLabel + redoableLabel  [every refresh]") {
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }
    try time("store.waitingDetails  [every refresh]") { _ = try store.waitingDetails() }
    try time("store.tasks(ids: 10)  [task cache top-up]") { _ = try store.tasks(ids: Array(listIDs.prefix(0)) + cards.prefix(10).map(\.id)) }
    try time("store.task(id:)  [cache miss in a view body]") { _ = try store.task(id: cards[3].id) }
    try time("store.externalChangeToken  [1 Hz poll]") { _ = try store.externalChangeToken() }
    try time("store.kanbanBoardConfigurations  [per new scope]") {
      _ = try store.kanbanBoardConfigurations(legacy: [:], currentKey: "\(list.id)/root")
    }
    try time("store.completedTasks(since: 14d)  [done rail]") {
      _ = try store.completedTasks(since: Date().addingTimeInterval(-14 * 86_400))
    }
    try time("store.searchTasks(\"plan\")") { _ = try store.searchTasks(in: workspace.id, matching: "plan", limit: 50) }

    // Next up: the background read after every write. It holds the core's
    // one connection for each of its calls, so main-thread reads queue.
    try time("store.nextUpSnapshot  [after every write, background]", runs: 5) {
      _ = try store.nextUpSnapshot(workspaceId: workspace.id, context: FocusContext(), runningID: nil)
    }
    try time("  loggedWorkTotals") { _ = try store.loggedWorkTotals() }
    try time("  taskPlanningValues") { _ = try store.taskPlanningValues() }
    try time("  nextUpCandidates") { _ = try store.nextUpCandidates() }
    let candidates = try store.nextUpCandidates()
    print("PERF   next-up candidates: \(candidates.count)")
    try time("  DayPlanSelector.plan") { _ = DayPlanSelector.plan(candidates: candidates, runningID: nil, now: Date()) }
    try time("  NextUpSelector.evaluate (Rust ranking)") {
      _ = NextUpSelector.evaluate(candidates, now: Date(), context: FocusContext())
    }
    try time("  workProgress") { _ = try store.workProgress() }
    try time("  hasManualFocusOrder") { _ = try store.hasManualFocusOrder() }
  }

  /// One edit, then the reads `perform`'s refresh makes on the main thread for
  /// a single-list board scope (`flushPendingRefresh` with `.outline` and
  /// `.sidebar`), in the order the view model makes them.
  func testSingleEditRefreshOnMainThread() throws {
    let store = try Self.seededStore()
    let workspace = try store.bootstrapIfNeeded()
    let lists = try store.lists(in: workspace.id)
    let list = lists.first { $0.name == "List 5" } ?? lists[0]
    let target = try store.listTrees(in: [list.id])[list.id]!.children(of: nil)[2]
    var title = 0

    try time("write: updateTask(title) alone", runs: 15) {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
    }
    try time("write: setStatus done+open alone", runs: 7) {
      try store.setStatus(.completed, for: target.id)
      try store.setStatus(.open, for: target.id)
    }

    try time("refresh after one edit: outline+board+sidebar+cache", runs: 9) {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      // reloadOutlineNow + reloadBoardNow (one list, cached tree)
      var cache = try store.listTrees(in: [list.id])
      let tree = cache[list.id]!
      _ = tree.visibleOutline(under: nil)
      let cards = tree.children(of: nil)
      let board = WorkspaceBoardTrees(cardIDs: Set(cards.map(\.id)), trees: [tree])
      let ids = cards.map(\.id) + board.descendants.values.flatMap { $0.map(\.id) }
      _ = try store.boardMetadata(for: ids)
      // reloadNestedListsNow: every list
      let missing = lists.map(\.id).filter { cache[$0] == nil }
      for (id, tree) in try store.listTrees(in: missing) { cache[id] = tree }
      _ = WorkspaceSidebarIndex(lists: lists, trees: cache)
      // rebuildTaskCache + refreshHistoryLabels
      _ = try store.waitingDetails()
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }
    try time("  same, without the sidebar's every-list read", runs: 9) {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      let tree = try store.listTrees(in: [list.id])[list.id]!
      _ = tree.visibleOutline(under: nil)
      let cards = tree.children(of: nil)
      let board = WorkspaceBoardTrees(cardIDs: Set(cards.map(\.id)), trees: [tree])
      let ids = cards.map(\.id) + board.descendants.values.flatMap { $0.map(\.id) }
      _ = try store.boardMetadata(for: ids)
      _ = try store.waitingDetails()
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }
  }

  /// The same refresh in the Everything scope, which is what Today sits on
  /// (`selectToday` is `selectEverything` + the Today mode). The board is
  /// rebuilt for Everything whatever the view mode, so Today pays for it.
  func testSingleEditRefreshInEverythingScope() throws {
    let store = try Self.seededStore()
    let workspace = try store.bootstrapIfNeeded()
    let lists = try store.lists(in: workspace.id)
    let target = try store.listTrees(in: [lists[5].id])[lists[5].id]!.children(of: nil)[2]
    var title = 0
    var boardMs = 0.0
    try time("Everything refresh after one edit (board+sidebar+cache)", runs: 7) {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      let start = DispatchTime.now().uptimeNanoseconds
      let trees = try store.listTrees(in: lists.map(\.id))
      let tasks = lists.flatMap { trees[$0.id]?.actionableTasks(visibleRootTaskId: $0.visibleRootTaskId) ?? [] }
      let board = WorkspaceBoardTrees(cardIDs: Set(tasks.map(\.id)), trees: Array(trees.values))
      var seen = Set<String>()
      let treeTasks = (tasks + tasks.flatMap { board.descendants[$0.id, default: []].map(\.task) })
        .filter { seen.insert($0.id).inserted }
      _ = try store.boardMetadata(for: treeTasks.map(\.id))
      boardMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      _ = WorkspaceSidebarIndex(lists: lists, trees: trees)
      _ = try store.waitingDetails()
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }
    print(String(format: "PERF   of which the Everything board (unused on Today): %.2f ms", boardMs))

    // Today since the board is set aside while it is not on screen: the
    // sidebar still reads every tree when the edit could have changed a count,
    // but nothing walks them for cards or reads the cards' metadata.
    try time("Today refresh after one edit, board set aside (sidebar+cache)", runs: 7) {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      let trees = try store.listTrees(in: lists.map(\.id))
      _ = WorkspaceSidebarIndex(lists: lists, trees: trees)
      _ = try store.waitingDetails()
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }
    // An edit that refreshes only the main pane (`reloadOutline(refreshSidebar:
    // false)`, `reloadBoard()`): before, the whole board; now, no tree at all.
    try time("Today refresh, main pane only, board read (before)", runs: 7) {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      let trees = try store.listTrees(in: lists.map(\.id))
      let tasks = lists.flatMap { trees[$0.id]?.actionableTasks(visibleRootTaskId: $0.visibleRootTaskId) ?? [] }
      let board = WorkspaceBoardTrees(cardIDs: Set(tasks.map(\.id)), trees: Array(trees.values))
      var seen = Set<String>()
      let treeTasks = (tasks + tasks.flatMap { board.descendants[$0.id, default: []].map(\.task) })
        .filter { seen.insert($0.id).inserted }
      _ = try store.boardMetadata(for: treeTasks.map(\.id))
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }
    try time("Today refresh, main pane only, board set aside (after)", runs: 7) {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      // The columns come from the layouts cached per scope: no read.
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }

    // What applying a next-up snapshot costs the main thread: the equality
    // checks `applyNextUp` makes before assigning.
    let a = try store.nextUpSnapshot(workspaceId: workspace.id, context: FocusContext(), runningID: nil)
    let b = try store.nextUpSnapshot(workspaceId: workspace.id, context: FocusContext(), runningID: nil)
    try time("applyNextUp equality checks (ladder, planning, blocked)") {
      _ = a.ranking.ranked == b.ranking.ranked
      _ = a.planning == b.planning
      _ = a.ranking.blocked == b.ranking.blocked
      _ = a.loggedSeconds == b.loggedSeconds
    }
    print("PERF   ladder \(a.ranking.ranked.count), blocked \(a.ranking.blocked.count), planning \(a.planning.count)")
  }

  /// `WorkspaceViewModel.load()`'s own reads, on top of the refresh: what undo,
  /// redo, an external write (the CLI, MCP) and a sync pull add.
  func testLoadPathReads() throws {
    let store = try Self.seededStore()
    let workspace = try store.bootstrapIfNeeded()
    try time("load(): bootstrap+folders+lists+archived") {
      _ = try store.bootstrapIfNeeded()
      _ = try store.folders(in: workspace.id)
      _ = try store.lists(in: workspace.id)
      _ = try store.lists(in: workspace.id, includingArchived: true)
    }
    try time("reloadDailiesNow: reconcile x2 + dailies + allDailies") {
      _ = try store.reconcileHabits()
      _ = try store.reconcileWaitingFollowUps()
      _ = try store.dailies()
      _ = try store.allDailies()
    }
    try time("reloadFocus: session+points+blocks+awards") {
      _ = try store.activeFocusSession()
      _ = try store.focusPointsSummary()
      let today = Calendar.current.dateInterval(of: .day, for: Date())!
      _ = try store.focusWorkBlocks(in: today)
      _ = try store.focusWorkBlocks(in: today)
      _ = try store.focusAwards(onDayOf: Date())
    }
    try time("undo + redo (core)") {
      _ = try store.undo()
      _ = try store.redo()
    }
  }

  /// A main-thread read issued while the background next-up snapshot runs:
  /// how long it waits on the core's single `Mutex<Connection>`.
  func testMainThreadReadContendingWithNextUp() throws {
    let store = try Self.seededStore()
    let workspace = try store.bootstrapIfNeeded()
    let lists = try store.lists(in: workspace.id)
    let list = lists.first { $0.name == "List 5" } ?? lists[0]
    try time("one-list read, idle", runs: 15) { _ = try store.listTrees(in: [list.id]) }
    var waits: [Double] = []
    for _ in 0..<15 {
      let group = DispatchGroup()
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        _ = try? store.nextUpSnapshot(workspaceId: workspace.id, context: FocusContext(), runningID: nil)
        group.leave()
      }
      // Let the snapshot get going, as it does a turn after `perform`.
      usleep(1_000)
      let start = DispatchTime.now().uptimeNanoseconds
      _ = try store.listTrees(in: [list.id])
      waits.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
      group.wait()
    }
    waits.sort()
    print(String(format: "PERF one-list read during nextUpSnapshot  median %8.2f ms  max %8.2f ms",
      waits[waits.count / 2], waits.last!))
  }
}
