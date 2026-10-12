import XCTest

@testable import TaktCore

final class CoreLogicRegressionTests: XCTestCase {
  func testAppTerminationPolicyRequiresExplicitQuitWhileAnAgent() {
    XCTAssertEqual(
      AppTerminationPolicy.decision(
        explicitQuitRequested: false, isRegularActivationPolicy: false),
      .cancel
    )
    XCTAssertEqual(
      AppTerminationPolicy.decision(
        explicitQuitRequested: true, isRegularActivationPolicy: false),
      .terminateNow
    )
  }

  func testAppTerminationPolicyDismissesToTheMenuBarInsteadOfQuitting() {
    // Cmd-Q from the app menu never sets the explicit flag. It has to do
    // something visible — otherwise the shortcut looks broken — but it must not
    // take the status item away with it.
    XCTAssertEqual(
      AppTerminationPolicy.decision(
        explicitQuitRequested: false, isRegularActivationPolicy: true),
      .dismissToMenuBar
    )
    XCTAssertEqual(
      AppTerminationPolicy.decision(
        explicitQuitRequested: true, isRegularActivationPolicy: true),
      .terminateNow
    )
  }

  func testAutoRefreshThrottlePolicyThrottlesBurstRefreshes() {
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertFalse(
      AutoRefreshThrottlePolicy.shouldRefresh(
        now: now,
        lastRefreshAt: now.addingTimeInterval(-3),
        minimumInterval: 8
      ))

    XCTAssertTrue(
      AutoRefreshThrottlePolicy.shouldRefresh(
        now: now,
        lastRefreshAt: now.addingTimeInterval(-12),
        minimumInterval: 8
      ))
  }
}
