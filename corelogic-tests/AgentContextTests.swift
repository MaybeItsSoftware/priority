import XCTest

@testable import TaktCore

final class AgentContextTests: XCTestCase {

  func testFolderChainRunsFromTheOutermostFolderIn() {
    let parents = ["inner": "middle", "middle": "outer"]
    XCTAssertEqual(
      AgentStandingInstructions.folderChain(from: "inner") { parents[$0] }, ["outer", "middle", "inner"])
    XCTAssertEqual(AgentStandingInstructions.folderChain(from: nil) { parents[$0] }, [])
  }

  func testFolderChainStopsAtACycle() {
    let parents = ["a": "b", "b": "a"]
    XCTAssertEqual(AgentStandingInstructions.folderChain(from: "a") { parents[$0] }, ["b", "a"])
  }

  func testBlockLabelsEachScopeInOrderAndSkipsBlankOnes() throws {
    let block = try XCTUnwrap(
      AgentStandingInstructions.block([
        AgentInstructionScope(kind: .account, id: nil, name: "Account", text: "Be brief."),
        AgentInstructionScope(kind: .folder, id: "F", name: "Work", text: "  "),
        AgentInstructionScope(kind: .list, id: "L", name: "Groceries", text: "Group by aisle.\n"),
      ]))
    XCTAssertTrue(block.hasSuffix("Account:\nBe brief.\n\nList \"Groceries\":\nGroup by aisle."))
    XCTAssertFalse(block.contains("Work"))
  }

  func testNoWrittenScopesIsNoBlock() {
    XCTAssertNil(
      AgentStandingInstructions.block([AgentInstructionScope(kind: .account, id: nil, name: "Account", text: "")]))
  }

  func testLedgerSendsABlockOnlyWhenItChanges() {
    var ledger = AgentContextLedger()
    let first = AgentContextBlock(key: "instructions", text: "A", cleared: "gone")
    XCTAssertEqual(ledger.changes([first]), ["A"])
    XCTAssertEqual(ledger.changes([first]), [])
    XCTAssertEqual(ledger.changes([AgentContextBlock(key: "instructions", text: "B", cleared: "gone")]), ["B"])
    XCTAssertEqual(ledger.changes([AgentContextBlock(key: "instructions", text: nil, cleared: "gone")]), ["gone"])
    XCTAssertEqual(ledger.changes([AgentContextBlock(key: "instructions", text: nil, cleared: "gone")]), [])
    XCTAssertEqual(ledger.changes([AgentContextBlock(key: "instructions", text: "B", cleared: "gone")]), ["B"])
  }

  func testVisibleTasksListsIdsInOrderAndSaysWhenCapped() throws {
    let tasks = (1...5).map { (id: "T\($0)", title: "Task \($0)") }
    let all = try XCTUnwrap(AgentSystemPrompt.visibleTasks(tasks))
    XCTAssertTrue(all.contains("(5)"))
    XCTAssertTrue(all.contains("- Task 1 (id T1)\n- Task 2 (id T2)"))
    let capped = try XCTUnwrap(AgentSystemPrompt.visibleTasks(tasks, limit: 2))
    XCTAssertTrue(capped.contains("the first 2 of 5"))
    XCTAssertFalse(capped.contains("T3"))
    XCTAssertNil(AgentSystemPrompt.visibleTasks([]))
  }

  func testAVisibleTitleIsKeptToOneShortLine() throws {
    let block = try XCTUnwrap(
      AgentSystemPrompt.visibleTasks([(id: "T", title: "Line one\nline two " + String(repeating: "x", count: 100))]))
    let line = try XCTUnwrap(block.split(separator: "\n").last)
    XCTAssertTrue(line.hasPrefix("- Line one line two"))
    XCTAssertTrue(line.contains("… (id T)"))
  }

  func testFailureAdviceSpellsOutTheFix() {
    XCTAssertTrue(AgentFailureAdvice.advice(for: "Invalid API key · Please run /login")?.contains("/login") == true)
    XCTAssertTrue(
      AgentFailureAdvice.advice(for: "error: unknown option '--permission-prompt-tool'")?.contains("claude update")
        == true)
    XCTAssertNil(AgentFailureAdvice.advice(for: "The turn ended with error_max_turns."))
  }

  func testAChangeShowsWhatItReplaces() {
    let summary = AgentToolSummary.describe(
      tool: "mcp__takt__workspace_task_update",
      input: .object(["task_id": .string("T1"), "title": .string("Oat milk"), "notes": .string("Same")]),
      name: { $0 == "T1" ? "Milk" : nil },
      current: { ["task_id": "Milk", "title": "Milk", "notes": "Same"][$0] })
    XCTAssertEqual(summary.fields.map(\.label), ["Task", "Title", "Notes"])
    XCTAssertEqual(summary.fields.map(\.previous), [nil, "Milk", nil])
  }

  func testLedgerKeepsBlocksApart() {
    var ledger = AgentContextLedger()
    XCTAssertEqual(
      ledger.changes([AgentContextBlock(key: "a", text: "1"), AgentContextBlock(key: "b", text: "2")]), ["1", "2"])
    XCTAssertEqual(
      ledger.changes([AgentContextBlock(key: "a", text: "1"), AgentContextBlock(key: "b", text: "3")]), ["3"])
  }

  /// After the agent saves a list's instructions, the next message carries
  /// the block again with them in it: the ledger compares the text, and the
  /// text is read back from the workspace.
  func testAnInstructionTheAgentSavedIsSentWithTheNextMessage() throws {
    var ledger = AgentContextLedger()
    func block(_ listText: String) -> [AgentContextBlock] {
      let scopes = [
        AgentInstructionScope(kind: .account, id: nil, name: "Account", text: "Verbs first."),
        AgentInstructionScope(kind: .list, id: "L1", name: "Groceries", text: listText),
      ]
      return [AgentContextBlock(
        key: "instructions", text: AgentStandingInstructions.block(scopes), cleared: AgentStandingInstructions.cleared)]
    }
    XCTAssertEqual(ledger.changes(block("")).count, 1)
    XCTAssertTrue(ledger.changes(block("")).isEmpty)
    let after = try XCTUnwrap(ledger.changes(block("Oat milk, never cow's.")).first)
    XCTAssertTrue(after.contains("List \"Groceries\":\nOat milk, never cow's."))
    XCTAssertTrue(ledger.changes(block("Oat milk, never cow's.")).isEmpty)
  }
}
