import XCTest

@testable import TaktCore

final class InspectorCursorTests: XCTestCase {
  /// The inspector's rows in the order it draws them, cut down.
  private let rows: [InspectorStopInfo] = [
    .init("title", kind: .field),
    .init("focus.start", kind: .control),
    .init("due", kind: .control),
    .init("estimate", kind: .field),
    .init("single-sitting", kind: .control),
    .init("notes", kind: .multilineField),
    .init("priority", kind: .adjustable),
    .init("repeat", kind: .field),
    .init("commitment.c1.edit", kind: .control),
    .init("commitment.c1.stop", kind: .control),
    .init("links", kind: .multilineField),
  ]

  func testStepsPastTheNotesWithoutGivingThemTheKeyboard() {
    var cursor = InspectorCursor(stops: rows, current: "single-sitting")
    cursor.step(by: 1)
    XCTAssertEqual(cursor.current, "notes")
    XCTAssertEqual(cursor.mode, .normal)
    XCTAssertNil(cursor.keyboardStop, "the notes are highlighted, not focused")
    cursor.step(by: 1)
    XCTAssertEqual(cursor.current, "priority")
    XCTAssertEqual(cursor.keyboardStop, "priority", "a control holds the keyboard so Space works on it")
    cursor.step(by: -2)
    XCTAssertEqual(cursor.current, "single-sitting")
  }

  func testReachesTheCommitmentActionsAndTheLinks() {
    var cursor = InspectorCursor(stops: rows, current: "repeat")
    cursor.step(by: 1)
    XCTAssertEqual(cursor.current, "commitment.c1.edit")
    cursor.step(by: 1)
    XCTAssertEqual(cursor.current, "commitment.c1.stop")
    cursor.step(by: 1)
    XCTAssertEqual(cursor.current, "links")
  }

  func testTheEndsStopAndAFreshCursorStartsAtTheNearEnd() {
    var cursor = InspectorCursor(stops: rows)
    cursor.step(by: 1)
    XCTAssertEqual(cursor.current, "title")
    cursor.step(by: -1)
    XCTAssertEqual(cursor.current, "title")
    var fromFoot = InspectorCursor(stops: rows)
    fromFoot.step(by: -1)
    XCTAssertEqual(fromFoot.current, "links")
    fromFoot.step(by: 1)
    XCTAssertEqual(fromFoot.current, "links")
  }

  func testGgAndShiftGGoToTheEnds() {
    var cursor = InspectorCursor(stops: rows, current: "notes")
    cursor.moveToLast()
    XCTAssertEqual(cursor.current, "links")
    cursor.moveToFirst()
    XCTAssertEqual(cursor.current, "title")
  }

  func testReturnOpensATextRowAndPressesAControl() {
    var cursor = InspectorCursor(stops: rows, current: "notes")
    XCTAssertNil(cursor.activate())
    XCTAssertEqual(cursor.mode, .editing)
    XCTAssertEqual(cursor.keyboardStop, "notes")

    var onSwitch = InspectorCursor(stops: rows, current: "single-sitting")
    XCTAssertEqual(onSwitch.activate(), .press("single-sitting"))
    XCTAssertEqual(onSwitch.mode, .normal)
  }

  func testEscapeInAOneLineFieldGivesUpAndStaysOnTheRow() {
    var cursor = InspectorCursor(stops: rows, current: "estimate")
    cursor.activate()
    XCTAssertEqual(InspectorEditingKey.meaning(of: "escape", multiline: false), .cancel)
    XCTAssertEqual(cursor.finishEditing(commit: false), .revert("estimate"))
    XCTAssertEqual(cursor.current, "estimate")
    XCTAssertEqual(cursor.mode, .normal)
    XCTAssertNil(cursor.keyboardStop)
  }

  func testReturnInAOneLineFieldCommitsAndLetsTheFieldHaveIt() {
    var cursor = InspectorCursor(stops: rows, current: "title")
    cursor.activate()
    XCTAssertEqual(InspectorEditingKey.meaning(of: "enter", multiline: false), .commit(passKey: true))
    XCTAssertNil(cursor.finishEditing(commit: true))
    XCTAssertEqual(cursor.current, "title")
    XCTAssertEqual(cursor.mode, .normal)
  }

  func testTheNotesKeepTheirArrowsAndEscapeCommits() {
    XCTAssertNil(InspectorEditingKey.meaning(of: "down", multiline: true))
    XCTAssertNil(InspectorEditingKey.meaning(of: "up", multiline: true))
    XCTAssertNil(InspectorEditingKey.meaning(of: "enter", multiline: true))
    XCTAssertEqual(InspectorEditingKey.meaning(of: "escape", multiline: true), .commit(passKey: false))
    XCTAssertEqual(InspectorEditingKey.meaning(of: "cmd+enter", multiline: true), .commit(passKey: false))
    XCTAssertEqual(InspectorEditingKey.meaning(of: "down", multiline: false), .step(1))
    XCTAssertNil(InspectorEditingKey.meaning(of: "j", multiline: false))
  }

  func testTabCommitsAndOpensTheNextTextRow() {
    var cursor = InspectorCursor(stops: rows, current: "title")
    cursor.activate()
    cursor.tab(forward: true)
    XCTAssertEqual(cursor.current, "focus.start")
    XCTAssertEqual(cursor.mode, .normal, "a control is stood on, not edited")
    cursor.edit("repeat")
    cursor.tab(forward: false)
    XCTAssertEqual(cursor.current, "priority")
    cursor.edit("single-sitting")
    XCTAssertEqual(cursor.mode, .normal)
    cursor.step(by: -1)
    cursor.edit("estimate")
    cursor.tab(forward: true)
    XCTAssertEqual(cursor.current, "single-sitting")
    cursor.edit("notes")
    XCTAssertEqual(cursor.mode, .editing)
    cursor.tab(forward: false)
    XCTAssertEqual(cursor.current, "single-sitting")
  }

  func testAClickInAFieldEditsItAndLosingTheKeyboardEndsTheEdit() {
    var cursor = InspectorCursor(stops: rows)
    cursor.keyboardMoved(to: "notes")
    XCTAssertEqual(cursor.current, "notes")
    XCTAssertEqual(cursor.mode, .editing)
    cursor.keyboardMoved(to: nil)
    XCTAssertEqual(cursor.current, "notes")
    XCTAssertEqual(cursor.mode, .normal)
    cursor.keyboardMoved(to: "priority")
    XCTAssertEqual(cursor.mode, .normal)
    XCTAssertEqual(cursor.keyboardStop, "priority")
  }

  func testClearPressesTheRowsOwnCrossOrClearsTheValue() {
    let dated = [
      InspectorStopInfo("due.date", kind: .control), .init("due.clear", kind: .control),
      .init("blocker.b1", kind: .control), .init("blocker.b1.remove", kind: .control),
      .init("estimate", kind: .field),
    ]
    XCTAssertEqual(InspectorCursor(stops: dated, current: "due.date").clear(), .press("due.clear"))
    XCTAssertEqual(InspectorCursor(stops: dated, current: "blocker.b1").clear(), .press("blocker.b1.remove"))
    XCTAssertEqual(InspectorCursor(stops: dated, current: "estimate").clear(), .clearValue("estimate"))
  }

  func testACursorWhoseRowWentAwayLandsOnItsFamily() {
    var cursor = InspectorCursor(
      stops: [.init("title", kind: .field), .init("due.date", kind: .control), .init("due.clear", kind: .control),
              .init("start", kind: .control)],
      current: "due.clear")
    cursor.updateStops([.init("title", kind: .field), .init("due", kind: .control), .init("start", kind: .control)])
    XCTAssertEqual(cursor.current, "due")
    cursor.updateStops([.init("title", kind: .field)])
    XCTAssertEqual(cursor.current, "title")
    cursor.updateStops([])
    XCTAssertNil(cursor.current)
  }

  func testLeftStepsAPickerAndOtherwiseLeaves() {
    XCTAssertEqual(InspectorCursor(stops: rows, current: "priority").leave(byArrow: true), .adjust("priority", by: -1))
    XCTAssertEqual(InspectorCursor(stops: rows, current: "priority").leave(byArrow: false), .leave)
    XCTAssertEqual(InspectorCursor(stops: rows, current: "notes").leave(byArrow: true), .leave)
  }
}
