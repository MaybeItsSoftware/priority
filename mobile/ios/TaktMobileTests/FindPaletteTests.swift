import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

/// Find: the core's commands, every one of them run here, and the places it opens.
@MainActor
final class FindPaletteTests: XCTestCase {
  func testTheIPhoneRunsEveryCommandTheCoreOffersThePhones() {
    XCTAssertEqual(Set(PhonePalette.commands.map(\.id)), PhoneCommandRunner.handled)
  }

  func testPlacesAreEverythingThenEveryLiveListAndAQueryRanksThem() throws {
    let model = try WorkspaceModel.temporary()
    _ = model.createList(named: "Work projects")
    model.reloadStructureNow()
    let places = FindPlace.all(in: model.structure)
    XCTAssertEqual(places.first?.scope, .everything)
    XCTAssertTrue(places.contains { $0.name == "Inbox" })
    XCTAssertEqual(FindPalette.places("wp", in: places).first?.name, "Work projects")
    XCTAssertEqual(FindPalette.places("", in: places), places)
  }

  func testACommandFromFindOpensWhereItSays() throws {
    let model = try WorkspaceModel.temporary()
    PhoneCommandRunner.run("goFocus", model: model, isPad: false)
    XCTAssertEqual(model.navigation.tab, .focus)
    PhoneCommandRunner.run("phoneSettings", model: model, isPad: false)
    XCTAssertTrue(model.navigation.isSettingsPresented)
    PhoneCommandRunner.run("goEverything", model: model, isPad: false)
    XCTAssertEqual(model.navigation.listPath, [.everything])
  }

  func testAnEditOffersUndoAndTheUndoOffersRedo() throws {
    let model = try WorkspaceModel.temporary()
    let inbox = try XCTUnwrap(model.inbox)
    let task = try XCTUnwrap(model.createTask("Alpha", listID: inbox.id))
    model.toggleComplete(task.id)
    XCTAssertEqual(model.toastAction, .undo)
    model.runToastAction()
    XCTAssertEqual(model.task(task.id)?.status, .open)
    XCTAssertEqual(model.toastAction, .redo)
  }
}
