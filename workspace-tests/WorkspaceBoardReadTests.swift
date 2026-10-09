import Foundation
import TaktCore
import TaktWorkspace
import XCTest

/// The core reads a combined scope's board (`WorkspaceStore.combinedBoard`)
/// so that only what the board draws crosses. It has to be the board the
/// desktop built from every list's tree before: the same cards in the same
/// order, the same trees, parents and placements.
final class WorkspaceBoardReadTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoardRead-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("tasks.sqlite"))
    workspaceID = try store.bootstrapIfNeeded().id
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  /// Every case the selection and the walk turn on: nesting several levels
  /// deep, finished and cancelled subtasks finished at different moments,
  /// open work beneath a finished task, nested lists open, archived and
  /// closed, a list shown through its wrapper, a list with nothing open, a
  /// list holding only a finished list, and placements on rows at every
  /// level, a hidden one's included.
  private func seed() throws {
    let work = try store.createList(workspaceId: workspaceID, name: "Work")
    let home = try store.createList(workspaceId: workspaceID, name: "Home")
    let quiet = try store.createList(workspaceId: workspaceID, name: "Quiet")
    let shut = try store.createList(workspaceId: workspaceID, name: "Shut")

    let project = try store.createTask(listId: work.id, title: "Project")
    let step = try store.createTask(listId: work.id, title: "Step", parentTaskId: project.id)
    let part = try store.createTask(listId: work.id, title: "Part", parentTaskId: step.id)
    let detail = try store.createTask(listId: work.id, title: "Detail", parentTaskId: part.id)
    let early = try store.createTask(listId: work.id, title: "Done early", parentTaskId: project.id)
    let late = try store.createTask(listId: work.id, title: "Done late", parentTaskId: step.id)
    let dropped = try store.createTask(listId: work.id, title: "Dropped", parentTaskId: project.id)
    try store.setStatus(.completed, for: early.id, now: base.addingTimeInterval(-60))
    try store.setStatus(.completed, for: late.id, now: base.addingTimeInterval(1))
    try store.setStatus(.cancelled, for: dropped.id, now: base.addingTimeInterval(-3_600))
    // Added after, as finishing a task finishes what is beneath it.
    let beneath = try store.createTask(listId: work.id, title: "Open beneath done", parentTaskId: early.id)
    let reading = try store.createTask(listId: work.id, title: "Reading", kind: .list)
    let papers = try store.createTask(listId: work.id, title: "Papers", parentTaskId: reading.id, kind: .list)
    let paper = try store.createTask(listId: work.id, title: "Paper", parentTaskId: papers.id)
    _ = try store.createTask(listId: work.id, title: "Paper note", parentTaskId: paper.id)
    let old = try store.createTask(listId: work.id, title: "Old", kind: .list)
    _ = try store.createTask(listId: work.id, title: "Stale", parentTaskId: old.id)
    try store.setNestedListArchived(true, id: old.id)
    let closed = try store.createTask(listId: work.id, title: "Closed", kind: .list)
    _ = try store.createTask(listId: work.id, title: "Inside closed", parentTaskId: closed.id)
    try store.setStatus(.completed, for: closed.id, now: base.addingTimeInterval(-10))
    // An archived list inside a card's tree, which the tree leaves out.
    let shelf = try store.createTask(listId: work.id, title: "Shelf", parentTaskId: project.id, kind: .list)
    _ = try store.createTask(listId: work.id, title: "On the shelf", parentTaskId: shelf.id)
    try store.setNestedListArchived(true, id: shelf.id)

    let wrapper = try store.createTask(listId: home.id, title: "Home", kind: .list)
    let chores = try store.createTask(listId: home.id, title: "Chores", parentTaskId: wrapper.id)
    _ = try store.createTask(listId: home.id, title: "Dishes", parentTaskId: chores.id)
    try store.saveListSettings(
      id: home.id, name: home.name, colorHex: nil, folderId: nil, isArchived: false,
      visibleRootTaskId: wrapper.id)

    let finished = try store.createTask(listId: quiet.id, title: "Finished")
    try store.setStatus(.completed, for: finished.id, now: base.addingTimeInterval(-5))
    let gone = try store.createTask(listId: shut.id, title: "Gone", kind: .list)
    _ = try store.createTask(listId: shut.id, title: "Gone task", parentTaskId: gone.id)
    try store.setStatus(.completed, for: gone.id, now: base)

    try store.setKanbanColumn("doing", for: [step.id, detail.id, early.id, dropped.id])
    try store.setKanbanColumn("done", for: [beneath.id, late.id])
    try store.setMatrixPosition(TaskMatrixPosition(urgency: 1, importance: 0), for: part.id)
    try store.setMatrixPosition(TaskMatrixPosition(urgency: 0, importance: 1), for: early.id)
  }

  /// The board as `reloadBoardNow` used to build it, finished tasks hidden
  /// before `cutoff`.
  private func boardFromTrees(lists: [TaskList], cutoff: Date?) throws -> WorkspaceBoardRead {
    let trees = try store.listTrees(in: lists.map(\.id))
    let cards = lists.flatMap { trees[$0.id]?.actionableTasks(visibleRootTaskId: $0.visibleRootTaskId) ?? [] }
    let listIDs = Array(Set(cards.map(\.listId)))
    let board = WorkspaceBoardTrees(cardIDs: Set(cards.map(\.id)), trees: listIDs.compactMap { trees[$0] })
    let descendants = board.descendants.mapValues { $0.filter { !hides($0.task, cutoff: cutoff) } }
    var seen = Set<String>()
    let treeTasks = (cards + cards.flatMap { descendants[$0.id, default: []].map(\.task) })
      .filter { seen.insert($0.id).inserted }
    let metadata = try store.boardMetadata(for: treeTasks.map(\.id))
    return WorkspaceBoardRead(
      cards: cards, descendants: descendants, parentIDs: board.parents.mapValues(\.id),
      columns: metadata.columns, positions: metadata.positions)
  }

  private func hides(_ task: WorkspaceTask, cutoff: Date?) -> Bool {
    guard let cutoff, task.status != .open else { return false }
    guard let completedAt = task.completedAt else { return true }
    return completedAt < cutoff
  }

  /// The core's read, with its placements cut to the board's own rows as
  /// `reloadBoardNow` cuts them.
  private func boardFromCore(lists: [TaskList], cutoff: Date?) throws -> WorkspaceBoardRead {
    var read = try store.combinedBoard(listIds: lists.map(\.id), hidingCompletedBefore: cutoff)
    var seen = Set<String>()
    let ids = Set((read.cards + read.cards.flatMap { read.descendants[$0.id, default: []].map(\.task) })
      .filter { seen.insert($0.id).inserted }.map(\.id))
    read.columns = read.columns.filter { ids.contains($0.key) }
    read.positions = read.positions.filter { ids.contains($0.key) }
    return read
  }

  func testTheCoreBoardIsTheBoardTheTreesGive() throws {
    try seed()
    let lists = try store.lists(in: workspaceID).filter { $0.completedAt == nil }
    let cutoffs: [Date?] = [
      nil, base.addingTimeInterval(-7_200), base.addingTimeInterval(-30), base, base.addingTimeInterval(3_600),
    ]
    for cutoff in cutoffs {
      let expected = try boardFromTrees(lists: lists, cutoff: cutoff)
      let actual = try boardFromCore(lists: lists, cutoff: cutoff)
      XCTAssertEqual(actual.cards.map(\.title), expected.cards.map(\.title), "cutoff \(String(describing: cutoff))")
      XCTAssertEqual(actual.descendants, expected.descendants, "cutoff \(String(describing: cutoff))")
      XCTAssertEqual(actual.parentIDs, expected.parentIDs, "cutoff \(String(describing: cutoff))")
      XCTAssertEqual(actual, expected, "cutoff \(String(describing: cutoff))")
    }
    // The seed reaches the cases it is for.
    let read = try boardFromCore(lists: lists, cutoff: base)
    let titles = Set(read.cards.map(\.title))
    XCTAssertTrue(titles.isSuperset(of: ["Project", "Detail", "Open beneath done", "Paper", "Chores", "Dishes"]))
    XCTAssertTrue(titles.isDisjoint(with: ["Home", "Stale", "Inside closed", "Reading", "On the shelf", "Gone task"]))
    let project = try XCTUnwrap(read.cards.first { $0.title == "Project" })
    XCTAssertEqual(
      read.descendants[project.id]?.map(\.task.title),
      ["Step", "Part", "Detail", "Done late", "Open beneath done"])
  }

  /// A folder's scope is a subset of the lists, in the folder's order.
  func testAFolderScopeInItsOwnOrder() throws {
    try seed()
    let lists = try store.lists(in: workspaceID).filter { $0.completedAt == nil }
    let scoped = [lists[2], lists[1], lists[0]]
    XCTAssertEqual(
      try boardFromCore(lists: scoped, cutoff: base), try boardFromTrees(lists: scoped, cutoff: base))
    XCTAssertEqual(try store.combinedBoard(listIds: [], hidingCompletedBefore: nil), .empty)
  }
}
