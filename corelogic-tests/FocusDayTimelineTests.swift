import Foundation
import TaktCore
import XCTest

final class FocusDayTimelineTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private let day = Date(timeIntervalSince1970: 1_700_000_000)

  private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  private func block(_ id: String, endedAt: Date, minutes: Int, isLive: Bool = false) -> FocusDayTimeline.Block {
    FocusDayTimeline.Block(id: id, title: id, seconds: minutes * 60, endedAt: endedAt, isLive: isLive)
  }

  func testItPlacesABlockWhereItRanRatherThanWhereItWasLogged() {
    let layout = FocusDayTimeline.layout(
      blocks: [block("a", endedAt: at(10, 30), minutes: 30)], day: day, calendar: calendar)

    let placement = try? XCTUnwrap(layout.placements.first)
    XCTAssertEqual(placement?.minutes, 30)
    XCTAssertEqual(placement?.startedAt, at(10, 0))
    XCTAssertEqual(layout.start, at(10, 0))
  }

  func testTheWindowCoversEveryBlockOnWholeHours() {
    let layout = FocusDayTimeline.layout(
      blocks: [
        block("morning", endedAt: at(9, 20), minutes: 35),
        block("evening", endedAt: at(17, 10), minutes: 40),
      ], day: day, calendar: calendar)

    XCTAssertEqual(layout.start, at(8, 0))
    XCTAssertEqual(layout.end, at(18, 0))
    XCTAssertEqual(layout.hourCount, 10)
    XCTAssertEqual(layout.hours.count, 11)
    XCTAssertEqual(layout.placements.first?.offsetMinutes, 45)
  }

  func testAShortDayStillGetsAReadableRuler() {
    let layout = FocusDayTimeline.layout(
      blocks: [block("a", endedAt: at(14, 20), minutes: 20)], day: day, calendar: calendar)

    XCTAssertEqual(layout.hourCount, FocusDayTimeline.minimumHours)
    XCTAssertEqual(layout.start, at(14, 0))
  }

  func testAMinimumWindowNeverOverhangsTheEndOfTheDay() {
    let layout = FocusDayTimeline.layout(
      blocks: [block("late", endedAt: at(23, 50), minutes: 20)], day: day, calendar: calendar)

    XCTAssertEqual(layout.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)))
    XCTAssertEqual(layout.hourCount, FocusDayTimeline.minimumHours)
  }

  func testAnEmptyDayKeepsItsShape() {
    let layout = FocusDayTimeline.layout(blocks: [], day: day, calendar: calendar)

    XCTAssertTrue(layout.placements.isEmpty)
    XCTAssertEqual(layout.laneCount, 1)
    XCTAssertEqual(layout.start, at(9, 0))
    XCTAssertEqual(layout.end, at(18, 0))
  }

  func testOverlappingBlocksTakeSeparateLanes() {
    let layout = FocusDayTimeline.layout(
      blocks: [
        block("a", endedAt: at(11, 0), minutes: 60),
        block("b", endedAt: at(11, 30), minutes: 60),
        block("c", endedAt: at(13, 0), minutes: 30),
      ], day: day, calendar: calendar)

    XCTAssertEqual(layout.laneCount, 2)
    XCTAssertEqual(layout.placements.map(\.lane), [0, 1, 0])
  }

  func testWorkRunningThroughMidnightIsClampedToTheDayItLandsOn() {
    let layout = FocusDayTimeline.layout(
      blocks: [block("overnight", endedAt: at(0, 30), minutes: 90)], day: day, calendar: calendar)

    XCTAssertEqual(layout.placements.first?.minutes, 30)
    XCTAssertEqual(layout.placements.first?.startedAt, calendar.startOfDay(for: day))
    XCTAssertEqual(layout.start, calendar.startOfDay(for: day))
  }

  func testBlocksWithNoTimeInThemAreNotDrawn() {
    let layout = FocusDayTimeline.layout(
      blocks: [block("empty", endedAt: at(12, 0), minutes: 0)], day: day, calendar: calendar)

    XCTAssertTrue(layout.placements.isEmpty)
  }

  func testTheLiveBlockIsPlacedLikeAnyOther() {
    let layout = FocusDayTimeline.layout(
      blocks: [
        block("logged", endedAt: at(10, 0), minutes: 25),
        block("running", endedAt: at(11, 15), minutes: 15, isLive: true),
      ], day: day, calendar: calendar)

    XCTAssertEqual(layout.placements.last?.block.isLive, true)
    XCTAssertEqual(layout.placements.last?.offsetMinutes, 120)
  }
}
