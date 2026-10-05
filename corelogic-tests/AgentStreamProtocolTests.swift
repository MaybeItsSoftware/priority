import XCTest

@testable import TaktCore

/// The lines below are trimmed from a real session with Claude Code 2.1.283,
/// driven the way the panel drives it, against a throwaway database.
final class AgentStreamProtocolTests: XCTestCase {

  func testInitLineStartsTheThread() {
    let line = """
      {"type":"system","subtype":"init","cwd":"/tmp","session_id":"9dc2","model":"claude-sonnet-5",\
      "tools":["mcp__priority__task_search","mcp__priority__workspace_task_add"]}
      """
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: line),
      [
        .started(
          sessionID: "9dc2", model: "claude-sonnet-5",
          tools: ["mcp__priority__task_search", "mcp__priority__workspace_task_add"])
      ])
  }

  func testAssistantLineYieldsTextAndToolCalls() {
    let line = """
      {"type":"assistant","message":{"role":"assistant","content":[\
      {"type":"text","text":"Now I'll add Milk."},\
      {"type":"tool_use","id":"toolu_01","name":"mcp__priority__workspace_task_add",\
      "input":{"title":"Milk","list_id":"94EA","position":2}},\
      {"type":"thinking","thinking":"…"},\
      {"type":"text","text":"  "}]},"session_id":"9dc2"}
      """
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: line),
      [
        .text("Now I'll add Milk."),
        .toolUse(
          AgentToolUse(
            id: "toolu_01", name: "mcp__priority__workspace_task_add",
            input: .object(["title": .string("Milk"), "list_id": .string("94EA"), "position": .int(2)]))),
      ])
  }

  func testToolResultsInEitherShape() {
    let blocks = """
      {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result",\
      "content":[{"type":"text","text":"Task created"}]}]}}
      """
    let string = """
      {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
      "content":"The user declined this change.","is_error":true,"tool_use_id":"toolu_02"}]}}
      """
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: blocks),
      [.toolResult(toolUseID: "toolu_01", isError: false, text: "Task created")])
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: string),
      [.toolResult(toolUseID: "toolu_02", isError: true, text: "The user declined this change.")])
  }

  func testCanUseToolBecomesAPermissionRequest() {
    let line = """
      {"type":"control_request","request_id":"8f11","request":{"subtype":"can_use_tool",\
      "tool_name":"mcp__priority__workspace_task_add","mcp_server":{"name":"priority","source":"dynamic"},\
      "display_name":"Workspace Task Add","input":{"title":"Milk","list_id":"94EA"},\
      "permission_suggestions":[],"tool_use_id":"toolu_01"}}
      """
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: line),
      [
        .permissionRequest(
          AgentPermissionRequest(
            requestID: "8f11", toolName: "mcp__priority__workspace_task_add",
            input: .object(["title": .string("Milk"), "list_id": .string("94EA")]),
            toolUseID: "toolu_01"))
      ])
  }

  func testOtherControlRequestsAreSurfacedToBeRefused() {
    let line = #"{"type":"control_request","request_id":"r2","request":{"subtype":"hook_callback"}}"#
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: line),
      [.unsupportedControlRequest(requestID: "r2", subtype: "hook_callback")])
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: #"{"type":"control_cancel_request","request_id":"8f11"}"#),
      [.controlRequestCancelled(requestID: "8f11")])
  }

  func testResultEndsTheTurn() {
    let line = """
      {"type":"result","subtype":"success","is_error":false,"duration_ms":7099,\
      "result":"Groceries has three open tasks.","session_id":"9dc2","total_cost_usd":0.0385}
      """
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: line),
      [
        .turnFinished(
          AgentTurnResult(
            isError: false, subtype: "success", text: "Groceries has three open tasks.", costUSD: 0.0385))
      ])
  }

  func testNoiseIsNoEvents() {
    XCTAssertEqual(AgentStreamParser.events(fromLine: ""), [])
    XCTAssertEqual(AgentStreamParser.events(fromLine: "not json"), [])
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: #"{"type":"rate_limit_event","rate_limit_info":{}}"#), [])
    XCTAssertEqual(
      AgentStreamParser.events(fromLine: #"{"type":"system","subtype":"hook_started"}"#), [])
  }

  // MARK: - Encoding

  func testUserMessageIsOneLine() throws {
    let line = AgentStreamEncoder.userMessage("Add milk\nand eggs")
    XCTAssertTrue(line.hasSuffix("\n"))
    XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "the framing is the newline")
    let value = try XCTUnwrap(JSONValue.parse(line))
    XCTAssertEqual(value["type"], .string("user"))
    XCTAssertEqual(value["message"]?["content"]?.arrayValue?.first?["text"], .string("Add milk\nand eggs"))
  }

  func testAllowQuotesTheRequestAndHandsBackTheInputUnchanged() throws {
    let input = JSONValue.object(["title": .string("Milk"), "position": .int(2), "at_top": .bool(false)])
    let line = AgentStreamEncoder.allow(requestID: "8f11", input: input)
    XCTAssertTrue(line.contains(#""position":2"#), "integers must not become 2.0")
    let value = try XCTUnwrap(JSONValue.parse(line))
    XCTAssertEqual(value["type"], .string("control_response"))
    XCTAssertEqual(value["response"]?["subtype"], .string("success"))
    XCTAssertEqual(value["response"]?["request_id"], .string("8f11"))
    XCTAssertEqual(value["response"]?["response"]?["behavior"], .string("allow"))
    XCTAssertEqual(value["response"]?["response"]?["updatedInput"], input)
  }

  func testDenyCarriesTheReason() throws {
    let value = try XCTUnwrap(
      JSONValue.parse(AgentStreamEncoder.deny(requestID: "8f11", message: "Declined")))
    XCTAssertEqual(value["response"]?["response"]?["behavior"], .string("deny"))
    XCTAssertEqual(value["response"]?["response"]?["message"], .string("Declined"))
  }

  func testErrorResponseForUnsupportedRequests() throws {
    let value = try XCTUnwrap(JSONValue.parse(AgentStreamEncoder.error(requestID: "r2", message: "no")))
    XCTAssertEqual(value["response"]?["subtype"], .string("error"))
    XCTAssertEqual(value["response"]?["request_id"], .string("r2"))
  }

  func testJSONValueRoundTripsItsKinds() {
    let text = #"{"a":null,"b":true,"c":3,"d":1.5,"e":"x","f":[1,"y"],"g":{"h":false}}"#
    let value = JSONValue.parse(text)
    XCTAssertEqual(value?.jsonString(), text)
  }
}
