import XCTest

@testable import TaktAppLogic

/// Placeholder ids have to be unique for as long as any offline create is
/// still queued — which outlives the process. A repeat silently retargets a
/// different task's replace/remove/rollback, so the cursor's persistence is
/// load-bearing rather than a nicety.
@MainActor
final class OptimisticTaskIDTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaultsSuite()
    OptimisticTaskID.resetForTesting()
  }

  override func tearDown() async throws {
    OptimisticTaskID.resetForTesting()
    try await super.tearDown()
  }

  func testIdsAreNegativeAndStrictlyDecreasing() {
    let ids = (0..<3).map { _ in OptimisticTaskID.make(defaults: defaults) }

    XCTAssertEqual(ids, [-1, -2, -3])
    XCTAssertEqual(Set(ids).count, 3)
  }

  /// The regression: the cursor was read from `UserDefaults.standard` no matter
  /// which store was passed, so a relaunch could hand out an id that a queued
  /// offline create was still using.
  func testTheCursorResumesFromTheStoreItWasWrittenTo() {
    _ = OptimisticTaskID.make(defaults: defaults)
    _ = OptimisticTaskID.make(defaults: defaults)

    // Stand in for a relaunch: same store, fresh in-memory state.
    OptimisticTaskID.resetForTesting()

    XCTAssertEqual(
      OptimisticTaskID.make(defaults: defaults), -3,
      "ids must not restart and collide with work still on the offline queue")
  }

  func testAFreshStoreStartsAtMinusOne() {
    XCTAssertEqual(OptimisticTaskID.make(defaults: defaults), -1)
  }
}
