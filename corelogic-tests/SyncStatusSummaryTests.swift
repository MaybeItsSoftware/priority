import XCTest

@testable import TaktCore

final class SyncStatusSummaryTests: XCTestCase {

  private func summary(
    isLoading: Bool = false,
    isNetworkReachable: Bool = true,
    canSyncRemotely: Bool = true,
    hasPendingOfflineWork: Bool = false,
    errorMessage: String? = nil,
    lastSuccessfulSyncAt: Date? = Date(timeIntervalSince1970: 1_000_000),
    now: Date = Date(timeIntervalSince1970: 1_000_000)
  ) -> SyncStatusSummary {
    SyncStatusFormatter.summary(
      isLoading: isLoading,
      isNetworkReachable: isNetworkReachable,
      canSyncRemotely: canSyncRemotely,
      hasPendingOfflineWork: hasPendingOfflineWork,
      errorMessage: errorMessage,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt,
      now: now
    )
  }

  func testAnErrorOutranksEverythingElse() {
    let result = summary(errorMessage: "Login failed.")
    XCTAssertEqual(result.text, "Login failed.")
    XCTAssertEqual(result.severity, .problem)
  }

  func testBeingOfflineExplainsItselfBeforeAStaleTimestampWould() {
    XCTAssertEqual(summary(isNetworkReachable: false).text, "Offline")
    XCTAssertEqual(
      summary(isNetworkReachable: false, hasPendingOfflineWork: true).text,
      "Offline · changes queued")
    XCTAssertEqual(summary(isNetworkReachable: false).severity, .warning)
  }

  func testTheOfflineWorkspaceIsNotAFault() {
    // Someone who never connected Checkvist is using the app as intended and
    // should not be shown a warning colour for it.
    let result = summary(canSyncRemotely: false)
    XCTAssertEqual(result.text, "Offline workspace")
    XCTAssertEqual(result.severity, .ok)
  }

  func testNeverSyncedIsDistinctFromSyncedLongAgo() {
    XCTAssertEqual(summary(lastSuccessfulSyncAt: nil).text, "Not synced yet")
    XCTAssertEqual(summary(lastSuccessfulSyncAt: nil).severity, .warning)
  }

  func testRelativeDescriptionIsCoarse() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ seconds: TimeInterval) -> String {
      SyncStatusFormatter.relativeDescription(
        from: base, to: base.addingTimeInterval(seconds))
    }
    XCTAssertEqual(ago(0), "just now")
    XCTAssertEqual(ago(30), "just now")
    XCTAssertEqual(ago(120), "2m ago")
    XCTAssertEqual(ago(3600 * 3), "3h ago")
    XCTAssertEqual(ago(86400 * 2), "2d ago")
  }

  func testAClockSkewedIntoTheFutureDoesNotProduceNegativeText() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(
      SyncStatusFormatter.relativeDescription(
        from: base, to: base.addingTimeInterval(-500)),
      "just now")
  }
}
