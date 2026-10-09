import XCTest

@testable import TaktCore

@MainActor
final class RelativeDateTextCacheTests: XCTestCase {
  func testAFreshReadingIsReusedAndAStaleOneIsRedone() {
    var calls = 0
    let cache = RelativeDateTextCache(lifetime: 60) { _, _ in
      calls += 1
      return "reading \(calls)"
    }
    let due = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let now = Date(timeIntervalSinceReferenceDate: 900_000)

    XCTAssertEqual(cache.text(for: due, now: now), "reading 1")
    XCTAssertEqual(cache.text(for: due, now: now.addingTimeInterval(59)), "reading 1")
    XCTAssertEqual(cache.text(for: due, now: now.addingTimeInterval(61)), "reading 2")
    XCTAssertEqual(calls, 2)
  }

  func testDifferentDatesAreKeptApart() {
    let cache = RelativeDateTextCache { date, _ in "\(date.timeIntervalSinceReferenceDate)" }
    let now = Date(timeIntervalSinceReferenceDate: 0)
    XCTAssertEqual(cache.text(for: Date(timeIntervalSinceReferenceDate: 1), now: now), "1.0")
    XCTAssertEqual(cache.text(for: Date(timeIntervalSinceReferenceDate: 2), now: now), "2.0")
  }

  func testAFullCacheStillAnswers() {
    let cache = RelativeDateTextCache(capacity: 4) { date, _ in "\(Int(date.timeIntervalSinceReferenceDate))" }
    let now = Date(timeIntervalSinceReferenceDate: 0)
    for second in 0..<20 {
      XCTAssertEqual(cache.text(for: Date(timeIntervalSinceReferenceDate: Double(second)), now: now), "\(second)")
    }
  }

  func testTheDefaultFormattingIsTheNamedRelativeStyle() {
    let due = Date.now.addingTimeInterval(86_400 * 3)
    XCTAssertEqual(
      RelativeDateTextCache().text(for: due), due.formatted(.relative(presentation: .named)))
  }

  /// The measurement behind the cache: a day of thirty rows redrawn on an
  /// arrow key, formatted every time against read from the cache. Printed so
  /// the figures are in the test log; asserted only by a margin far wider
  /// than any machine's noise.
  func testCachedReadingsAreFarCheaperThanFormatting() {
    let now = Date.now
    let dates = (0..<30).map { now.addingTimeInterval(Double($0) * 86_400 / 3) }
    let redraws = 50
    let cache = RelativeDateTextCache()

    let formatting = Self.seconds {
      for _ in 0..<redraws { for date in dates { _ = date.formatted(.relative(presentation: .named)) } }
    }
    let cached = Self.seconds {
      for _ in 0..<redraws { for date in dates { _ = cache.text(for: date, now: now) } }
    }
    let perCall = { (seconds: Double) in seconds / Double(redraws * dates.count) * 1_000_000 }
    print(String(
      format: "RelativeDateTextCache: formatting %.2f µs/row, cached %.2f µs/row",
      perCall(formatting), perCall(cached)))
    XCTAssertLessThan(cached, formatting / 3)
  }

  private static func seconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
