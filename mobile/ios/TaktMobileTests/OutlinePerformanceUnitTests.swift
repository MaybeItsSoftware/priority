import TaktWorkspace
import XCTest
@testable import Takt

/// The off-main work behind a 5,000-row outline: reading the tree and
/// flattening it, then re-folding it. Both run on a background task in the
/// app; these bound how long the outline waits before it can draw.
@MainActor
final class OutlinePerformanceUnitTests: XCTestCase {
  func testReadingAndFoldingFiveThousandTasksIsQuick() throws {
    let model = try WorkspaceModel.temporary()
    let store = model.store
    let list = try store.createList(workspaceId: model.workspace.id, name: "Big")
    for parent in 0..<250 {
      let project = try store.createTask(listId: list.id, title: "Project \(parent)")
      for child in 0..<19 {
        _ = try store.createTask(listId: list.id, title: "Task \(child)", parentTaskId: project.id)
      }
    }
    model.reloadStructureNow()
    let structure = model.structure

    var start = Date()
    let base = try OutlineBase.load(
      store: store, workspaceID: model.workspace.id, scope: .list(list.id), structure: structure, hidesCompleted: false)
    let rows = base.rows(folded: [])
    let readSeconds = Date().timeIntervalSince(start)
    XCTAssertEqual(rows.count, 5_000)

    start = Date()
    let folded = base.rows(folded: Set(base.items.filter { $0.depth == 0 }.map(\.id)))
    let foldSeconds = Date().timeIntervalSince(start)
    XCTAssertEqual(folded.count, 250)

    print("OUTLINE-PERF read+flatten \(String(format: "%.3f", readSeconds))s, fold \(String(format: "%.3f", foldSeconds))s")
    XCTAssertLessThan(readSeconds, 1.0)
    XCTAssertLessThan(foldSeconds, 0.25)
  }
}
