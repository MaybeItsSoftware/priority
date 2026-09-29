import CoreGraphics
import XCTest

@testable import PriorityCore

final class WindowFrameClampTests: XCTestCase {

  /// A laptop panel as main, with an external display to its right.
  private let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
  private let external = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
  private let minSize = CGSize(width: 760, height: 548)

  func testFullyVisibleFrameIsUnchanged() {
    let frame = CGRect(x: 100, y: 100, width: 900, height: 700)
    XCTAssertEqual(WindowFrameClamp.clamp(frame, visibleFrames: [main, external], minSize: minSize), frame)

    let onExternal = CGRect(x: 2000, y: 300, width: 1200, height: 900)
    XCTAssertEqual(
      WindowFrameClamp.clamp(onExternal, visibleFrames: [main, external], minSize: minSize), onExternal)
  }

  /// The external display has been unplugged: the frame saved on it is on no
  /// screen at all, so it goes to the middle of the main one.
  func testOffScreenFrameMovesToMainScreenCentred() {
    let saved = CGRect(x: 2000, y: 300, width: 900, height: 700)
    let result = WindowFrameClamp.clamp(saved, visibleFrames: [main], minSize: minSize)
    XCTAssertEqual(result.size, saved.size)
    XCTAssertEqual(result.midX, main.midX)
    XCTAssertEqual(result.midY, main.midY)
    XCTAssertTrue(main.contains(result))
  }

  func testPartiallyOffFrameIsNudgedInside() {
    // Hanging off the right-hand edge with the title bar still reachable.
    let saved = CGRect(x: 1000, y: 100, width: 900, height: 700)
    let result = WindowFrameClamp.clamp(saved, visibleFrames: [main], minSize: minSize)
    XCTAssertEqual(result, CGRect(x: 540, y: 100, width: 900, height: 700))
  }

  /// The body is on screen but the title bar is above it — nothing to grab.
  func testFrameWhoseTitleBarIsOffScreenIsNotKeptWhereItWas() {
    let saved = CGRect(x: 100, y: 400, width: 900, height: 700)
    let result = WindowFrameClamp.clamp(saved, visibleFrames: [main], minSize: minSize)
    XCTAssertLessThanOrEqual(result.maxY, main.maxY)
    XCTAssertTrue(main.contains(result))
  }

  /// A frame saved on the big display, restored onto the laptop alone.
  func testTooLargeFrameIsShrunkToFit() {
    let saved = CGRect(x: 0, y: 0, width: 2400, height: 1400)
    let result = WindowFrameClamp.clamp(saved, visibleFrames: [main], minSize: minSize)
    XCTAssertEqual(result, main)
  }

  /// The minimum size wins over a screen too small for it, keeping the title
  /// bar and left edge visible rather than centring it off the top.
  func testMinimumSizeIsRespectedWithTitleBarKeptOnScreen() {
    let tiny = CGRect(x: 0, y: 0, width: 600, height: 400)
    let result = WindowFrameClamp.clamp(
      CGRect(x: 50, y: 50, width: 900, height: 700), visibleFrames: [tiny], minSize: minSize)
    XCTAssertEqual(result.size, minSize)
    XCTAssertEqual(result.minX, tiny.minX)
    XCTAssertEqual(result.maxY, tiny.maxY)
  }

  func testNoScreensLeavesFrameAlone() {
    let frame = CGRect(x: 5000, y: 5000, width: 900, height: 700)
    XCTAssertEqual(WindowFrameClamp.clamp(frame, visibleFrames: []), frame)
  }
}
