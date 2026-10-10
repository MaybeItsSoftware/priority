import Foundation
import TaktCore
import TaktWorkspace
import XCTest

/// The desktop keeps the scopes it has shown resident (`WorkspaceScopeCache`)
/// and shapes them once (`WorkspaceScopeShaping`). What it keeps has to be
/// what a fresh read would have drawn, and has to stop being used the moment
/// it is not.
final class WorkspaceScopeCacheTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScopeCache-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
    workspaceID = try store.bootstrapIfNeeded().id
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private let options = WorkspaceScopeShapeOptions(scopeTaskID: nil, registeredRootTaskID: nil, hidesCompletedTasks: true)

  private func makeList(_ name: String, tasks: Int = 2) throws -> TaskList {
    let list = try store.createList(workspaceId: workspaceID, name: name)
    for index in 0..<tasks {
      let root = try store.createTask(listId: list.id, title: "\(name) \(index)")
      _ = try store.createTask(listId: list.id, title: "\(name) \(index) child", parentTaskId: root.id)
    }
    return list
  }

  // MARK: - Shaping

  func testListBoardShapeMatchesTheTreeItWasReadFrom() throws {
    let list = try makeList("Work", tasks: 3)
    let tree = try store.listTree(in: list.id)
    let cards = tree.children(of: nil)
    try store.setKanbanColumn("doing", for: [cards[1].id])
    let read = try store.scopeRead(.list(list.id), hidingCompletedBefore: nil)

    let shape = WorkspaceScopeShaping.board(read, options: options, now: Date()).board
    let trees = WorkspaceBoardTrees(cardIDs: Set(cards.map(\.id)), trees: [tree])
    XCTAssertEqual(shape.cards, cards)
    XCTAssertEqual(shape.descendants, trees.descendants)
    XCTAssertEqual(shape.parents, trees.parents.mapValues(\.id))
    XCTAssertEqual(shape.columns, [cards[1].id: "doing"])
    // A placement for every row the board draws, and none for any it does not.
    let drawn = Set(shape.treeTasks.map(\.id))
    XCTAssertEqual(Set(shape.positions.keys), drawn)
    XCTAssertEqual(drawn.count, 6)
  }

  func testCombinedShapeIsTheCoreBoard() throws {
    let work = try makeList("Work")
    let home = try makeList("Home")
    let ids = [work.id, home.id]
    let board = try store.combinedBoard(listIds: ids, hidingCompletedBefore: nil)
    let read = try store.scopeRead(.combined(ids), hidingCompletedBefore: nil)
    let shape = WorkspaceScopeShaping.board(read, options: options, now: Date()).board
    XCTAssertEqual(shape.cards, board.cards)
    XCTAssertEqual(shape.descendants, board.descendants)
    XCTAssertEqual(WorkspaceScopeShaping.outline(read, options: options, now: Date()).items.map(\.id),
      board.cards.map(\.id))
  }

  func testAFinishedTaskLingersUntilItsExpiryThenGoes() throws {
    let list = try makeList("Work")
    let card = try store.listTree(in: list.id).children(of: nil)[0]
    let finished = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    try store.setStatus(.completed, for: card.id, now: finished)
    let read = try store.scopeRead(.list(list.id), hidingCompletedBefore: nil)

    let soon = WorkspaceScopeShaping.outline(read, options: options, now: finished.addingTimeInterval(1))
    XCTAssertTrue(soon.items.contains { $0.id == card.id })
    XCTAssertEqual(soon.expiry, finished.addingTimeInterval(WorkspaceScopeShaping.completedLingerInterval))
    let later = WorkspaceScopeShaping.outline(read, options: options, now: finished.addingTimeInterval(5))
    XCTAssertFalse(later.items.contains { $0.id == card.id })
    XCTAssertNil(later.expiry)
    let shown = WorkspaceScopeShapeOptions(scopeTaskID: nil, registeredRootTaskID: nil, hidesCompletedTasks: false)
    XCTAssertTrue(WorkspaceScopeShaping.outline(read, options: shown, now: finished.addingTimeInterval(5))
      .items.contains { $0.id == card.id })
  }

  func testTheBackgroundHandleReadsWhatTheMainOneDoes() throws {
    let work = try makeList("Work")
    let home = try makeList("Home")
    for scope in [WorkspaceScope.list(work.id), .combined([work.id, home.id])] {
      XCTAssertEqual(
        try store.scopeRead(scope, hidingCompletedBefore: nil, inBackground: true),
        try store.scopeRead(scope, hidingCompletedBefore: nil))
    }
    // And sees a write the main handle has just made.
    _ = try store.createTask(listId: work.id, title: "Written")
    guard case .list(let tree, _, _) = try store.scopeRead(.list(work.id), hidingCompletedBefore: nil, inBackground: true)
    else { return XCTFail("a list's read") }
    XCTAssertTrue(tree.tasks.contains { $0.title == "Written" })
  }

  // MARK: - The cache

  func testAKeptReadIsCurrentUntilSomethingIsWritten() throws {
    let list = try makeList("Work")
    let scope = WorkspaceScope.list(list.id)
    let cache = WorkspaceScopeCache()
    let stamp = try store.changeStamp()
    cache.store(try store.scopeRead(scope, hidingCompletedBefore: nil), for: scope, stamp: stamp, cutoff: nil)
    XCTAssertEqual(cache.entry(for: scope)?.stamp, try store.changeStamp())

    _ = try store.createTask(listId: list.id, title: "New")
    XCTAssertNotEqual(cache.entry(for: scope)?.stamp, try store.changeStamp())
    XCTAssertTrue(try store.changeStamp().isNewer(than: stamp))
  }

  func testShapesAreKeptAndReusedUntilTheReadChanges() throws {
    let list = try makeList("Work")
    let scope = WorkspaceScope.list(list.id)
    let cache = WorkspaceScopeCache()
    let read = try store.scopeRead(scope, hidingCompletedBefore: nil)
    cache.store(read, for: scope, stamp: try store.changeStamp(), cutoff: nil)
    let first = try XCTUnwrap(cache.board(for: scope, options: options, now: Date()))
    let again = try XCTUnwrap(cache.board(for: scope, options: options, now: Date()))
    XCTAssertEqual(first.generation, again.generation)

    // The same answer at a newer stamp keeps the shape.
    cache.store(read, for: scope, stamp: WorkspaceChangeStamp(external: 0, own: 1_000), cutoff: nil)
    XCTAssertEqual(cache.board(for: scope, options: options, now: Date())?.generation, first.generation)

    // A different answer is shaped afresh.
    _ = try store.createTask(listId: list.id, title: "New")
    cache.store(
      try store.scopeRead(scope, hidingCompletedBefore: nil), for: scope,
      stamp: WorkspaceChangeStamp(external: 0, own: 2_000), cutoff: nil)
    let fresh = try XCTUnwrap(cache.board(for: scope, options: options, now: Date()))
    XCTAssertNotEqual(fresh.generation, first.generation)
    XCTAssertTrue(fresh.board.cards.contains { $0.title == "New" })
  }

  func testAnOlderReadCannotReplaceANewerOne() throws {
    let list = try makeList("Work")
    let scope = WorkspaceScope.list(list.id)
    let cache = WorkspaceScopeCache()
    let old = try store.scopeRead(scope, hidingCompletedBefore: nil)
    _ = try store.createTask(listId: list.id, title: "New")
    let new = try store.scopeRead(scope, hidingCompletedBefore: nil)
    XCTAssertTrue(cache.store(new, for: scope, stamp: WorkspaceChangeStamp(external: 0, own: 5), cutoff: nil))
    XCTAssertFalse(cache.store(old, for: scope, stamp: WorkspaceChangeStamp(external: 0, own: 4), cutoff: nil))
    XCTAssertEqual(cache.entry(for: scope)?.read, new)
  }

  func testLeastRecentlyUsedGoesFirst() throws {
    let cache = WorkspaceScopeCache(capacity: 2)
    let lists = try (0..<3).map { try makeList("List \($0)", tasks: 1) }
    let stamp = try store.changeStamp()
    for list in lists.prefix(2) {
      cache.store(try store.scopeRead(.list(list.id), hidingCompletedBefore: nil), for: .list(list.id), stamp: stamp, cutoff: nil)
    }
    cache.touch(.list(lists[0].id))
    cache.store(try store.scopeRead(.list(lists[2].id), hidingCompletedBefore: nil), for: .list(lists[2].id), stamp: stamp, cutoff: nil)
    XCTAssertEqual(cache.scopes, [.list(lists[0].id), .list(lists[2].id)])
    XCTAssertNil(cache.entry(for: .list(lists[1].id)))
  }

  func testAPrefetchNeverPushesOutAScopeInUse() throws {
    let cache = WorkspaceScopeCache(capacity: 1, prefetchCapacity: 1)
    let lists = try (0..<3).map { try makeList("List \($0)", tasks: 1) }
    let stamp = try store.changeStamp()
    func read(_ index: Int) throws -> WorkspaceScopeRead {
      try store.scopeRead(.list(lists[index].id), hidingCompletedBefore: nil)
    }
    cache.store(try read(0), for: .list(lists[0].id), stamp: stamp, cutoff: nil)
    cache.store(try read(1), for: .list(lists[1].id), stamp: stamp, cutoff: nil, asPrefetch: true)
    cache.store(try read(2), for: .list(lists[2].id), stamp: stamp, cutoff: nil, asPrefetch: true)
    // The in-use scope stays; the newer guess replaced the older one.
    XCTAssertEqual(cache.scopes, [.list(lists[0].id)])
    XCTAssertEqual(cache.prefetchedScopes, [.list(lists[2].id)])
    XCTAssertNil(cache.entry(for: .list(lists[1].id)))

    // Going to the guess takes it into use, and only then does it count
    // against the scopes in use.
    cache.touch(.list(lists[2].id))
    XCTAssertEqual(cache.scopes, [.list(lists[2].id)])
    XCTAssertTrue(cache.prefetchedScopes.isEmpty)
  }
}
