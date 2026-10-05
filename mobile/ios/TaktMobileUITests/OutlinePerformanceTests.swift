import XCTest

/// Scrolling a 5,000-task outline. Seeds through the DEBUG `-seed5000`
/// launch argument, opens the list, and measures flicks through it with the
/// scrolling signpost metric (hitch time ratio, frame rate).
final class OutlinePerformanceTests: XCTestCase {
  func testScrollingFiveThousandTasks() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-seed5000"]
    app.launch()

    let seeded = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Seeded'")).firstMatch
    XCTAssertTrue(seeded.waitForExistence(timeout: 240), "seeding did not finish")

    app.tabBars.buttons["Lists"].tap()
    let row = app.buttons["lists.row.Seed 5,000"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    let opened = Date()
    row.tap()
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(app.staticTexts["Project 1"].waitForExistence(timeout: 10))
    print("OUTLINE-PERF first rows after \(String(format: "%.2f", Date().timeIntervalSince(opened)))s")

    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
      for _ in 0..<6 { list.swipeUp(velocity: .fast) }
      for _ in 0..<6 { list.swipeDown(velocity: .fast) }
    }
  }
}
