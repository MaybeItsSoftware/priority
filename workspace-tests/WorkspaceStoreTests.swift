import Foundation
import PriorityWorkspace
import XCTest

final class WorkspaceStoreTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PriorityWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func testBootstrapCreatesOneWorkspaceAndInbox() throws {
    let workspace = try store.bootstrapIfNeeded()

    XCTAssertEqual(try store.workspaces().map(\.id), [workspace.id])
    XCTAssertEqual(try store.lists(in: workspace.id).map(\.name), ["Inbox"])
    XCTAssertEqual(try store.bootstrapIfNeeded().id, workspace.id)
  }

  func testOutlineKeepsHierarchyAndCompletingATaskPersists() throws {
    let workspace = try store.bootstrapIfNeeded()
    let list = try XCTUnwrap(store.lists(in: workspace.id).first)
    let root = try store.createTask(listId: list.id, title: "Project")
    let child = try store.createTask(listId: list.id, title: "First step", parentTaskId: root.id)

    let outline = try store.outline(in: list.id)
    XCTAssertEqual(outline.map { $0.task.title }, ["Project", "First step"])
    XCTAssertEqual(outline.map(\.depth), [0, 1])

    try store.setStatus(.completed, for: child.id)
    XCTAssertEqual(try store.task(id: child.id)?.status, .completed)
  }

  func testLegacyImportCreatesSeparateListAndRebuildsParents() throws {
    let workspace = try store.bootstrapIfNeeded()
    let imported = try XCTUnwrap(store.importLegacyTasks(
      workspaceId: workspace.id,
      listName: "Imported from old Priority",
      seeds: [
        .init(sourceId: "2", parentSourceId: "1", title: "Child", status: .completed, sortOrder: 0),
        .init(sourceId: "1", parentSourceId: nil, title: "Parent", status: .open, sortOrder: 0),
      ]))

    let outline = try store.outline(in: imported.id)
    XCTAssertEqual(outline.map { $0.task.title }, ["Parent", "Child"])
    XCTAssertEqual(outline.map(\.depth), [0, 1])
    XCTAssertEqual(outline.last?.task.status, .completed)
  }
}
