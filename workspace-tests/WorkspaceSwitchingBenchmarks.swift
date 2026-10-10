import Foundation
import TaktCore
import TaktRustCore
import XCTest

@testable import TaktWorkspace

/// What a switch costs the main thread — a list to the next, Everything, a
/// folder, Today, a change of view mode — on the seeded workspace of
/// `WorkspacePerformanceBenchmarks`. Opt-in the same way:
///
///     TAKT_PERF=1 swift test -c release --filter WorkspaceSwitchingBenchmarks
///
/// A switch's work is all on the main thread, so the time to the new content
/// being ready and the time the main thread is blocked are the same number:
/// reading the scope, shaping it, and the indexes the view model builds from
/// the shape (`applyCost`), in the order `WorkspaceViewModel` makes them.
/// "before" is how every switch went before scopes were kept resident
/// (`WorkspaceScopeCache`); "after" is how they go now. SwiftUI's own layout
/// is not in these numbers: the `Switching` signposts (`SwitchSignpost`) time
/// that in Instruments. See `docs/performance.md`.
final class WorkspaceSwitchingBenchmarks: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["TAKT_PERF"] == "1", "set TAKT_PERF=1 to run")
  }

  private let options = WorkspaceScopeShapeOptions(scopeTaskID: nil, registeredRootTaskID: nil, hidesCompletedTasks: true)

  /// Median and minimum of `runs` calls, in milliseconds, after one to warm.
  private func time(_ label: String, runs: Int = 9, _ body: () throws -> Void) rethrows {
    var samples: [Double] = []
    try body()
    for _ in 0..<runs {
      let start = DispatchTime.now().uptimeNanoseconds
      try body()
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    samples.sort()
    print(String(format: "PERF %-58@ median %8.2f ms  min %8.2f ms", label as NSString, samples[samples.count / 2], samples[0]))
  }

  /// The view model's work once it has a shape: the outline's fold and
  /// grouping, the task cache, and — unless the shape is one it has indexed
  /// before (`BoardIndexMemo`) — the board's columns, matrix quadrants and
  /// the arrow keys' row index.
  private func applyCost(outline: [TaskOutlineItem], board: WorkspaceBoardShape, indexesBoard: Bool = true) {
    _ = Dictionary(grouping: outline) { $0.task.listId }
    _ = TaskOutlineFolding.parentIDs(outline)
    _ = TaskOutlineFolding.visible(outline, folded: [])
    if indexesBoard {
      let cards = board.cards + board.crossColumnTasks
      _ = Set(cards.map(\.id))
      _ = Set(board.columns.values)
      let byColumn = Dictionary(grouping: cards) { board.columns[$0.id] ?? "backlog" }
      _ = MatrixQuadrantIndex(board.cards) { task in
        let position = board.positions[task.id]
        return (position?.urgency, position?.importance)
      }
      for (_, cards) in byColumn {
        _ = BoardColumnRows(cards: cards.map { card in
          (id: card.id, rowIDs: TaskOutlineFolding.visible(board.descendants[card.id] ?? [], folded: [])
            .prefix(12).map(\.task.id))
        })
      }
    }
    var cache: [String: WorkspaceTask] = [:]
    cache.reserveCapacity(board.treeTasks.count + outline.count)
    for item in outline { cache[item.id] = item.task }
    for task in board.treeTasks { cache[task.id] = task }
  }

  /// The switch as it was: every switch read its scope again and shaped it.
  private func coldSwitch(_ scope: WorkspaceScope, store: WorkspaceStore, outline: Bool, board: Bool) throws {
    let cutoff: Date? = if case .combined = scope { Date().addingTimeInterval(-3) } else { nil }
    let read = try store.scopeRead(scope, hidingCompletedBefore: cutoff)
    let items = outline ? WorkspaceScopeShaping.outline(read, options: options, now: Date()).items : []
    let shape = board ? WorkspaceScopeShaping.board(read, options: options, now: Date()).board : .empty
    applyCost(outline: items, board: shape)
    _ = try store.undoableLabel()
    _ = try store.redoableLabel()
  }

  /// The switch now, to a scope the cache holds at the store's stamp.
  private func residentSwitch(
    _ scope: WorkspaceScope, cache: WorkspaceScopeCache, store: WorkspaceStore, outline: Bool, board: Bool
  ) throws {
    let stamp = try store.changeStamp()
    XCTAssertEqual(cache.entry(for: scope)?.stamp, stamp)
    cache.touch(scope)
    let items = outline ? cache.outline(for: scope, options: options, now: Date())?.items ?? [] : []
    let shape = board ? cache.board(for: scope, options: options, now: Date())?.board ?? .empty : .empty
    applyCost(outline: items, board: shape, indexesBoard: false)
    _ = try store.undoableLabel()
    _ = try store.redoableLabel()
  }

  func testScopeSwitching() throws {
    let store = try WorkspacePerformanceBenchmarks.seededStore()
    let workspace = try store.bootstrapIfNeeded()
    let lists = try store.lists(in: workspace.id).filter { $0.completedAt == nil }
    let folders = try store.folders(in: workspace.id)
    let listA = WorkspaceScope.list(lists[5].id)
    let listB = WorkspaceScope.list(lists[6].id)
    let everything = WorkspaceScope.combined(lists.map(\.id))
    let folder = WorkspaceScope.combined(lists.filter { $0.folderId == folders[1].id }.map(\.id))

    print("PERF -- before: every switch reads its scope again")
    try time("list -> list (board)") { try coldSwitch(listB, store: store, outline: true, board: true) }
    try time("list -> list (outline, the inbox)") { try coldSwitch(listB, store: store, outline: true, board: false) }
    try time("-> Everything (board)", runs: 7) { try coldSwitch(everything, store: store, outline: false, board: true) }
    try time("-> folder (board)", runs: 7) { try coldSwitch(folder, store: store, outline: false, board: true) }
    // Today sits on Everything and sets its board aside, so it read nothing
    // but the history labels before either.
    try time("-> Today (board set aside: labels only)") {
      _ = try store.undoableLabel()
      _ = try store.redoableLabel()
    }
    try time("Everything board -> outline", runs: 7) {
      try coldSwitch(everything, store: store, outline: true, board: false)
    }
    try time("Everything outline -> board", runs: 7) {
      try coldSwitch(everything, store: store, outline: false, board: true)
    }

    print("PERF -- after: resident scopes (WorkspaceScopeCache)")
    let cache = WorkspaceScopeCache(capacity: 8)
    let stamp = try store.changeStamp()
    for scope in [listA, listB, everything, folder] {
      let cutoff: Date? = if case .combined = scope { Date().addingTimeInterval(-3) } else { nil }
      cache.store(try store.scopeRead(scope, hidingCompletedBefore: cutoff), for: scope, stamp: stamp, cutoff: cutoff)
    }
    // Shaped once, as the first visit does; every later visit reuses it.
    for scope in [listA, listB, everything, folder] {
      _ = cache.outline(for: scope, options: options, now: Date())
      _ = cache.board(for: scope, options: options, now: Date())
    }
    try time("list -> list (board), resident or prefetched") {
      try residentSwitch(listB, cache: cache, store: store, outline: true, board: true)
    }
    try time("list -> list (outline), resident") {
      try residentSwitch(listB, cache: cache, store: store, outline: true, board: false)
    }
    try time("-> Everything (board), resident") {
      try residentSwitch(everything, cache: cache, store: store, outline: false, board: true)
    }
    try time("-> folder (board), resident") {
      try residentSwitch(folder, cache: cache, store: store, outline: false, board: true)
    }
    try time("Everything board -> outline, resident") {
      try residentSwitch(everything, cache: cache, store: store, outline: true, board: false)
    }
    try time("Everything outline -> board, resident") {
      try residentSwitch(everything, cache: cache, store: store, outline: false, board: true)
    }

    // After a write elsewhere every kept read is behind. A list is read again
    // on the main thread, which for one list is cheap; a combined scope is
    // drawn as kept while the background reads it again.
    let target = try store.listTree(in: lists[20].id).children(of: nil)[2]
    var title = 0
    try time("list -> list after a write elsewhere (reread; incl. the write)") {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      let stamp = try store.changeStamp()
      cache.store(try store.scopeRead(listB, hidingCompletedBefore: nil), for: listB, stamp: stamp, cutoff: nil)
      try residentSwitch(listB, cache: cache, store: store, outline: true, board: true)
    }
    try time("-> Everything after a write elsewhere (drawn kept; incl. write)") {
      title += 1
      try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
      // The main thread's part: the stamp, the kept shapes.
      _ = try store.changeStamp()
      cache.touch(everything)
      let shape = cache.board(for: everything, options: options, now: Date())?.board ?? .empty
      applyCost(outline: [], board: shape, indexesBoard: false)
    }
    try time("  background reread + compare + shape (off the main thread)", runs: 5) {
      let read = try store.scopeRead(everything, hidingCompletedBefore: Date().addingTimeInterval(-3))
      _ = read == cache.entry(for: everything)?.read
      _ = WorkspaceScopeShaping.board(read, options: options, now: Date())
    }
    // What the main thread pays if that reread did find a change: the shape
    // came with it, so only the indexes.
    let reread = try store.scopeRead(everything, hidingCompletedBefore: Date().addingTimeInterval(-3))
    let rereadShape = WorkspaceScopeShaping.board(reread, options: options, now: Date()).board
    try time("  swap-in when the reread differs (main thread)") {
      applyCost(outline: [], board: rereadShape)
    }

    // A main-thread write made while a background reread of Everything is
    // running: on the store's own handle it queues behind the read; on the
    // background handle it does not.
    for inBackground in [false, true] {
      var waits: [Double] = []
      for _ in 0..<9 {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          _ = try? store.scopeRead(everything, hidingCompletedBefore: nil, inBackground: inBackground)
          group.leave()
        }
        usleep(2_000)
        title += 1
        let start = DispatchTime.now().uptimeNanoseconds
        try store.updateTask(id: target.id, title: "Renamed \(title)", notes: "", dueAt: nil, estimateSeconds: nil)
        waits.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        group.wait()
      }
      waits.sort()
      print(String(format: "PERF   main-thread write during a reread on the %@ handle  median %8.2f ms  max %8.2f ms",
        inBackground ? "background" : "store's own", waits[waits.count / 2], waits.last!))
    }

    // The overlays: neither reads a scope, and neither changed.
    print("PERF -- overlays (unchanged)")
    try time("command palette opens: matches for an empty query") {
      _ = WorkspaceCommandQuery.matches(query: "", surface: .board)
    }
    try time("inspector opens: store.taskEditorSnapshot(for:)") {
      _ = try store.taskEditorSnapshot(for: target.id)
    }

    // The pieces, to say where the before numbers go.
    print("PERF -- pieces")
    try time("  store.scopeRead(one list)") { _ = try store.scopeRead(listB, hidingCompletedBefore: nil) }
    try time("  store.scopeRead(Everything)", runs: 7) {
      _ = try store.scopeRead(everything, hidingCompletedBefore: Date().addingTimeInterval(-3))
    }
    let read = try store.scopeRead(everything, hidingCompletedBefore: Date().addingTimeInterval(-3))
    try time("  WorkspaceScopeShaping.board(Everything)") {
      _ = WorkspaceScopeShaping.board(read, options: options, now: Date())
    }
    let shape = WorkspaceScopeShaping.board(read, options: options, now: Date()).board
    try time("  view model indexes (Everything board)") { applyCost(outline: [], board: shape) }
    try time("  WorkspaceScopeRead == (Everything, background compare)") { _ = read == reread }
    let cards = shape.cards + shape.crossColumnTasks
    try time("    index: grouping by column + visible set") {
      _ = Set(cards.map(\.id))
      _ = Dictionary(grouping: cards) { shape.columns[$0.id] ?? "backlog" }
    }
    try time("    index: matrix quadrants") {
      _ = MatrixQuadrantIndex(shape.cards) { task in
        let position = shape.positions[task.id]
        return (position?.urgency, position?.importance)
      }
    }
    try time("    index: board row index") {
      _ = BoardColumnRows(cards: cards.map { card in
        (id: card.id, rowIDs: TaskOutlineFolding.visible(shape.descendants[card.id] ?? [], folded: [])
          .prefix(12).map(\.task.id))
      })
    }
    try time("    index: task cache") {
      var cache: [String: WorkspaceTask] = [:]
      cache.reserveCapacity(shape.treeTasks.count)
      for task in shape.treeTasks { cache[task.id] = task }
    }
    let other = WorkspaceScopeShaping.board(read, options: options, now: Date()).board
    try time("    shape == shape (the view model's assign-if-changed)") {
      _ = shape.cards == other.cards
      _ = shape.descendants == other.descendants
      _ = shape.parents == other.parents
      _ = shape.columns == other.columns
      _ = shape.positions == other.positions
    }
  }
}
