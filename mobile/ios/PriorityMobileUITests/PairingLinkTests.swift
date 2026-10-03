import XCTest

/// A `priority-sync://pair?…` link opened from outside the app — a QR code
/// read by the Camera, a link tapped in Messages — must attempt pairing and
/// report a failure in Settings, never crash or do nothing. Runs against the
/// app's real container (not `-uiTesting`), since sync is switched off in a
/// throwaway workspace; the server address is a closed local port, so no
/// network is reached.
final class PairingLinkTests: XCTestCase {
  func testAPairingLinkToAnUnreachableServerShowsACleanError() throws {
    let app = XCUIApplication()
    app.launch()
    let link = try XCTUnwrap(URL(string: "priority-sync://pair?server=http%3A%2F%2F127.0.0.1%3A9&code=X"))
    app.open(link)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons["Open"]
    if open.waitForExistence(timeout: 3) { open.tap() }

    let error = app.descendants(matching: .any)["sync.pairingError"]
    XCTAssertTrue(error.waitForExistence(timeout: 20), "the failure is reported on the Sync page")
    XCTAssertEqual(app.state, .runningForeground)
    Self.save(XCUIScreen.main.screenshot(), as: "pair-error")
  }

  /// Leaves a copy for review when the shots directory exists.
  static func save(_ screenshot: XCUIScreenshot, as name: String) {
    let directory = URL(filePath: "/tmp/iosshots")
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(name).png"))
  }
}
