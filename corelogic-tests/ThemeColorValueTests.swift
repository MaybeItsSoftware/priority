import XCTest

@testable import PriorityCore

final class ThemeColorValueTests: XCTestCase {
  func testParsesSixDigitHexWithAndWithoutHash() {
    let withHash = ThemeColorValue(hex: "#FAF8F4")
    let withoutHash = ThemeColorValue(hex: "faf8f4")
    XCTAssertEqual(withHash, withoutHash)
    XCTAssertEqual(withHash?.hexString, "#FAF8F4")
  }

  func testParsesShorthandHexByDoublingEachDigit() {
    XCTAssertEqual(ThemeColorValue(hex: "#fff"), ThemeColorValue(hex: "#ffffff"))
    XCTAssertEqual(ThemeColorValue(hex: "#07f"), ThemeColorValue(hex: "#0077ff"))
  }

  func testParsesEightDigitHexAsAlpha() {
    let scrim = ThemeColorValue(hex: "#000000B3")
    XCTAssertNotNil(scrim)
    XCTAssertEqual(scrim?.alpha ?? 0, 0.7, accuracy: 0.01)
    XCTAssertEqual(scrim?.hexString, "#000000B3")
  }

  func testRejectsNonsense() {
    XCTAssertNil(ThemeColorValue(hex: ""))
    XCTAssertNil(ThemeColorValue(hex: "#12345"))
    XCTAssertNil(ThemeColorValue(hex: "#ggghhh"))
    XCTAssertNil(ThemeColorValue(hex: "chalk"))
  }

  func testChannelsClampRatherThanWrap() {
    let overdriven = ThemeColorValue(red: 4, green: -1, blue: 0.5, alpha: 9)
    XCTAssertEqual(overdriven.red, 1)
    XCTAssertEqual(overdriven.green, 0)
    XCTAssertEqual(overdriven.alpha, 1)
  }

  func testContrastRatioMatchesTheWCAGEndpoints() {
    let white = ThemeColorValue(hex: "#ffffff")!
    let black = ThemeColorValue(hex: "#000000")!
    XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.001)
    XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.001)
  }

  func testContrastRatioIsSymmetric() {
    let ink = ThemeColorValue(hex: "#444054")!
    let paper = ThemeColorValue(hex: "#faf8f4")!
    XCTAssertEqual(
      ink.contrastRatio(against: paper),
      paper.contrastRatio(against: ink),
      accuracy: 0.0001
    )
  }

  /// The numbers the house style states, checked rather than repeated.
  func testHouseStyleContrastFiguresOnChalk() {
    let paper = ThemeColorValue(hex: "#faf8f4")!
    func ratio(_ hex: String) -> Double {
      ThemeColorValue(hex: hex)!.contrastRatio(against: paper)
    }
    XCTAssertEqual(ratio("#444054"), 9.4, accuracy: 0.1)
    XCTAssertEqual(ratio("#6e6b7c"), 4.9, accuracy: 0.1)
    XCTAssertEqual(ratio("#d62246"), 4.7, accuracy: 0.1)
    // The one that is deliberately not for body copy.
    XCTAssertEqual(ratio("#007fff"), 3.6, accuracy: 0.1)
  }
}
