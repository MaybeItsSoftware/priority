import TaktSync
import XCTest
@testable import Takt

final class SyncPhaseTextTests: XCTestCase {
  func testDescribesEachPhase() {
    let now = Date()
    XCTAssertEqual(SyncPhaseText.describe(.unpaired, now: now), "Not set up")
    XCTAssertEqual(SyncPhaseText.describe(.syncing, now: now), "Syncing…")
    XCTAssertEqual(SyncPhaseText.describe(.idle(lastSyncedAt: nil), now: now), "Signed in")
    XCTAssertEqual(SyncPhaseText.describe(.idle(lastSyncedAt: now.addingTimeInterval(-10)), now: now), "Synced just now")
    XCTAssertTrue(SyncPhaseText.describe(.idle(lastSyncedAt: now.addingTimeInterval(-3_600)), now: now).hasPrefix("Synced "))
    XCTAssertEqual(SyncPhaseText.describe(.failed("offline"), now: now), "Couldn't sync: offline")
    XCTAssertEqual(SyncPhaseText.short(.failed("x")), "Error")
  }

  func testSupabaseComesBackOnTheAppsOwnScheme() throws {
    let scheme = try XCTUnwrap(SyncServer.authCallbackURL.scheme)
    let callback = try XCTUnwrap(URL(string: "\(scheme)://auth-callback?code=abc"))
    XCTAssertTrue(SyncServer.isAuthCallback(callback))
    XCTAssertFalse(SyncServer.isAuthCallback(try XCTUnwrap(URL(string: "\(scheme)://add"))))
    // The app answers to that scheme: it is the one Info.plist registers.
    let registered = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
      .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    XCTAssertTrue(registered.contains(scheme), "\(scheme) is not among \(registered)")
  }
}
