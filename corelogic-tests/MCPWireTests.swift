import XCTest

@testable import TaktCore

/// The half of an MCP client that has no process in it: what goes down the
/// pipe, and what can be read back off it.
final class MCPWireTests: XCTestCase {

  private func decodedObject(_ message: JSONValue) throws -> JSONValue {
    let data = try MCPWire.encode(message)
    XCTAssertEqual(data.last, 0x0A, "stdio framing is newline-delimited")
    return try JSONDecoder().decode(JSONValue.self, from: data.dropLast())
  }

  func testInitializeCarriesAProtocolVersionAndAnId() throws {
    let encoded = try decodedObject(
      MCPWire.initializeRequest(id: 7, clientName: "Priority", clientVersion: "1.2"))

    XCTAssertEqual(encoded["jsonrpc"]?.stringValue, "2.0")
    XCTAssertEqual(encoded["id"]?.intValue, 7)
    XCTAssertEqual(encoded["method"]?.stringValue, "initialize")
    XCTAssertEqual(
      encoded["params"]?["protocolVersion"]?.stringValue, MCPWire.protocolVersion)
    XCTAssertEqual(encoded["params"]?["clientInfo"]?["name"]?.stringValue, "Priority")
  }

  /// A notification with an id would leave the client waiting for a reply that
  /// is never coming.
  func testTheInitializedNotificationHasNoId() throws {
    let encoded = try decodedObject(MCPWire.initializedNotification())

    XCTAssertNil(encoded["id"])
    XCTAssertEqual(encoded["method"]?.stringValue, "notifications/initialized")
  }

  func testToolCallCarriesItsArguments() throws {
    let encoded = try decodedObject(
      MCPWire.toolCallRequest(
        id: 3,
        name: "create_doc_from_markdown",
        arguments: ["title": .string("Today"), "markdown": .string("- [x] ship it")]
      ))

    XCTAssertEqual(encoded["method"]?.stringValue, "tools/call")
    XCTAssertEqual(encoded["params"]?["name"]?.stringValue, "create_doc_from_markdown")
    XCTAssertEqual(encoded["params"]?["arguments"]?["title"]?.stringValue, "Today")
  }

  func testResultsAndErrorsAreToldApart() {
    XCTAssertEqual(
      MCPWire.decode(line: #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#),
      .result(id: 1, value: .object(["ok": .bool(true)]))
    )
    XCTAssertEqual(
      MCPWire.decode(line: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"nope"}}"#),
      .failure(id: 2, code: -32602, message: "nope")
    )
  }

  /// Servers write notifications and, under nvm, the occasional stray line.
  /// Neither is an answer to anything, and neither may be fatal.
  func testAnythingWithNoRequestWaitingOnItIsUnrelated() {
    XCTAssertEqual(MCPWire.decode(line: "npm warn: something"), .unrelated)
    XCTAssertEqual(
      MCPWire.decode(line: #"{"jsonrpc":"2.0","method":"notifications/message"}"#), .unrelated)
    XCTAssertEqual(MCPWire.decode(line: ""), .unrelated)
  }

  func testToolTextIsJoinedAndNonTextContentIsSkipped() {
    let result = JSONValue.object([
      "content": .array([
        .object(["type": .string("text"), "text": .string("first")]),
        .object(["type": .string("image"), "data": .string("…")]),
        .object(["type": .string("text"), "text": .string("second")]),
      ])
    ])

    XCTAssertEqual(MCPWire.toolResultText(result), "first\n\nsecond")
  }

  /// The trap this exists for: a failed tool call is reported *inside* a
  /// successful JSON-RPC result, so a client that only checks `error` reads a
  /// failure as a success.
  func testAToolFailureInsideASuccessfulResultIsVisible() {
    let result = JSONValue.object([
      "isError": .bool(true),
      "content": .array([.object(["type": .string("text"), "text": .string("no such doc")])]),
    ])

    XCTAssertTrue(MCPWire.toolResultIsError(result))
    XCTAssertEqual(MCPWire.toolResultText(result), "no such doc")
  }

  func testStructuredContentFallsBackToParsingTheTextBlock() {
    let structured = JSONValue.object([
      "structuredContent": .object(["docId": .string("abc")])
    ])
    XCTAssertEqual(MCPWire.structuredContent(structured)?["docId"]?.stringValue, "abc")

    let textOnly = JSONValue.object([
      "content": .array([
        .object(["type": .string("text"), "text": .string(#"{"docId":"def"}"#)])
      ])
    ])
    XCTAssertEqual(MCPWire.structuredContent(textOnly)?["docId"]?.stringValue, "def")

    let prose = JSONValue.object([
      "content": .array([.object(["type": .string("text"), "text": .string("all done")])])
    ])
    XCTAssertNil(MCPWire.structuredContent(prose))
  }
}
