import TaktCore
import SwiftUI
import XCTest
@testable import Takt

final class KeyboardCommandsTests: XCTestCase {
  func testParsesChordsFromTheCatalogue() throws {
    let (key, modifiers) = try XCTUnwrap(KeyboardCommands.parse("cmd+shift+z"))
    XCTAssertEqual(key, KeyEquivalent("z"))
    XCTAssertEqual(modifiers, [.command, .shift])
    XCTAssertEqual(KeyboardCommands.parse("option+up")?.0, .upArrow)
  }

  func testSkipsSequencesAndBareLettersThatWouldSwallowTyping() {
    XCTAssertNil(KeyboardCommands.parse("dd"))
    XCTAssertNil(KeyboardCommands.parse("x"))
    XCTAssertNil(KeyboardCommands.parse("/"))
    XCTAssertNil(KeyboardCommands.parse("enter"))
    XCTAssertNotNil(KeyboardCommands.parse("space"))
  }

  func testTheBriefsShortcutsAreBound() {
    let bound = Dictionary(grouping: KeyboardCommands.bindings, by: \.id)
    for id: WorkspaceCommandID in [
      .goToday, .goBoard, .goOutline, .goMatrix, .taskNew, .goSearch, .windowUndo, .windowRedo,
      .taskMoveUp, .taskMoveDown, .taskIndent, .taskOutdent, .taskMoveToPreviousList, .taskMoveToNextList, .taskComplete,
    ] {
      XCTAssertNotNil(bound[id], "\(id) has no chord")
    }
    XCTAssertEqual(Set(KeyboardCommands.bindings.map { "\($0.key.character)\($0.modifiers.rawValue)" }).count,
      KeyboardCommands.bindings.count, "two commands share a chord")
  }
}
