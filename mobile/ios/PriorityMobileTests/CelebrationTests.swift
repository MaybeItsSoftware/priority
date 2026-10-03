import PriorityCore
import PriorityWorkspace
import XCTest
@testable import Priority

@MainActor
final class CelebrationTests: XCTestCase {
  func testEachStyleRunsTheMacPresetsScriptWithinTheInlineBudget() {
    XCTAssertTrue(CelebrationStyle.none.script(reduceMotion: false).steps.isEmpty)
    for style in [CelebrationStyle.strike, .spark, .fold] {
      let script = style.script(reduceMotion: false)
      XCTAssertEqual(script.steps.first?.phase, .anticipating, "\(style)")
      XCTAssertEqual(script.steps.last?.phase, .celebrating, "\(style)")
      XCTAssertLessThanOrEqual(script.total, CompletionMilestonePolicy.inlineBudget + 0.0001, "\(style)")
    }
    XCTAssertEqual(CelebrationStyle.strike.script(reduceMotion: false).steps.count, 3)
    XCTAssertEqual(CelebrationStyle.fold.treatment, .fold)
    XCTAssertTrue(CelebrationStyle.strike.treatment.drawsStrikethrough)
  }

  func testReduceMotionCollapsesTheDurationsRatherThanDroppingTheEffect() {
    for style in [CelebrationStyle.strike, .spark, .fold] {
      let full = style.script(reduceMotion: false)
      let reduced = style.script(reduceMotion: true)
      XCTAssertEqual(reduced.steps.map(\.phase), full.steps.map(\.phase), "\(style)")
      XCTAssertGreaterThan(reduced.total, 0)
      XCTAssertLessThan(reduced.total, full.total)
    }
  }

  func testCompletingPlaysTheScriptOnTheRowThenWrites() async throws {
    let model = try WorkspaceModel.temporary()
    model.celebration.reduceMotion = { false }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "CelebrationTests-\(UUID().uuidString)"))
    defaults.set(CelebrationStyle.fold.rawValue, forKey: CelebrationStyle.storageKey)
    let task = try XCTUnwrap(model.createTask("Alpha", listID: try XCTUnwrap(model.inbox).id))

    model.completeCelebrating(task.id, defaults: defaults)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(model.celebration.taskID, task.id)
    XCTAssertNotEqual(model.celebration.phase(for: task.id), .idle)
    XCTAssertEqual(model.celebration.phase(for: "someone else"), .idle)
    XCTAssertEqual(model.task(task.id)?.status, .open, "the write waits for the effect")

    for _ in 0..<50 where model.task(task.id)?.status == .open {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.task(task.id)?.status, .completed)
    XCTAssertFalse(model.celebration.isPlaying)
  }

  func testNoneAndReopeningWriteAtOnce() throws {
    let model = try WorkspaceModel.temporary()
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "CelebrationTests-\(UUID().uuidString)"))
    defaults.set(CelebrationStyle.none.rawValue, forKey: CelebrationStyle.storageKey)
    let task = try XCTUnwrap(model.createTask("Alpha", listID: try XCTUnwrap(model.inbox).id))
    model.completeCelebrating(task.id, defaults: defaults)
    XCTAssertEqual(model.task(task.id)?.status, .completed)
    defaults.set(CelebrationStyle.strike.rawValue, forKey: CelebrationStyle.storageKey)
    model.completeCelebrating(task.id, defaults: defaults)
    XCTAssertEqual(model.task(task.id)?.status, .open)
  }
}
