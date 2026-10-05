import XCTest

@testable import TaktCore

final class DiagnosticsReportTests: XCTestCase {

  private func makeSnapshot(
    health: [DiagnosticsSnapshot.HealthItem] = [],
    recentProblems: [DiagnosticsSnapshot.LogItem] = [],
    paths: [(label: String, path: String)] = []
  ) -> DiagnosticsSnapshot {
    DiagnosticsSnapshot(
      appVersion: "2.2.0",
      buildNumber: "4",
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      connectionDescription: "connected (4 lists)",
      listName: "Work",
      listID: "12",
      isNetworkReachable: true,
      syncStatus: "Synced 2m ago",
      lastSuccessfulSyncAt: Date(timeIntervalSince1970: 1_699_999_880),
      openTaskCount: 37,
      pendingOfflineWorkCount: 0,
      health: health,
      recentProblems: recentProblems,
      paths: paths
    )
  }

  func testReportNamesTheListAndItsID() {
    let text = DiagnosticsReport.text(from: makeSnapshot())
    XCTAssertTrue(text.contains("Work (id 12)"))
    XCTAssertTrue(text.contains("Open tasks:     37"))
  }

  func testEmptyProblemListSaysSoRatherThanLookingTruncated() {
    let text = DiagnosticsReport.text(from: makeSnapshot())
    XCTAssertTrue(text.contains("(none recorded this session)"))
  }

  func testUnhealthyItemsAreMarked() {
    let text = DiagnosticsReport.text(
      from: makeSnapshot(health: [
        .init(title: "Checkvist", isHealthy: true, detail: "signed in"),
        .init(title: "AFFiNE helper", isHealthy: false, detail: "not found on PATH"),
      ]))
    XCTAssertTrue(text.contains("[ok] Checkvist"))
    XCTAssertTrue(text.contains("[!!] AFFiNE helper"))
    XCTAssertTrue(text.contains("not found on PATH"))
  }

  // MARK: - Redaction
  //
  // A report is something the user is invited to paste in public, so these are
  // the tests that matter most in this file.

  func testLabelledCredentialsAreRedactedButTheLabelSurvives() {
    let redacted = DiagnosticsReport.redacting(#"{"api_key": "abc123def456ghi789jkl"}"#)
    XCTAssertFalse(redacted.contains("abc123def456ghi789jkl"))
    XCTAssertTrue(redacted.lowercased().contains("api_key"))
    XCTAssertTrue(redacted.contains("<redacted>"))
  }

  func testRemoteKeyShapedRunsAreRedactedEvenWhenUnlabelled() {
    // What a Checkvist remote key actually looks like in the wild: no
    // surrounding key name, just a long opaque run.
    let key = "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA"
    let redacted = DiagnosticsReport.redacting("Fetch failed for \(key) at 14:02")
    XCTAssertFalse(redacted.contains(key))
    XCTAssertTrue(redacted.contains("<redacted>"))
  }

  func testOrdinaryProseIsLeftAlone() {
    let text = "Failed to fetch tasks: The Internet connection appears to be offline."
    XCTAssertEqual(DiagnosticsReport.redacting(text), text)
  }

  func testASecretLandingInTheProblemLogDoesNotReachTheReport() {
    let secret = "tokenABCDEFGH1234567890abcdef"
    let text = DiagnosticsReport.text(
      from: makeSnapshot(recentProblems: [
        .init(
          date: Date(timeIntervalSince1970: 1_700_000_000),
          category: "Sync",
          message: "Login failed with \(secret)",
          isFailure: true)
      ]))
    XCTAssertFalse(text.contains(secret))
  }
}
