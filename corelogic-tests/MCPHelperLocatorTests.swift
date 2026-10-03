import XCTest

@testable import PriorityCore

/// Where `Takt --mcp-server` looks for the CLI it hands over to.
///
/// This is the compatibility story for retiring the in-process MCP server:
/// client configurations already on disk name
/// `/Applications/Priority.app/Contents/MacOS/Priority --mcp-server`, and they
/// keep working only because that binary can still find something to become.
final class MCPHelperLocatorTests: XCTestCase {

  private func candidates(
    override: String? = nil,
    bundle: String = "/Applications/Takt.app",
    home: String = "/Users/someone"
  ) -> [String] {
    MCPHelperLocator.candidates(
      environmentOverride: override, bundlePath: bundle, homeDirectory: home)
  }

  /// The one that matters: an app installed from the DMG, with no CLI on the
  /// machine, still resolves — because the CLI ships inside the bundle.
  func testTheBundledHelperIsFoundWithNothingElseInstalled() {
    let resolved = MCPHelperLocator.resolve(candidates: candidates()) {
      $0 == "/Applications/Takt.app/Contents/Helpers/takt"
    }
    XCTAssertEqual(resolved, "/Applications/Takt.app/Contents/Helpers/takt")
  }

  /// So a development build can be pointed at a freshly built CLI without
  /// reinstalling the app.
  func testAnExplicitOverrideOutranksTheBundledHelper() {
    let resolved = MCPHelperLocator.resolve(
      candidates: candidates(override: "/tmp/priority"), isExecutable: { _ in true })
    XCTAssertEqual(resolved, "/tmp/priority")
  }

  func testABlankOverrideIsIgnoredRatherThanTried() {
    XCTAssertEqual(candidates(override: "   ").first, candidates().first)
  }

  func testTheOverrideIsTrimmed() {
    XCTAssertEqual(candidates(override: "  /tmp/priority \n").first, "/tmp/priority")
  }

  /// The fallbacks matter for a bundle built with PRIORITY_SKIP_CLI_BUNDLE=1,
  /// or one run straight out of DerivedData.
  func testASeparatelyInstalledCLIIsFoundWhenTheBundleHasNone() {
    let resolved = MCPHelperLocator.resolve(candidates: candidates()) {
      $0 == "/Users/someone/.local/bin/takt"
    }
    XCTAssertEqual(resolved, "/Users/someone/.local/bin/takt")
  }

  func testTheSearchOrderPrefersTheBundleOverAnInstalledCLI() {
    let all = candidates()
    let bundled = all.firstIndex(of: "/Applications/Takt.app/Contents/Helpers/takt")
    let installed = all.firstIndex(of: "/usr/local/bin/takt")
    XCTAssertNotNil(bundled)
    XCTAssertNotNil(installed)
    XCTAssertLessThan(
      bundled!, installed!,
      "the app must run the CLI it shipped with, not whichever one is on PATH")
  }

  func testNothingExecutableResolvesToNothing() {
    XCTAssertNil(MCPHelperLocator.resolve(candidates: candidates(), isExecutable: { _ in false }))
  }

  func testDuplicateCandidatesAreTriedOnce() {
    let withDuplicate = candidates(override: "/Applications/Takt.app/Contents/Helpers/takt")
    XCTAssertEqual(Set(withDuplicate).count, withDuplicate.count)
  }

  /// "Not found" without the search order is the kind of error that costs an
  /// afternoon, and stderr is the only channel — stdout carries the protocol.
  func testTheDiagnosticNamesEveryPathTried() {
    let message = MCPHelperLocator.missingHelperMessage(candidates: candidates())
    for candidate in candidates() {
      XCTAssertTrue(message.contains(candidate), "\(candidate) missing from the diagnostic")
    }
    XCTAssertTrue(message.contains("install_cli.sh"), "the diagnostic should say how to fix it")
  }

  // MARK: - Argument forwarding

  func testTheFlagAndEverythingAfterItIsForwarded() {
    XCTAssertEqual(
      MCPHelperLocator.forwardedArguments(from: ["/path/Priority", "--mcp-server"]),
      ["--mcp-server"])
  }

  /// Anything the launcher prepends — the `-psn_…` LaunchServices passes, for
  /// instance — is dropped rather than handed to the CLI's parser.
  func testArgumentsBeforeTheFlagAreDropped() {
    XCTAssertEqual(
      MCPHelperLocator.forwardedArguments(from: ["/path/Priority", "-psn_0_123", "--mcp-server"]),
      ["--mcp-server"])
  }

  /// So a future CLI flag needs no change in the shim.
  func testTrailingArgumentsSurvive() {
    XCTAssertEqual(
      MCPHelperLocator.forwardedArguments(
        from: ["/path/Priority", "--mcp-server", "--verbose", "x"]),
      ["--mcp-server", "--verbose", "x"])
  }
}
