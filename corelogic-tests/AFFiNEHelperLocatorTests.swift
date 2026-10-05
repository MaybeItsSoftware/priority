import XCTest

@testable import TaktCore

/// Finding `affine-mcp`, which is not ours and is not bundled — the user
/// installed it, and under nvm it is somewhere no GUI app's PATH reaches.
final class AFFiNEHelperLocatorTests: XCTestCase {

  private func candidates(
    configured: String? = nil,
    override: String? = nil,
    nodeVersions: [String] = []
  ) -> [String] {
    AFFiNEHelperLocator.candidates(
      configuredPath: configured,
      environmentOverride: override,
      homeDirectory: "/Users/someone",
      nodeVersionDirectories: nodeVersions
    )
  }

  func testAConfiguredPathIsTriedFirst() {
    let resolved = AFFiNEHelperLocator.resolve(
      candidates: candidates(configured: "/opt/affine-mcp", override: "/env/affine-mcp")
    ) { _ in true }

    XCTAssertEqual(resolved, "/opt/affine-mcp")
  }

  func testBlankSettingsAreNotCandidates() {
    XCTAssertFalse(candidates(configured: "   ", override: "").contains("   "))
  }

  /// The case the whole locator exists for: nothing on the system PATH, an
  /// nvm-managed node, and a binary that still has to be found.
  func testAnNvmInstallIsFound() {
    let resolved = AFFiNEHelperLocator.resolve(
      candidates: candidates(nodeVersions: ["/Users/someone/.nvm/versions/node/v22.0.0"])
    ) { $0.hasPrefix("/Users/someone/.nvm") }

    XCTAssertEqual(resolved, "/Users/someone/.nvm/versions/node/v22.0.0/bin/affine-mcp")
  }

  func testNothingIsTriedTwice() {
    let all = candidates(configured: "/opt/homebrew/bin/affine-mcp")
    XCTAssertEqual(all.count, Set(all).count)
  }

  /// `affine-mcp` is a `#!/usr/bin/env node` script, so the directory it lives
  /// in — which is also where its node lives — has to lead.
  func testTheHelpersOwnDirectoryLeadsThePath() {
    let path = AFFiNEHelperLocator.searchPath(
      forHelperPath: "/Users/someone/.nvm/versions/node/v22.0.0/bin/affine-mcp",
      basePATH: "/usr/bin:/bin"
    )

    XCTAssertEqual(path, "/Users/someone/.nvm/versions/node/v22.0.0/bin:/usr/bin:/bin")
  }

  func testADirectoryAlreadyOnThePathIsMovedRatherThanRepeated() {
    let path = AFFiNEHelperLocator.searchPath(
      forHelperPath: "/usr/local/bin/affine-mcp",
      basePATH: "/usr/bin:/usr/local/bin:/bin"
    )

    XCTAssertEqual(path, "/usr/local/bin:/usr/bin:/bin")
  }

  func testTheDiagnosticNamesEveryPathTried() {
    let all = candidates()
    let message = AFFiNEHelperLocator.missingHelperMessage(candidates: all)

    for candidate in all {
      XCTAssertTrue(message.contains(candidate), "\(candidate) missing from the diagnostic")
    }
    XCTAssertTrue(message.contains("npm install -g affine-mcp-server"))
  }
}
