import Foundation
import TaktCore
import TaktWorkspace
import XCTest

final class WorkspaceDependencyTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var list: TaskList!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktDependencyTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    list = try XCTUnwrap(store.lists(in: workspace.id).first)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testABlockerIsListedBothWaysAndBlocksUntilDone() throws {
    let report = try store.createTask(listId: list.id, title: "Write report")
    let data = try store.createTask(listId: list.id, title: "Get data")

    XCTAssertTrue(try store.addBlocker(data.id, to: report.id))
    XCTAssertFalse(try store.addBlocker(data.id, to: report.id), "the same edge twice is one edge")

    XCTAssertEqual(try store.blockers(of: report.id).map(\.id), [data.id])
    XCTAssertEqual(try store.tasksBlocked(by: data.id).map(\.id), [report.id])
    XCTAssertEqual(try store.blockedTaskIds(), [report.id])
    XCTAssertTrue(try store.isTaskBlocked(report.id))
    XCTAssertFalse(try store.isTaskBlocked(data.id))

    try store.setStatus(.completed, for: data.id)
    XCTAssertTrue(try store.blockedTaskIds().isEmpty, "a done blocker no longer holds it back")
    XCTAssertFalse(try store.isTaskBlocked(report.id))
    XCTAssertEqual(try store.blockers(of: report.id).first?.status, .completed, "still listed, as done")
  }

  func testRemovingABlockerUnblocks() throws {
    let report = try store.createTask(listId: list.id, title: "Write report")
    let data = try store.createTask(listId: list.id, title: "Get data")
    try store.addBlocker(data.id, to: report.id)

    XCTAssertTrue(try store.removeBlocker(data.id, from: report.id))
    XCTAssertFalse(try store.removeBlocker(data.id, from: report.id))
    XCTAssertTrue(try store.blockers(of: report.id).isEmpty)
    XCTAssertTrue(try store.blockedTaskIds().isEmpty)
  }

  func testABlockedTaskSinksBelowItsUnblockedSiblings() throws {
    let first = try store.createTask(listId: list.id, title: "First")
    let second = try store.createTask(listId: list.id, title: "Second")
    let third = try store.createTask(listId: list.id, title: "Third")
    let other = try store.createTask(listId: list.id, title: "Elsewhere", parentTaskId: third.id)

    try store.addBlocker(other.id, to: first.id)

    let roots = try store.listTree(in: list.id).children(of: nil).map(\.id)
    XCTAssertEqual(roots, [second.id, third.id, first.id])
    XCTAssertEqual(try store.tasks(in: list.id).map(\.id), [second.id, third.id, first.id])

    try store.setStatus(.completed, for: other.id)
    XCTAssertEqual(try store.listTree(in: list.id).children(of: nil).map(\.id), [first.id, second.id, third.id])
  }

  func testACycleIsRefused() throws {
    let a = try store.createTask(listId: list.id, title: "A")
    let b = try store.createTask(listId: list.id, title: "B")
    let c = try store.createTask(listId: list.id, title: "C")
    try store.addBlocker(b.id, to: a.id)
    try store.addBlocker(c.id, to: b.id)

    XCTAssertThrowsError(try store.addBlocker(a.id, to: c.id)) { error in
      XCTAssertEqual(error as? WorkspaceStoreError, .dependencyCycle)
    }
    XCTAssertThrowsError(try store.addBlocker(a.id, to: a.id)) { error in
      XCTAssertEqual(error as? WorkspaceStoreError, .dependencyCycle)
    }
    XCTAssertTrue(try store.blockers(of: c.id).isEmpty)
  }

  func testAddingAndRemovingAreEachOneUndoStep() throws {
    let report = try store.createTask(listId: list.id, title: "Write report")
    let data = try store.createTask(listId: list.id, title: "Get data")

    try store.addBlocker(data.id, to: report.id)
    XCTAssertEqual(try store.undo(), "Add Blocker")
    XCTAssertTrue(try store.blockers(of: report.id).isEmpty)
    XCTAssertEqual(try store.redo(), "Add Blocker")
    XCTAssertEqual(try store.blockedTaskIds(), [report.id])

    try store.removeBlocker(data.id, from: report.id)
    XCTAssertEqual(try store.undo(), "Remove Blocker")
    XCTAssertEqual(try store.blockers(of: report.id).map(\.id), [data.id])
  }

  func testDeletingABlockerDropsTheEdgeAndUndoBringsItBack() throws {
    let report = try store.createTask(listId: list.id, title: "Write report")
    let data = try store.createTask(listId: list.id, title: "Get data")
    try store.addBlocker(data.id, to: report.id)

    try store.deleteTask(id: data.id)
    XCTAssertTrue(try store.blockers(of: report.id).isEmpty)
    _ = try store.undo()
    XCTAssertEqual(try store.blockers(of: report.id).map(\.id), [data.id])
  }
}
