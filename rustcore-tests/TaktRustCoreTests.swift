import Foundation
import TaktRustCore
import XCTest

/// The Swift side of the boundary: proves the xcframework links and the
/// bindings match the library they were generated from. A UniFFI checksum
/// mismatch between the two fails the first call, so this is the canary for a
/// stale `build/core` after a change in `core/`.
final class TaktRustCoreTests: XCTestCase {
  func testTheCoreAnswersWithItsCrateVersion() throws {
    let manifest = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("core/Cargo.toml")
    let text = try String(contentsOf: manifest, encoding: .utf8)
    let line = try XCTUnwrap(
      text.split(separator: "\n").first { $0.hasPrefix("version = ") })
    let expected = line.split(separator: "\"")[1]
    XCTAssertEqual(coreVersion(), String(expected))
  }
}
