import XCTest

@testable import PriorityCore

final class ThemeFileTests: XCTestCase {
  private func source(_ name: String, _ json: String) -> ThemeFileSource {
    ThemeFileSource(name: name, data: Data(json.utf8))
  }

  private func load(_ sources: ThemeFileSource...) -> ThemeFileLibrary {
    ThemeFileLoader.load(sources)
  }

  private func messages(_ outcome: ThemeFileOutcome?) -> [String] {
    outcome?.issues.map(\.message) ?? []
  }

  // MARK: - Round trip

  /// Exporting a built-in and loading the export back gives the same theme,
  /// to the precision a hex string carries.
  func testExportedBuiltInsLoadBackAsTheSameTheme() throws {
    for builtIn in BuiltInThemeSpecifications.all {
      var file = ThemeFile(specification: builtIn)
      file.identifier = "user.copy"
      let data = try file.encoded()

      let (decoded, decodeIssues) = ThemeFileLoader.decode(data, source: "copy.json")
      XCTAssertEqual(decodeIssues, [])
      XCTAssertEqual(decoded, file)

      let library = ThemeFileLoader.load([ThemeFileSource(name: "copy.json", data: data)])
      let loaded = try XCTUnwrap(library.themes.first)
      XCTAssertEqual(loaded.name, builtIn.name)
      XCTAssertEqual(loaded.lockedAppearance, builtIn.lockedAppearance)
      XCTAssertEqual(loaded.structure, builtIn.structure)
      for appearance in ThemeAppearance.allCases {
        for role in ThemeColorRole.allCases {
          XCTAssertEqual(
            loaded.color(role, in: appearance).hexString,
            builtIn.color(role, in: appearance).hexString,
            "\(builtIn.name) \(appearance.rawValue).\(role.rawValue)")
        }
      }
      XCTAssertFalse(library.issues.contains { $0.severity == .error }, "\(library.issues)")
    }
  }

  func testTheTriStateFieldsSurviveEncoding() throws {
    let file = ThemeFile(identifier: "x", lockedAppearance: .unlocked, extends: .nothing)
    let json = try XCTUnwrap(String(bytes: try file.encoded(), encoding: .utf8))
    XCTAssertTrue(json.contains("\"extends\" : null"), json)
    XCTAssertTrue(json.contains("\"lockedAppearance\" : null"), json)
    XCTAssertEqual(ThemeFileLoader.decode(Data(json.utf8), source: "x.json").0, file)

    let bare = ThemeFileLoader.decode(Data("{}".utf8), source: "bare.json").0
    XCTAssertEqual(bare?.extends, .defaultTheme)
    XCTAssertEqual(bare?.lockedAppearance, .inherit)
  }

  // MARK: - extends and merging

  func testAFewOverridesInheritEverythingElseFromChalk() throws {
    let library = load(
      source(
        "dusk.json",
        """
        {
          "name": "Dusk",
          "palette": { "light": { "primary": "#7a4de8" }, "dark": { "paper": "#101014" } },
          "structure": { "radius": { "panel": 10 }, "typography": { "bodySize": 15 } }
        }
        """))
    let dusk = try XCTUnwrap(library.themes.first)
    let chalk = BuiltInThemeSpecifications.chalk

    XCTAssertEqual(dusk.identifier, "user.dusk", "no identifier: named after the file")
    XCTAssertEqual(dusk.name, "Dusk")
    XCTAssertEqual(dusk.color(.primary, in: .light).hexString, "#7A4DE8")
    XCTAssertEqual(dusk.color(.primary, in: .dark), chalk.color(.primary, in: .dark))
    XCTAssertEqual(dusk.color(.paper, in: .dark).hexString, "#101014")
    XCTAssertEqual(dusk.color(.ink, in: .light), chalk.color(.ink, in: .light))
    XCTAssertEqual(dusk.structure.radius.panel, 10)
    XCTAssertEqual(dusk.structure.radius.control, chalk.structure.radius.control)
    XCTAssertEqual(dusk.structure.border, chalk.structure.border)
    XCTAssertEqual(dusk.structure.typography.bodySize, 15)
    XCTAssertEqual(
      dusk.structure.typography.scale, .proportioned(fromBody: 15),
      "a new body size with no scale re-proportions the scale")
  }

  /// The built-ins moved to Zed's faces and quiet labels; a theme file can
  /// still put back the slab and the tracked capitals, in full.
  func testAThemeCanRestoreTheSlabFaceAndTheTrackedCapitals() throws {
    let library = load(
      source(
        "slab.json",
        """
        {
          "structure": { "typography": {
            "body": { "families": ["Arvo", "Rockwell"], "design": "serif" },
            "microLabel": { "size": 10, "weight": "bold", "tracking": 0.15, "uppercase": true }
          } }
        }
        """))
    let slab = try XCTUnwrap(library.themes.first)
    let type = slab.structure.typography
    XCTAssertEqual(type.body, ThemeFontFace(families: ["Arvo", "Rockwell"], design: .serif))
    XCTAssertEqual(type.mono, BuiltInThemeSpecifications.chalk.structure.typography.mono)
    XCTAssertEqual(
      type.microLabel,
      ThemeMicroLabel(size: 10, weight: .bold, tracking: 0.15, isUppercased: true, role: .mutedText))
  }

  func testExtendingChalkDarkInheritsItsLockUnlessClearedWithNull() throws {
    let library = load(
      source("a.json", ##"{ "extends": "native.theme.chalk.dark" }"##),
      source("b.json", ##"{ "extends": "native.theme.chalk.dark", "lockedAppearance": null }"##),
      source("c.json", ##"{ "lockedAppearance": "light" }"##))
    XCTAssertEqual(library.themes.map(\.lockedAppearance), [.dark, nil, .light])
  }

  func testAThemeCanExtendAnotherUserThemeWhateverTheFileOrder() throws {
    let library = load(
      source("a-child.json", ##"{ "extends": "mine.base", "palette": { "light": { "ink": "#111111" } } }"##),
      source("z-base.json", ##"{ "identifier": "mine.base", "palette": { "light": { "paper": "#fefefe" } } }"##))
    let child = try XCTUnwrap(library.themes.first { $0.identifier == "user.a-child" })
    XCTAssertEqual(child.color(.paper, in: .light).hexString, "#FEFEFE")
    XCTAssertEqual(child.color(.ink, in: .light).hexString, "#111111")
  }

  func testCyclesAndUnknownParentsAreSkippedWithAReason() {
    let library = load(
      source("a.json", ##"{ "identifier": "a", "extends": "b" }"##),
      source("b.json", ##"{ "identifier": "b", "extends": "a" }"##),
      source("c.json", ##"{ "extends": "nope" }"##))
    XCTAssertEqual(library.themes, [])
    XCTAssertEqual(library.outcomes.count, 3)
    XCTAssertTrue(library.outcomes.allSatisfy { $0.skippedReason != nil })
    XCTAssertEqual(library.outcomes[2].skippedReason, "it extends \"nope\", which is not a theme")
  }

  func testIdentifiersCannotShadowABuiltInOrEachOther() {
    let library = load(
      source("a.json", ##"{ "identifier": "native.theme.chalk" }"##),
      source("b.json", ##"{ "identifier": "mine" }"##),
      source("c.json", ##"{ "identifier": "mine" }"##))
    XCTAssertEqual(library.themes.map(\.identifier), ["mine"])
    XCTAssertNotNil(library.outcomes[0].skippedReason)
    XCTAssertEqual(library.outcomes[2].skippedReason, "identifier \"mine\" is already used by b.json")
  }

  // MARK: - Bad values are reported, not fatal

  func testABadHexIsAnErrorButTheThemeStillLoadsWithTheInheritedValue() throws {
    let library = load(
      source("bad.json", ##"{ "palette": { "light": { "paper": "#nothex", "ink": "#222" } } }"##))
    let outcome = try XCTUnwrap(library.outcomes.first)
    let theme = try XCTUnwrap(outcome.specification)
    XCTAssertEqual(
      theme.color(.paper, in: .light), BuiltInThemeSpecifications.chalk.color(.paper, in: .light))
    XCTAssertEqual(theme.color(.ink, in: .light).hexString, "#222222")
    XCTAssertEqual(outcome.issues.first?.severity, .error)
    XCTAssertTrue(messages(outcome).contains { $0.contains("palette.light.paper \"#nothex\"") })
  }

  func testAnUnknownRoleIsAWarningAndIgnored() throws {
    let library = load(source("x.json", ##"{ "palette": { "dark": { "backgroundd": "#000000" } } }"##))
    let outcome = try XCTUnwrap(library.outcomes.first)
    XCTAssertNotNil(outcome.specification)
    let issue = try XCTUnwrap(outcome.issues.first { $0.message.contains("backgroundd") })
    XCTAssertEqual(issue.severity, .warning)
    XCTAssertEqual(issue.source, "x.json")
  }

  func testUnknownKeysAndBadEnumeratedValuesAreReported() throws {
    let library = load(
      source(
        "x.json",
        """
        {
          "pallete": {},
          "lockedAppearance": "dusk",
          "structure": {
            "radius": { "pannel": 3 },
            "typography": { "body": { "design": "comic" }, "microLabel": { "weight": "heavy", "role": "nope" } }
          }
        }
        """))
    let outcome = try XCTUnwrap(library.outcomes.first)
    XCTAssertNotNil(outcome.specification, "every one of those is recoverable")
    let text = messages(outcome).joined(separator: "\n")
    for fragment in ["pallete", "structure.radius.pannel", "\"dusk\"", "\"comic\"", "\"heavy\"", "\"nope\""] {
      XCTAssertTrue(text.contains(fragment), "missing \(fragment) in:\n\(text)")
    }
  }

  func testAFileThatIsNotJSONIsSkippedNotThrown() throws {
    let library = load(source("broken.json", "{ \"name\": "), source("ok.json", "{}"))
    XCTAssertEqual(library.themes.map(\.identifier), ["user.ok"])
    let broken = try XCTUnwrap(library.outcomes.first)
    XCTAssertEqual(broken.skippedReason, "could not be read")
    XCTAssertTrue(messages(broken).contains("not valid JSON"))
  }

  func testAWrongTypeNamesThePath() throws {
    let library = load(source("x.json", ##"{ "structure": { "radius": { "panel": "big" } } }"##))
    XCTAssertTrue(
      messages(library.outcomes.first).contains("structure.radius.panel should be a number"),
      "\(messages(library.outcomes.first))")
  }

  func testANegativeSizeKeepsTheInheritedValue() throws {
    let library = load(source("x.json", ##"{ "structure": { "border": { "hairline": -1 } } }"##))
    let theme = try XCTUnwrap(library.themes.first)
    XCTAssertEqual(theme.structure.border.hairline, 1)
    XCTAssertEqual(library.issues.first?.severity, .error)
  }

  // MARK: - Missing roles

  func testAStandaloneThemeMissingARoleEverywhereIsSkipped() throws {
    var light: [String: String] = [:]
    for role in ThemeColorRole.allCases where role != .categoricalPink {
      light[role.rawValue] = "#808080"
    }
    let file = ThemeFile(extends: .nothing, palette: .init(light: light))
    let library = ThemeFileLoader.load([
      ThemeFileSource(name: "partial.json", data: try file.encoded())
    ])
    let outcome = try XCTUnwrap(library.outcomes.first)
    XCTAssertNil(outcome.specification)
    XCTAssertEqual(outcome.skippedReason, "no colour for categoricalPink")
  }

  func testAStandaloneThemeWithOneTableLoadsWithMissingRoleErrors() throws {
    var light: [String: String] = [:]
    for role in ThemeColorRole.allCases { light[role.rawValue] = "#808080" }
    light[ThemeColorRole.ink.rawValue] = "#000000"
    light[ThemeColorRole.paper.rawValue] = "#ffffff"
    let file = ThemeFile(extends: .nothing, palette: .init(light: light))
    let outcome = ThemeFileLoader.resolve(file, source: "light-only.json", base: nil)
    let theme = try XCTUnwrap(outcome.specification, "every role resolves, via the light table")
    XCTAssertEqual(theme.color(.ink, in: .dark).hexString, "#000000")
    XCTAssertTrue(outcome.issues.contains { $0.severity == .error && $0.message.contains("no dark value") })
  }
}
