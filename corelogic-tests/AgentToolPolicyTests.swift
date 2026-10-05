import XCTest

@testable import TaktCore

final class AgentToolPolicyTests: XCTestCase {

  /// The two lists together are the CLI's whole tool table (33 tools, per
  /// `docs/mcp-server.md`), with nothing in both.
  func testReadAndWriteToolsPartitionTheServer() {
    let read = Set(AgentToolPolicy.readOnlyTools)
    let write = Set(AgentToolPolicy.writeTools)
    XCTAssertTrue(read.isDisjoint(with: write))
    XCTAssertEqual(read.count + write.count, 33)
  }

  func testNothingThatWritesIsPreAllowed() {
    for tool in AgentToolPolicy.writeTools {
      XCTAssertFalse(AgentToolPolicy.isReadOnly(AgentToolPolicy.qualifiedName(tool)), tool)
    }
    XCTAssertTrue(AgentToolPolicy.isReadOnly("mcp__takt__workspace_tasks"))
    // Another server's tool of the same name is not ours to allow.
    XCTAssertFalse(AgentToolPolicy.isReadOnly("mcp__other__workspace_tasks"))
    XCTAssertFalse(AgentToolPolicy.isReadOnly("workspace_tasks"))
  }

  func testPermissionRequestsAskOrRefuseButNeverAllow() {
    XCTAssertEqual(
      AgentToolPolicy.decision(forPermissionRequestOn: "mcp__takt__workspace_task_delete"), .askUser)
    XCTAssertEqual(AgentToolPolicy.decision(forPermissionRequestOn: "mcp__takt__task_search"), .askUser)
    XCTAssertEqual(AgentToolPolicy.decision(forPermissionRequestOn: "Bash"), .refuse)
    XCTAssertEqual(AgentToolPolicy.decision(forPermissionRequestOn: "mcp__filesystem__write"), .refuse)
    XCTAssertEqual(AgentToolPolicy.decision(forPermissionRequestOn: "mcp__takt__"), .refuse)
  }

  func testInvocationLoadsOnlyPriorityAndOnlyPreAllowsReads() throws {
    let arguments = AgentInvocation.arguments(
      helperPath: "/Applications/Takt.app/Contents/Helpers/takt", systemPrompt: "Hi")
    func value(after flag: String) -> String? {
      arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }
    XCTAssertEqual(arguments.first, "-p")
    XCTAssertEqual(value(after: "--input-format"), "stream-json")
    XCTAssertEqual(value(after: "--output-format"), "stream-json")
    XCTAssertTrue(arguments.contains("--strict-mcp-config"))
    XCTAssertEqual(value(after: "--tools"), "", "every built-in tool is off")
    XCTAssertEqual(value(after: "--permission-mode"), "manual")
    XCTAssertEqual(value(after: "--permission-prompt-tool"), "stdio")
    XCTAssertEqual(value(after: "--setting-sources"), "")
    XCTAssertEqual(value(after: "--system-prompt"), "Hi")
    XCTAssertFalse(arguments.contains("--model"))
    XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))

    let allowed = try XCTUnwrap(value(after: "--allowedTools")).split(separator: ",").map(String.init)
    XCTAssertEqual(Set(allowed), Set(AgentToolPolicy.readOnlyTools.map(AgentToolPolicy.qualifiedName)))

    let config = try XCTUnwrap(JSONValue.parse(try XCTUnwrap(value(after: "--mcp-config"))))
    let servers = try XCTUnwrap(config["mcpServers"]?.objectValue)
    XCTAssertEqual(Array(servers.keys), ["takt"])
    XCTAssertEqual(servers["takt"]?["command"], .string("/Applications/Takt.app/Contents/Helpers/takt"))
    XCTAssertEqual(servers["takt"]?["args"], .array([.string("--mcp-server")]))
  }

  func testAModelIsPassedOnlyWhenSet() {
    let arguments = AgentInvocation.arguments(helperPath: "/p", systemPrompt: "", model: " sonnet ")
    XCTAssertEqual(arguments.suffix(2), ["--model", "sonnet"])
    XCTAssertFalse(AgentInvocation.arguments(helperPath: "/p", systemPrompt: "", model: " ").contains("--model"))
  }

  func testLocatorTriesTheUsersPathFirstThenTheInstallerLocations() {
    let candidates = AgentCLILocator.candidates(userPath: " /opt/claude ", homeDirectory: "/Users/a")
    XCTAssertEqual(
      candidates,
      [
        "/opt/claude", "/Users/a/.local/bin/claude", "/Users/a/.claude/local/claude",
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
      ])
    XCTAssertEqual(AgentCLILocator.candidates(userPath: "", homeDirectory: "/Users/a").count, 4)
    XCTAssertEqual(
      AgentCLILocator.resolve(candidates: candidates, isExecutable: { $0.hasPrefix("/opt/homebrew") }),
      "/opt/homebrew/bin/claude")
    XCTAssertNil(AgentCLILocator.resolve(candidates: candidates, isExecutable: { _ in false }))
  }

  func testSystemPromptCarriesTheDateAndTheApprovalRule() {
    let date = ISO8601DateFormatter().date(from: "2026-09-28T09:00:00Z")!
    let text = AgentSystemPrompt.text(today: date, timeZone: TimeZone(identifier: "Europe/London")!)
    XCTAssertTrue(text.contains("2026-09-28"))
    XCTAssertTrue(text.contains("Monday 28 September 2026"))
    XCTAssertTrue(text.contains("only runs if they approve it"))
  }

  func testContextNamesWhatIsOnScreen() {
    XCTAssertNil(AgentSystemPrompt.context(listName: nil, listID: nil, taskTitle: nil, taskID: nil))
    XCTAssertEqual(
      AgentSystemPrompt.context(listName: "Groceries", listID: "L1", taskTitle: "Milk", taskID: "T1"),
      #"[The user is looking at list "Groceries" (id L1), with selected task "Milk" (id T1)]"#)
  }

  // MARK: - Summaries

  func testWriteSummaryResolvesIdsAndReadsInOrder() {
    let summary = AgentToolSummary.describe(
      tool: "mcp__takt__workspace_task_add",
      input: .object([
        "list_id": .string("L1"), "title": .string("Milk"), "notes": .string(""), "at_top": .bool(true),
      ]),
      name: { $0 == "L1" ? "Groceries" : nil })
    XCTAssertEqual(summary.title, "Add a task")
    XCTAssertFalse(summary.isDestructive)
    XCTAssertEqual(
      summary.fields,
      [
        .init(label: "Title", value: "Milk"),
        .init(label: "List", value: "Groceries"),
        .init(label: "At the top", value: "Yes"),
      ])
  }

  func testAnUnresolvedIdIsShownRatherThanHidden() {
    let summary = AgentToolSummary.describe(
      tool: "mcp__takt__workspace_task_delete", input: .object(["task_id": .string("T9")]))
    XCTAssertTrue(summary.isDestructive)
    XCTAssertEqual(summary.fields, [.init(label: "Task", value: "T9")])
  }

  func testClearingAValueSaysSo() {
    let summary = AgentToolSummary.describe(
      tool: "mcp__takt__workspace_task_update",
      input: .object(["task_id": .string("T1"), "kanban_column": .null]),
      name: { _ in "Milk" })
    XCTAssertEqual(
      summary.fields, [.init(label: "Task", value: "Milk"), .init(label: "Column", value: "None")])
  }

  func testAnUnknownToolStillGetsWords() {
    let summary = AgentToolSummary.describe(
      tool: "mcp__takt__brand_new_tool", input: .object(["some_flag": .bool(false)]))
    XCTAssertEqual(summary.title, "Brand new tool")
    XCTAssertEqual(summary.fields, [.init(label: "Some flag", value: "No")])
  }

  func testReadLineNamesTheToolAndWhatItLookedAt() {
    XCTAssertEqual(
      AgentToolSummary.readLine(tool: "mcp__takt__task_search", input: .object(["query": .string("milk")])),
      "task_search · milk")
    XCTAssertEqual(
      AgentToolSummary.readLine(
        tool: "mcp__takt__workspace_tasks", input: .object(["list_id": .string("L1")]),
        name: { _ in "Groceries" }),
      "workspace_tasks · Groceries")
    XCTAssertEqual(
      AgentToolSummary.readLine(tool: "mcp__takt__workspace_tree", input: .object([:])), "workspace_tree")
  }
}
