import XCTest

/// The outline's core loop, end to end, on an empty workspace: add a task,
/// add a subtask, fold, complete, undo.
final class SmokeTests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["-uiTesting"]
    app.launch()
  }

  func testAddSubtaskFoldCompleteUndo() {
    // Lists → Inbox.
    app.tabBars.buttons["Lists"].tap()
    let inbox = app.buttons["lists.row.Inbox"].firstMatch
    XCTAssertTrue(inbox.waitForExistence(timeout: 10))
    inbox.tap()

    // Add a task with the toolbar's add button; the composer stays open.
    app.buttons["toolbar.add"].tap()
    let composer = app.textFields["outline.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.typeText("Alpha\n")
    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5))
    app.buttons["Cancel new task"].tap()

    // Add a subtask from the long-press menu.
    app.staticTexts["Alpha"].press(forDuration: 1.2)
    let newSubtask = app.buttons["New subtask"]
    XCTAssertTrue(newSubtask.waitForExistence(timeout: 5))
    newSubtask.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.typeText("Beta\n")
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5))
    app.buttons["Cancel new task"].tap()

    // Fold Alpha: Beta goes, Alpha stays.
    let fold = app.buttons["outline.fold.Alpha"]
    XCTAssertTrue(fold.waitForExistence(timeout: 5))
    fold.tap()
    XCTAssertTrue(waitForDisappearance(app.staticTexts["Beta"]))
    XCTAssertTrue(app.staticTexts["Alpha"].exists)

    // Complete Alpha.
    let check = app.buttons["outline.check.Alpha"]
    check.tap()
    XCTAssertTrue(waitForLabel(check, "Reopen Alpha"))

    // Undo the completion.
    app.buttons["toolbar.undo"].tap()
    XCTAssertTrue(waitForLabel(check, "Complete Alpha"))
  }

  private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
  }

  private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "label == %@", label)
    return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
  }
}
