import XCTest

@testable import TaktCore

/// What one render of the done rail cost before it grouped and indexed its
/// rows once per load: a regrouping, then every row scanning the list for the
/// cursor. Printed so the figures are in the test log.
final class CompletedWorkRailCostTests: XCTestCase {
  private struct Done {
    let id: String
    let completedAt: Date
  }

  func testGroupingAndIndexingOnceBeatsDoingItPerRender() {
    let now = Date.now
    let tasks = (0..<300).map { Done(id: "t\($0)", completedAt: now.addingTimeInterval(Double(-$0) * 3_600)) }
    let cursorID = "t299"
    let renders = 20

    let perRender = Self.seconds {
      for _ in 0..<renders {
        _ = CompletedWorkDigest.group(tasks, completedAt: \.completedAt, now: now)
        for task in tasks { _ = tasks.first { $0.id == cursorID }?.id == task.id }
      }
    }
    _ = CompletedWorkDigest.group(tasks, completedAt: \.completedAt, now: now)
    let index = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($1.id, $0) })
    let once = Self.seconds {
      for _ in 0..<renders {
        let cursor = index[cursorID].map { tasks[$0].id }
        for task in tasks { _ = cursor == task.id }
      }
    }
    print(String(
      format: "Done rail render, %d rows: per render %.0f µs, indexed %.1f µs",
      tasks.count, perRender / Double(renders) * 1_000_000, once / Double(renders) * 1_000_000))
    XCTAssertLessThan(once, perRender)
  }

  private static func seconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
