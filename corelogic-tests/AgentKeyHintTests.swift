import XCTest

@testable import TaktCore

/// The Mac's side of `core/src/agent_hints.rs`: the call reaches the core
/// with the commands in force, and the parts come back drawn as the palette
/// draws keys. The mapping itself is the core's, and tested there.
final class AgentKeyHintTests: XCTestCase {

  func testADueDateIsTheDueChordThenTheDate() {
    let hint = AgentKeyHintLine.forTool(
      "mcp__takt__task_update", input: .object(["task_id": .int(4), "due": .string("friday")]),
      commands: WorkspaceCommandCatalog.defaults)
    XCTAssertEqual(hint?.parts, [.key("dd"), .text("then type “friday”")])
  }

  func testAMoveIsMmAndAReadHasNone() {
    let move = AgentKeyHintLine.forTool(
      "mcp__takt__workspace_task_move", input: .object(["task_id": .string("A"), "list_id": .string("B")]),
      commands: WorkspaceCommandCatalog.defaults)
    XCTAssertEqual(move?.parts.first, .key("mm"))
    XCTAssertEqual(move?.plainText, "M M then choose the list")
    XCTAssertNil(
      AgentKeyHintLine.forTool(
        "mcp__takt__workspace_tasks", input: .object([:]), commands: WorkspaceCommandCatalog.defaults))
    XCTAssertNil(
      AgentKeyHintLine.forTool(
        "mcp__takt__daily_tick", input: .object(["daily_id": .string("d")]),
        commands: WorkspaceCommandCatalog.defaults))
  }

  func testTheHintFollowsAReboundKey() {
    let keymap = WorkspaceKeymap.parse(
      Data(#"[{"bindings": {"space": null, "x": null, "cmd+shift+u": "taskComplete"}}]"#.utf8)
    ).keymap
    let commands = keymap.resolve().bindings.commands
    let hint = AgentKeyHintLine.forTool(
      "mcp__takt__task_complete", input: .object(["task_id": .int(1)]), commands: commands)
    XCTAssertEqual(hint?.parts, [.key("cmd+shift+u")])
    XCTAssertEqual(hint?.plainText, "⌘⇧U")
  }

  func testTheSystemPromptSaysTheCardsShowTheKeys() {
    for asks in [false, true] {
      let text = AgentSystemPrompt.text(today: Date(), asksBeforeChanges: asks)
      XCTAssertTrue(text.contains("keys that would have made the same change"), "\(asks)")
    }
  }
}
