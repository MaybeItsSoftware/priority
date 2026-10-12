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

  func testLedgerKeepsBlocksApart() {
    var ledger = AgentContextLedger()
    XCTAssertEqual(
      ledger.changes([AgentContextBlock(key: "a", text: "1"), AgentContextBlock(key: "b", text: "2")]), ["1", "2"])
    XCTAssertEqual(
      ledger.changes([AgentContextBlock(key: "a", text: "1"), AgentContextBlock(key: "b", text: "3")]), ["3"])
  }
}
