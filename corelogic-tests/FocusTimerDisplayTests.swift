import Foundation
import PriorityCore
import XCTest

final class FocusTimerDisplayTests: XCTestCase {
  private func text(elapsed: TimeInterval, planned: TimeInterval) -> String {
    FocusTimerDisplay.reading(elapsed: elapsed, planned: planned).text
  }

  func testItCountsDownTowardsTheEstimate() {
    XCTAssertEqual(text(elapsed: 0, planned: 25 * 60), "25:00")
    XCTAssertEqual(text(elapsed: 29, planned: 25 * 60), "24:31")
    XCTAssertEqual(text(elapsed: 24 * 60, planned: 25 * 60), "1:00")
  }

  func testItReachesZeroExactlyRatherThanSkippingIt() {
    let reading = FocusTimerDisplay.reading(elapsed: 25 * 60, planned: 25 * 60)

    XCTAssertEqual(reading.text, "0:00")
    XCTAssertFalse(reading.isOverrun)
  }

  func testPastTheEstimateItCountsUpWithAPlusInsteadOfStalling() {
    let reading = FocusTimerDisplay.reading(elapsed: 25 * 60 + 134, planned: 25 * 60)

    XCTAssertEqual(reading.text, "+2:14")
    XCTAssertTrue(reading.isOverrun)
  }

  func testLongSittingsGrowAnHoursField() {
    XCTAssertEqual(text(elapsed: 0, planned: 90 * 60), "1:30:00")
    XCTAssertEqual(text(elapsed: 2 * 3_600 + 61, planned: 0), "+2:01:01")
  }

  func testTimeBeforeTheStartIsTreatedAsNoneElapsed() {
    XCTAssertEqual(text(elapsed: -500, planned: 60), "1:00")
  }
}
