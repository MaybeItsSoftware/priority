import PriorityWorkspace
import XCTest
@testable import Priority

@MainActor
final class SearchModelTests: XCTestCase {
  func testFindsByTitlePrefixAndHidesCompletedUnlessAsked() async throws {
    let model = try WorkspaceModel.temporary()
    let inbox = try XCTUnwrap(model.inbox)
    let open = try XCTUnwrap(model.createTask("Write the report", listID: inbox.id))
    let done = try XCTUnwrap(model.createTask("Write a letter", listID: inbox.id))
    _ = model.createTask("Unrelated", listID: inbox.id)
    model.toggleComplete(done.id)

    let search = SearchModel()
    search.includesCompleted = false
    search.query = "wri"
    await search.search(store: model.store, workspaceID: model.workspace.id)
    XCTAssertEqual(search.results.map(\.task.id), [open.id])
    XCTAssertEqual(search.searchedQuery, "wri")

    search.includesCompleted = true
    await search.search(store: model.store, workspaceID: model.workspace.id)
    XCTAssertEqual(Set(search.results.map(\.task.id)), [open.id, done.id])
    XCTAssertEqual(search.results.first?.list.id, inbox.id)
  }

  func testBlankQueryClearsResults() async throws {
    let model = try WorkspaceModel.temporary()
    let search = SearchModel()
    search.query = "   "
    await search.search(store: model.store, workspaceID: model.workspace.id)
    XCTAssertTrue(search.results.isEmpty)
    XCTAssertEqual(search.searchedQuery, "")
  }

  func testKeyMovesWithTheRevision() {
    let search = SearchModel()
    search.query = "a"
    XCTAssertNotEqual(search.key(revision: 1), search.key(revision: 2))
  }
}

@MainActor
final class UndoHistoryTests: XCTestCase {
  func testListsLabelledStepsNewestFirstAndMovesThemToRedoOnUndo() throws {
    let model = try WorkspaceModel.temporary()
    let url = try XCTUnwrap(model.databaseURL)
    let inbox = try XCTUnwrap(model.inbox)
    let task = try XCTUnwrap(model.createTask("Alpha", listID: inbox.id))
    model.toggleComplete(task.id)

    var history = try UndoHistoryReader.read(databaseURL: url)
    XCTAssertEqual(history.undo.map(\.label), ["Change Status", "New Task"])
    XCTAssertTrue(history.redo.isEmpty)
    XCTAssertEqual(history.undoCount(through: history.undo[1]), 2)

    model.undo()
    history = try UndoHistoryReader.read(databaseURL: url)
    XCTAssertEqual(history.undo.map(\.label), ["New Task"])
    XCTAssertEqual(history.redo.map(\.label), ["Change Status"])
    XCTAssertEqual(history.redoCount(through: history.redo[0]), 1)
  }

  func testUndoingSeveralStepsFromTheSheetRestoresTheEarlierState() throws {
    let model = try WorkspaceModel.temporary()
    let url = try XCTUnwrap(model.databaseURL)
    let inbox = try XCTUnwrap(model.inbox)
    let task = try XCTUnwrap(model.createTask("Alpha", listID: inbox.id))
    model.rename(task.id, to: "Beta")
    model.toggleComplete(task.id)

    let history = try UndoHistoryReader.read(databaseURL: url)
    let rename = try XCTUnwrap(history.undo.first { $0.label != "Change Status" && $0.label != "New Task" })
    for _ in 0..<(history.undoCount(through: rename) ?? 0) { model.undo() }
    XCTAssertEqual(model.task(task.id)?.title, "Alpha")
    XCTAssertEqual(model.task(task.id)?.status, .open)
  }
}

final class SettingsTests: XCTestCase {
  func testCelebrationStyleFallsBackToStrike() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsTests-\(UUID().uuidString)"))
    XCTAssertEqual(CelebrationStyle.stored(in: defaults), .strike)
    defaults.set("nonsense", forKey: CelebrationStyle.storageKey)
    XCTAssertEqual(CelebrationStyle.stored(in: defaults), .strike)
    defaults.set("spark", forKey: CelebrationStyle.storageKey)
    XCTAssertEqual(CelebrationStyle.stored(in: defaults), .spark)
  }

  func testHapticsDefaultOn() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsTests-\(UUID().uuidString)"))
    XCTAssertTrue(CompletionHaptics.isEnabled(in: defaults))
    defaults.set(false, forKey: CompletionHaptics.storageKey)
    XCTAssertFalse(CompletionHaptics.isEnabled(in: defaults))
  }
}
