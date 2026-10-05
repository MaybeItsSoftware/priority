import XCTest

@testable import TaktCore

final class ThemePaletteTests: XCTestCase {
  private func value(_ hex: String) -> ThemeColorValue {
    ThemeColorValue(hex: hex)!
  }

  func testRoleFlipsWithTheAppearance() {
    let palette = ThemePalette(
      light: [.paper: value("#ffffff"), .ink: value("#000000")],
      dark: [.paper: value("#000000"), .ink: value("#ffffff")]
    )
    XCTAssertEqual(palette.color(.paper, in: .light), value("#ffffff"))
    XCTAssertEqual(palette.color(.paper, in: .dark), value("#000000"))
    XCTAssertEqual(palette.color(.ink, in: .light), value("#000000"))
    XCTAssertEqual(palette.color(.ink, in: .dark), value("#ffffff"))
  }

  func testInvariantRoleDoesNotFlip() {
    // Rule 5: the content under a letterbox isn't ours to theme, so the
    // letterbox doesn't flip — even when the dark table tries to make it.
    let palette = ThemePalette(
      light: [.mediaLetterbox: value("#000000")],
      dark: [.mediaLetterbox: value("#ffffff")]
    )
    XCTAssertEqual(palette.color(.mediaLetterbox, in: .light), value("#000000"))
    XCTAssertEqual(palette.color(.mediaLetterbox, in: .dark), value("#000000"))
  }

  func testMissingRoleFallsBackToTheOtherTable() {
    let palette = ThemePalette(light: [.primary: value("#007fff")], dark: [:])
    XCTAssertEqual(palette.color(.primary, in: .dark), value("#007fff"))
  }

  func testAbsentEverywhereResolvesToTheDebugColour() {
    let palette = ThemePalette(light: [:], dark: [:])
    XCTAssertEqual(palette.color(.paper, in: .light), .unresolved)
  }

  func testMissingRolesReportsBothTables() {
    let palette = ThemePalette(light: [.paper: value("#ffffff")], dark: [:])
    XCTAssertFalse(palette.missingRoles(in: .light).contains(.paper))
    XCTAssertTrue(palette.missingRoles(in: .light).contains(.ink))
    XCTAssertTrue(palette.missingRoles(in: .dark).contains(.paper))
  }

  func testInvariantRolesAreNeverMissingFromTheDarkTable() {
    let palette = ThemePalette(
      light: Dictionary(
        uniqueKeysWithValues: ThemeColorRole.allCases.map { ($0, value("#808080")) }),
      dark: Dictionary(
        uniqueKeysWithValues: ThemeColorRole.allCases
          .filter { !$0.isThemeInvariant }
          .map { ($0, value("#808080")) })
    )
    XCTAssertEqual(palette.missingRoles(in: .light), [])
    XCTAssertEqual(palette.missingRoles(in: .dark), [])
  }

  func testAppearanceOpposite() {
    XCTAssertEqual(ThemeAppearance.light.opposite, .dark)
    XCTAssertEqual(ThemeAppearance.dark.opposite, .light)
  }
}
