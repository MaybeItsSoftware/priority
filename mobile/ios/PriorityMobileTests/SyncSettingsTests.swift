import PrioritySync
import XCTest
@testable import Priority

final class SyncPhaseTextTests: XCTestCase {
  func testDescribesEachPhase() {
    let now = Date()
    XCTAssertEqual(SyncPhaseText.describe(.unpaired, now: now), "Not set up")
    XCTAssertEqual(SyncPhaseText.describe(.syncing, now: now), "Syncing…")
    XCTAssertEqual(SyncPhaseText.describe(.idle(lastSyncedAt: nil), now: now), "Paired")
    XCTAssertEqual(SyncPhaseText.describe(.idle(lastSyncedAt: now.addingTimeInterval(-10)), now: now), "Synced just now")
    XCTAssertTrue(SyncPhaseText.describe(.idle(lastSyncedAt: now.addingTimeInterval(-3_600)), now: now).hasPrefix("Synced "))
    XCTAssertEqual(SyncPhaseText.describe(.failed("offline"), now: now), "Couldn't sync: offline")
    XCTAssertEqual(SyncPhaseText.short(.failed("x")), "Error")
  }

  func testPairingLinkRoundTripsThroughTheURLTheQRCodeCarries() throws {
    let link = SyncPairingLink(serverURL: try XCTUnwrap(URL(string: "https://sync.example.com")), code: "ABC123")
    XCTAssertEqual(SyncPairingLink(link.url.absoluteString), link)
    XCTAssertNil(SyncPairingLink("priority://add"))
    XCTAssertNotNil(QRCodeImage.render(link.url.absoluteString))
  }
}
