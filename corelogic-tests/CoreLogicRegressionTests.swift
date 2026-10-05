import XCTest

@testable import TaktCore

final class CoreLogicRegressionTests: XCTestCase {
  func testRemoteKeyBootstrapLoadsFromKeychainOnce() {
    var keychainReadCount = 0
    var state = RemoteKeyBootstrapState(remoteKey: "", hasAttemptedBootstrap: false)

    state = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: true,
      loadFromKeychain: {
        keychainReadCount += 1
        return "rk_test_123"
      })

    XCTAssertEqual(state.remoteKey, "rk_test_123")
    XCTAssertTrue(state.hasAttemptedBootstrap)
    XCTAssertEqual(keychainReadCount, 1)

    state = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: true,
      loadFromKeychain: {
        keychainReadCount += 1
        return "should_not_be_used"
      })

    XCTAssertEqual(state.remoteKey, "rk_test_123")
    XCTAssertTrue(state.hasAttemptedBootstrap)
    XCTAssertEqual(keychainReadCount, 1)
  }

  func testRemoteKeyBootstrapNoopWhenKeychainDisabled() {
    var keychainReadCount = 0
    let state = RemoteKeyBootstrapState(remoteKey: "", hasAttemptedBootstrap: false)

    let next = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: false,
      loadFromKeychain: {
        keychainReadCount += 1
        return "rk_test_123"
      })

    XCTAssertEqual(next, state)
    XCTAssertEqual(keychainReadCount, 0)
  }

  func testRemoteKeyBootstrapTreatsWhitespaceAsEmpty() {
    var keychainReadCount = 0
    let state = RemoteKeyBootstrapState(remoteKey: "   ", hasAttemptedBootstrap: false)

    let next = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: true,
      loadFromKeychain: {
        keychainReadCount += 1
        return "rk_test_123"
      })

    XCTAssertEqual(next.remoteKey, "rk_test_123")
    XCTAssertTrue(next.hasAttemptedBootstrap)
    XCTAssertEqual(keychainReadCount, 1)
  }

  func testOnboardingResetPreservesRemoteKeyAndClearsSessionState() {
    let initial = OnboardingResetState(
      remoteKey: "rk_keep_me",
      onboardingCompleted: true,
      username: "user@example.com",
      listId: "12345",
      availableListsCount: 4,
      tasksCount: 99,
      currentParentId: 42,
      currentSiblingIndex: 3
    )

    let reset = OnboardingResetPolicy.reset(initial)

    XCTAssertEqual(reset.remoteKey, "rk_keep_me")
    XCTAssertFalse(reset.onboardingCompleted)
    XCTAssertEqual(reset.username, "")
    XCTAssertEqual(reset.listId, "")
    XCTAssertEqual(reset.availableListsCount, 0)
    XCTAssertEqual(reset.tasksCount, 0)
    XCTAssertEqual(reset.currentParentId, 0)
    XCTAssertEqual(reset.currentSiblingIndex, 0)
  }

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

  func testAuthRetryPolicyRetriesOnlyOnceAfterUnauthorized() {
    var state = AuthRetryState(hasRetriedAfterUnauthorized: false)

    let firstAttempt = AuthRetryPolicy.decisionForUnauthorized(state: state)
    XCTAssertEqual(firstAttempt.decision, .retryAuthentication)
    XCTAssertTrue(firstAttempt.nextState.hasRetriedAfterUnauthorized)

    state = firstAttempt.nextState
    let secondAttempt = AuthRetryPolicy.decisionForUnauthorized(state: state)
    XCTAssertEqual(secondAttempt.decision, .giveUp)
    XCTAssertEqual(secondAttempt.nextState, state)
  }

  func testAutoRefreshThrottlePolicyBlocksSetupAndThrottlesBurstRefreshes() {
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertFalse(
      AutoRefreshThrottlePolicy.shouldRefresh(
        needsInitialSetup: true,
        now: now,
        lastRefreshAt: now.addingTimeInterval(-100)
      ))

    XCTAssertFalse(
      AutoRefreshThrottlePolicy.shouldRefresh(
        needsInitialSetup: false,
        now: now,
        lastRefreshAt: now.addingTimeInterval(-3),
        minimumInterval: 8
      ))

    XCTAssertTrue(
      AutoRefreshThrottlePolicy.shouldRefresh(
        needsInitialSetup: false,
        now: now,
        lastRefreshAt: now.addingTimeInterval(-12),
        minimumInterval: 8
      ))
  }
}
