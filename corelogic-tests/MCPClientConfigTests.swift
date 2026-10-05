import XCTest

@testable import TaktCore

final class MCPClientConfigTests: XCTestCase {
  private let entry = MCPServerEntry(
    command: "/Applications/Priority.app/Contents/MacOS/Priority",
    args: ["--mcp-server"],
    env: ["CHECKVIST_USERNAME": "you@example.com", "CHECKVIST_REMOTE_KEY": "key"]
  )

  private func merge(
    into existing: String?,
    entry overrideEntry: MCPServerEntry? = nil,
    serversKey: String = "mcpServers"
  ) throws -> (contents: String, outcome: MCPConfigWriteOutcome) {
    try MCPClientConfigWriter.merged(
      entry: overrideEntry ?? entry,
      into: existing,
      serversKey: serversKey,
      clientName: "Test Client",
      configPath: "/tmp/config.json"
    )
  }

  private func parse(_ json: String) throws -> [String: Any] {
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - Merging

  func testMergeIntoMissingConfigAddsServer() throws {
    let result = try merge(into: nil)
    XCTAssertEqual(result.outcome, .added)

    let servers = try XCTUnwrap(parse(result.contents)["mcpServers"] as? [String: Any])
    let server = try XCTUnwrap(servers["takt"] as? [String: Any])
    XCTAssertEqual(server["command"] as? String, entry.command)
    XCTAssertEqual(server["args"] as? [String], ["--mcp-server"])
  }

  func testMergeIntoEmptyFileIsTreatedAsEmptyObject() throws {
    XCTAssertEqual(try merge(into: "   \n ").outcome, .added)
  }

  /// The whole point of merging rather than overwriting: a user who already has
  /// three MCP servers configured must still have them afterwards.
  func testMergePreservesOtherServersAndUnrelatedKeys() throws {
    let existing = """
      {
        "globalShortcut": "Cmd+Shift+X",
        "mcpServers": {
          "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }
        }
      }
      """
    let result = try merge(into: existing)
    XCTAssertEqual(result.outcome, .added)

    let root = try parse(result.contents)
    XCTAssertEqual(root["globalShortcut"] as? String, "Cmd+Shift+X")

    let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
    XCTAssertEqual(Set(servers.keys), ["github", "takt"])
    let github = try XCTUnwrap(servers["github"] as? [String: Any])
    XCTAssertEqual(github["command"] as? String, "npx")
  }

  func testRepeatedMergeOfIdenticalEntryReportsUnchanged() throws {
    let first = try merge(into: nil)
    let second = try merge(into: first.contents)
    XCTAssertEqual(second.outcome, .unchanged)
  }

  func testMergeOverExistingPriorityEntryReportsUpdated() throws {
    let first = try merge(into: nil)
    let rotated = MCPServerEntry(
      command: entry.command,
      args: entry.args,
      env: ["CHECKVIST_USERNAME": "you@example.com", "CHECKVIST_REMOTE_KEY": "rotated"]
    )
    let second = try merge(into: first.contents, entry: rotated)
    XCTAssertEqual(second.outcome, .updated)

    let servers = try XCTUnwrap(parse(second.contents)["mcpServers"] as? [String: Any])
    let server = try XCTUnwrap(servers["takt"] as? [String: Any])
    let env = try XCTUnwrap(server["env"] as? [String: String])
    XCTAssertEqual(env["CHECKVIST_REMOTE_KEY"], "rotated")
  }

  /// Refuse rather than clobber: a config we can't parse is one we can't safely
  /// rewrite, and silently replacing it would lose the user's other servers.
  func testMalformedConfigThrowsInsteadOfOverwriting() {
    XCTAssertThrowsError(try merge(into: "{ not json")) { error in
      XCTAssertEqual(
        error as? MCPConfigError,
        .unreadableConfig(client: "Test Client", path: "/tmp/config.json")
      )
    }
  }

  func testServersKeyOfWrongTypeThrows() {
    XCTAssertThrowsError(try merge(into: #"{"mcpServers": []}"#)) { error in
      XCTAssertEqual(
        error as? MCPConfigError,
        .serversKeyNotAnObject(client: "Test Client", key: "mcpServers")
      )
    }
  }

  func testVSCodeStyleUsesServersKeyAndExplicitTransport() throws {
    let vsCodeEntry = MCPServerEntry(
      command: entry.command,
      args: entry.args,
      env: entry.env,
      transportType: "stdio"
    )
    let result = try merge(into: nil, entry: vsCodeEntry, serversKey: "servers")

    let root = try parse(result.contents)
    XCTAssertNil(root["mcpServers"])
    let servers = try XCTUnwrap(root["servers"] as? [String: Any])
    let server = try XCTUnwrap(servers["takt"] as? [String: Any])
    XCTAssertEqual(server["type"] as? String, "stdio")
  }

  // MARK: - The rename from Priority

  /// An entry this app wrote when it was called Priority is replaced, so the
  /// client isn't left with a second server pointing at an app that is gone.
  func testAnEntryWrittenUnderTheOldNameIsReplaced() throws {
    let existing = """
      {
        "mcpServers": {
          "github": { "command": "npx", "args": [] },
          "priority": { "command": "/Applications/Priority.app/Contents/Helpers/priority", "args": ["mcp"] }
        }
      }
      """
    let result = try merge(into: existing)
    XCTAssertEqual(result.outcome, .updated)
    let servers = try XCTUnwrap(parse(result.contents)["mcpServers"] as? [String: Any])
    XCTAssertEqual(Set(servers.keys), ["github", "takt"])
  }

  /// One the user wrote themselves, for something else that happens to be
  /// called `priority`, is not this app's to delete.
  func testAnUnrelatedEntryNamedPriorityIsLeftAlone() throws {
    let existing = """
      { "mcpServers": { "priority": { "command": "/opt/other/server", "args": [] } } }
      """
    let result = try merge(into: existing)
    XCTAssertEqual(result.outcome, .added)
    let servers = try XCTUnwrap(parse(result.contents)["mcpServers"] as? [String: Any])
    XCTAssertEqual(Set(servers.keys), ["priority", "takt"])
  }

  // MARK: - Terminal command

  func testTerminalCommandIsASingleShellSafeLine() throws {
    let command = MCPClientConfigWriter.terminalCommand(entry: entry)
    let removal = "claude mcp remove priority --scope user >/dev/null 2>&1; "
    let add = "claude mcp add-json takt --scope user '"
    XCTAssertTrue(command.hasPrefix(removal + add))
    XCTAssertTrue(command.hasSuffix("'"))
    XCTAssertFalse(command.contains("\n"))

    let json = String(command.dropFirst((removal + add).count))
      .dropLast()
    let server = try parse(String(json))
    XCTAssertEqual(server["command"] as? String, entry.command)
  }

  func testTerminalCommandEscapesSingleQuotesInCredentials() {
    let awkward = MCPServerEntry(
      command: "/bin/true",
      args: [],
      env: ["CHECKVIST_USERNAME": "o'brien@example.com"]
    )
    let command = MCPClientConfigWriter.terminalCommand(entry: awkward)
    XCTAssertTrue(command.contains(#"'\''"#))
  }

  // MARK: - Paste snippet

  func testPasteSnippetIsAFragmentWithoutOuterBraces() throws {
    let snippet = MCPClientConfigWriter.pasteSnippet(entry: entry, serversKey: "context_servers")
    XCTAssertTrue(snippet.hasPrefix("\"context_servers\""))
    XCTAssertFalse(snippet.hasPrefix("{"))

    // Wrapping it back in braces must yield the object Zed expects.
    let root = try parse("{\(snippet)}")
    let servers = try XCTUnwrap(root["context_servers"] as? [String: Any])
    let server = try XCTUnwrap(servers["takt"] as? [String: Any])
    XCTAssertEqual(server["command"] as? String, entry.command)
  }

  // MARK: - Detection

  func testDetectionMatchesHomeMarkersAndApplicationBundles() {
    let present: Set<String> = [
      "/Users/test/.claude.json",
      "/Applications/Cursor.app",
    ]
    let detected = MCPClientCatalog.detectedClients(
      homeDirectory: "/Users/test",
      fileExists: { present.contains($0) }
    )
    XCTAssertEqual(detected.map(\.id), ["claude-code", "cursor"])
  }

  func testDetectionReturnsNothingOnABareMachine() {
    let detected = MCPClientCatalog.detectedClients(
      homeDirectory: "/Users/test",
      fileExists: { _ in false }
    )
    XCTAssertTrue(detected.isEmpty)
  }

  func testClaudeCodeIsNeverEditedDirectly() {
    // `~/.claude.json` is rewritten by Claude Code itself; a direct merge would
    // race it. If this ever flips to `.mergeConfigFile` it needs a very good
    // reason.
    XCTAssertEqual(MCPClientCatalog.claudeCode.installStyle, .terminalCommand)
    XCTAssertEqual(MCPClientCatalog.zed.installStyle, .pasteSnippet)
  }
}
