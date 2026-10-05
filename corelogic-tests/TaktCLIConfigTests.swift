import XCTest

@testable import TaktCore

final class TaktCLIConfigTests: XCTestCase {
  private let credentials = TaktCLICredentials(
    username: "you@example.com",
    remoteKey: "rkey",
    listId: "123"
  )

  private func seed(
    into existing: String?,
    credentials overrideCredentials: TaktCLICredentials? = nil
  ) throws -> (contents: String, outcome: MCPConfigWriteOutcome) {
    try TaktCLIConfigWriter.seeded(
      credentials: overrideCredentials ?? credentials,
      into: existing,
      configPath: "/tmp/priority/config.json"
    )
  }

  private func parse(_ json: String) throws -> [String: Any] {
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - Seeding

  func testSeedIntoMissingConfigWritesCredentials() throws {
    let result = try seed(into: nil)
    XCTAssertEqual(result.outcome, .added)

    let values = try parse(result.contents)
    XCTAssertEqual(values["username"] as? String, "you@example.com")
    XCTAssertEqual(values["remote_key"] as? String, "rkey")
    XCTAssertEqual(values["list_id"] as? String, "123")
  }

  func testSeedIntoEmptyFileIsTreatedAsEmptyObject() throws {
    XCTAssertEqual(try seed(into: "   \n ").outcome, .added)
  }

  func testSeedTrimsWhitespaceTheWayTheCLIDoes() throws {
    let padded = TaktCLICredentials(
      username: " you@example.com ", remoteKey: " rkey ", listId: " 123 ")
    let values = try parse(try seed(into: nil, credentials: padded).contents)
    XCTAssertEqual(values["username"] as? String, "you@example.com")
    XCTAssertEqual(values["remote_key"] as? String, "rkey")
    XCTAssertEqual(values["list_id"] as? String, "123")
  }

  /// The whole point of merging rather than overwriting: someone on a
  /// self-hosted Checkvist has a `base_url` the app knows nothing about.
  func testSeedPreservesUnrelatedKeys() throws {
    let existing = """
      {
        "base_url": "https://checkvist.example.com",
        "day_log_path": "~/logs"
      }
      """
    let result = try seed(into: existing)
    XCTAssertEqual(result.outcome, .added)

    let values = try parse(result.contents)
    XCTAssertEqual(values["base_url"] as? String, "https://checkvist.example.com")
    XCTAssertEqual(values["day_log_path"] as? String, "~/logs")
    XCTAssertEqual(values["remote_key"] as? String, "rkey")
  }

  func testRepeatedSeedOfIdenticalCredentialsReportsUnchanged() throws {
    let first = try seed(into: nil)
    let second = try seed(into: first.contents)
    XCTAssertEqual(second.outcome, .unchanged)
    XCTAssertEqual(second.contents, first.contents)
  }

  /// Rotating the remote key in the app is what this exists for: the file has
  /// to follow, or every configured client 401s with nothing to indicate why.
  func testSeedOverAStaleRemoteKeyReportsUpdated() throws {
    let existing = """
      {"username": "you@example.com", "remote_key": "old-key"}
      """
    let result = try seed(into: existing)
    XCTAssertEqual(result.outcome, .updated)
    XCTAssertEqual(try parse(result.contents)["remote_key"] as? String, "rkey")
  }

  /// `list_id` is the CLI's default for terminal use and the MCP entry
  /// overrides it per client, so a choice already made there stands.
  func testSeedFillsListIdOnlyWhenAbsent() throws {
    let existing = """
      {"username": "you@example.com", "remote_key": "rkey", "list_id": "999"}
      """
    let result = try seed(into: existing)
    XCTAssertEqual(result.outcome, .unchanged)
    XCTAssertEqual(try parse(result.contents)["list_id"] as? String, "999")
  }

  func testSeedWithoutAListIdLeavesTheKeyAlone() throws {
    let noList = TaktCLICredentials(username: "you@example.com", remoteKey: "rkey")
    let result = try seed(into: nil, credentials: noList)
    XCTAssertNil(try parse(result.contents)["list_id"])
  }

  /// A blank value in the file is no value at all as far as the CLI is
  /// concerned, so it gets replaced rather than treated as the user's choice.
  func testBlankStoredValuesAreTreatedAsAbsent() throws {
    let existing = """
      {"username": "  ", "remote_key": "", "list_id": " "}
      """
    let result = try seed(into: existing)
    XCTAssertEqual(result.outcome, .added)

    let values = try parse(result.contents)
    XCTAssertEqual(values["username"] as? String, "you@example.com")
    XCTAssertEqual(values["list_id"] as? String, "123")
  }

  // MARK: - Refusals

  func testMalformedConfigThrowsInsteadOfOverwriting() {
    XCTAssertThrowsError(try seed(into: "{ not json")) { error in
      XCTAssertEqual(
        error as? TaktCLIConfigError,
        .unreadableConfig(path: "/tmp/priority/config.json"))
    }
  }

  func testNonObjectConfigThrowsInsteadOfOverwriting() {
    XCTAssertThrowsError(try seed(into: "[1, 2, 3]")) { error in
      XCTAssertEqual(
        error as? TaktCLIConfigError,
        .unreadableConfig(path: "/tmp/priority/config.json"))
    }
  }

  func testEmptyCredentialsAreRefusedRatherThanWritten() {
    let blank = TaktCLICredentials(username: " ", remoteKey: "rkey")
    XCTAssertThrowsError(try seed(into: nil, credentials: blank)) { error in
      XCTAssertEqual(error as? TaktCLIConfigError, .missingCredentials)
    }
    let noKey = TaktCLICredentials(username: "you@example.com", remoteKey: "")
    XCTAssertThrowsError(try seed(into: nil, credentials: noKey)) { error in
      XCTAssertEqual(error as? TaktCLIConfigError, .missingCredentials)
    }
  }

  // MARK: - Path

  func testDefaultConfigPathMatchesTheCLIsOwn() {
    XCTAssertEqual(
      TaktCLIConfigWriter.defaultConfigPath(inHomeDirectory: "/Users/example"),
      "/Users/example/.config/takt/config.json"
    )
  }
}
