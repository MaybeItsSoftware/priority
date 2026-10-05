import XCTest

@testable import TaktCore

final class ThemeTypographyOverrideTests: XCTestCase {
  private let priority = BuiltInThemeSpecifications.priority

  func testAnEmptyOverrideLeavesTheThemeAlone() {
    let override = ThemeTypographyOverride()
    XCTAssertTrue(override.isEmpty)
    XCTAssertNil(override.structureOverlay(over: priority.structure.typography))
    XCTAssertEqual(override.applied(to: priority), priority)
  }

  func testBlankFamiliesAndAUnitScaleCountAsEmpty() {
    let override = ThemeTypographyOverride(bodyFamily: "  ", displayFamily: "", textScale: 1)
    XCTAssertTrue(override.isEmpty)
    XCTAssertEqual(override.applied(to: priority), priority)
  }

  func testAChosenFamilyGoesFirstWithTheThemesRequestBehindIt() {
    let base = priority.structure.typography
    let applied = ThemeTypographyOverride(bodyFamily: "Inter").applied(to: priority)
    let body = applied.structure.typography.body

    XCTAssertEqual(body.families.first, "Inter")
    XCTAssertEqual(Array(body.families.dropFirst()), base.body.families.filter { $0 != "Inter" })
    XCTAssertEqual(body.design, base.body.design)
    // Only the role chosen moves.
    XCTAssertEqual(applied.structure.typography.display, base.display)
    XCTAssertEqual(applied.structure.typography.mono, base.mono)
    XCTAssertEqual(applied.structure.typography.bodySize, base.bodySize)
  }

  func testEachRoleIsIndependentlyOverridable() {
    let applied = ThemeTypographyOverride(
      bodyFamily: "Geist", displayFamily: "Arvo", monoFamily: "JetBrains Mono"
    ).applied(to: priority)
    let type = applied.structure.typography
    XCTAssertEqual(type.body.families.first, "Geist")
    XCTAssertEqual(type.display.families.first, "Arvo")
    XCTAssertEqual(type.mono.families.first, "JetBrains Mono")
  }

  func testTextSizeScalesTheBodyAndEveryStepInProportion() {
    let base = priority.structure.typography
    let applied = ThemeTypographyOverride(textScale: 1.2).applied(to: priority)
    let type = applied.structure.typography

    func expected(_ value: Double) -> Double { (value * 1.2 * 2).rounded() / 2 }
    XCTAssertEqual(type.bodySize, expected(base.bodySize))
    XCTAssertEqual(type.scale.caption, expected(base.scale.caption))
    XCTAssertEqual(type.scale.body, expected(base.scale.body))
    XCTAssertEqual(type.scale.title, expected(base.scale.title))
    XCTAssertEqual(type.scale.display, expected(base.scale.display))
    XCTAssertEqual(type.scale.hero, expected(base.scale.hero))
    XCTAssertEqual(type.microLabel.size, expected(base.microLabel.size))
    // The label's other tokens are the theme's.
    XCTAssertEqual(type.microLabel.weight, base.microLabel.weight)
    XCTAssertEqual(type.microLabel.tracking, base.microLabel.tracking)
    XCTAssertEqual(type.microLabel.isUppercased, base.microLabel.isUppercased)
    XCTAssertEqual(type.body, base.body)
  }

  func testTextSizeIsClampedToTheOfferedRange() {
    XCTAssertEqual(ThemeTypographyOverride(textScale: 4).effectiveTextScale, 1.3)
    XCTAssertEqual(ThemeTypographyOverride(textScale: 0.1).effectiveTextScale, 0.85)
    XCTAssertEqual(ThemeTypographyOverride(textScale: .nan).effectiveTextScale, 1)
    XCTAssertEqual(ThemeTypographyOverride().effectiveTextScale, 1)
  }

  /// The point of keeping the choices apart from the theme: the same override
  /// lands on every theme, and leaves each one's own identity and palette.
  func testTheSameChoicesApplyToEveryBuiltIn() {
    let override = ThemeTypographyOverride(bodyFamily: "Inter", textScale: 1.1)
    for builtIn in BuiltInThemeSpecifications.all {
      let applied = override.applied(to: builtIn)
      XCTAssertEqual(applied.identifier, builtIn.identifier)
      XCTAssertEqual(applied.name, builtIn.name)
      XCTAssertEqual(applied.lockedAppearance, builtIn.lockedAppearance)
      XCTAssertEqual(applied.palette, builtIn.palette)
      XCTAssertEqual(applied.structure.radius, builtIn.structure.radius)
      XCTAssertEqual(applied.structure.spacing, builtIn.structure.spacing)
      XCTAssertEqual(applied.structure.typography.body.families.first, "Inter")
      XCTAssertGreaterThan(
        applied.structure.typography.bodySize, builtIn.structure.typography.bodySize)
      XCTAssertEqual(applied.validate().filter { $0.severity == .error }, [])
    }
  }

  func testTheOverrideRoundTripsThroughJSON() throws {
    let override = ThemeTypographyOverride(
      bodyFamily: "Inter", displayFamily: nil, monoFamily: "Lilex", textScale: 1.15)
    let data = try JSONEncoder().encode(override)
    XCTAssertEqual(try JSONDecoder().decode(ThemeTypographyOverride.self, from: data), override)
  }

  func testBundledFamiliesAreUniqueAndFindableByName() {
    let names = BundledFontFamily.all.map(\.name)
    XCTAssertEqual(Set(names).count, names.count)
    XCTAssertEqual(BundledFontFamily.named("Arvo")?.design, .serif)
    XCTAssertNil(BundledFontFamily.named("Comic Sans MS"))
  }
}
