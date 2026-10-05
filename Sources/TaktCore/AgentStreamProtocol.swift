import Foundation

/// The agent panel's wire format: Claude Code's headless `stream-json`, one
/// JSON object per line in each direction.
///
/// The panel runs the user's own `claude` binary with
/// `-p --input-format stream-json --output-format stream-json`, the mode the
/// Agent SDK drives it in. What comes back is a stream of transcript messages
/// (`system`, `assistant`, `user` carrying tool results, `result` at the end of
/// a turn) interleaved with `control_request`s — the CLI asking its host a
/// question it cannot answer itself. With `--permission-prompt-tool stdio` the
/// question that matters is `can_use_tool`: every tool call not pre-allowed
/// stops and waits for a `control_response` on stdin saying allow or deny.
/// That wait is what the approval card is drawn on.
///
/// Parsing and encoding are here rather than beside the `Process` so the shape
/// of each line — the part that breaks when the CLI changes — is tested
/// without launching anything. See `docs/agent-panel.md`.

/// The agent's lines are `JSONValue` (`MCPWire.swift`) — the same Sendable
/// JSON the AFFiNE session reads its server with — plus what the panel needs:
/// parsing a line, printing a value, and reading a number either way.
///
/// A tool's input is kept whole as one, so it can be shown, summarised and
/// handed back to the CLI unchanged when the user approves it. Integral
/// numbers stay `.int`, so a `position: 2` goes back as `2` rather than `2.0`
/// — the CLI's tools parse integers strictly.
extension JSONValue {
  public var doubleValue: Double? {
    switch self {
    case .int(let value): Double(value)
    case .double(let value): value
    default: nil
    }
  }

  /// Compact, key-sorted JSON — for the wire and for the disclosure under an
  /// approval card.
  public func jsonString(pretty: Bool = false) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "null" }
    return String(bytes: data, encoding: .utf8) ?? "null"
  }

  public static func parse(_ text: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}

/// A tool call the assistant made, as it appears in the transcript.
public struct AgentToolUse: Equatable, Sendable {
  public let id: String
  public let name: String
  public let input: JSONValue

  public init(id: String, name: String, input: JSONValue) {
    self.id = id
    self.name = name
    self.input = input
  }
}

/// The CLI asking whether a tool call may run. Nothing runs until it is
/// answered, and it is answered only by a click.
public struct AgentPermissionRequest: Equatable, Sendable {
  /// The control request's id, which the answer has to quote.
  public let requestID: String
  public let toolName: String
  public let input: JSONValue
  /// The `tool_use` block this is about, so its result can be matched later.
  public let toolUseID: String?

  public init(requestID: String, toolName: String, input: JSONValue, toolUseID: String?) {
    self.requestID = requestID
    self.toolName = toolName
    self.input = input
    self.toolUseID = toolUseID
  }
}

/// How a turn ended.
public struct AgentTurnResult: Equatable, Sendable {
  public let isError: Bool
  /// `success`, or an `error_…` subtype such as `error_max_turns`.
  public let subtype: String
  /// The final text, or on failure the CLI's explanation (for instance, not
  /// being logged in).
  public let text: String?
  public let costUSD: Double?

  public init(isError: Bool, subtype: String, text: String?, costUSD: Double?) {
    self.isError = isError
    self.subtype = subtype
    self.text = text
    self.costUSD = costUSD
  }
}

/// One thing the panel does something about. A line can carry several — an
/// assistant message with text and two tool calls is three.
public enum AgentStreamEvent: Equatable, Sendable {
  case started(sessionID: String, model: String?, tools: [String])
  case text(String)
  case toolUse(AgentToolUse)
  case toolResult(toolUseID: String, isError: Bool, text: String)
  case permissionRequest(AgentPermissionRequest)
  /// A question the panel has no answer for. It is refused, never ignored:
  /// an unanswered control request leaves the CLI waiting forever.
  case unsupportedControlRequest(requestID: String, subtype: String)
  /// The CLI withdrew a question it had asked, so its card can stop waiting.
  case controlRequestCancelled(requestID: String)
  case turnFinished(AgentTurnResult)
}

public enum AgentStreamParser {

  /// The events on one line of the CLI's stdout. Anything unrecognised —
  /// rate-limit notices, hook chatter, a line that is not JSON — is no events
  /// rather than an error: the stream carries plenty the panel has no use for.
  public static func events(fromLine line: String) -> [AgentStreamEvent] {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let value = JSONValue.parse(trimmed),
      let type = value["type"]?.stringValue
    else { return [] }

    switch type {
    case "system":
      guard value["subtype"]?.stringValue == "init",
        let session = value["session_id"]?.stringValue
      else { return [] }
      let tools = value["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
      return [.started(sessionID: session, model: value["model"]?.stringValue, tools: tools)]

    case "assistant":
      return contentBlocks(of: value).compactMap { block in
        switch block["type"]?.stringValue {
        case "text":
          guard let text = block["text"]?.stringValue,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else { return nil }
          return .text(text)
        case "tool_use":
          guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else {
            return nil
          }
          return .toolUse(AgentToolUse(id: id, name: name, input: block["input"] ?? .object([:])))
        default:
          // Thinking blocks and anything newer.
          return nil
        }
      }

    case "user":
      // The CLI reports tool results as the next "user" message; the user's
      // own messages are not echoed unless asked for.
      return contentBlocks(of: value).compactMap { block in
        guard block["type"]?.stringValue == "tool_result",
          let id = block["tool_use_id"]?.stringValue
        else { return nil }
        return .toolResult(
          toolUseID: id, isError: block["is_error"]?.boolValue ?? false,
          text: resultText(block["content"]))
      }

    case "control_request":
      guard let requestID = value["request_id"]?.stringValue, let request = value["request"] else {
        return []
      }
      let subtype = request["subtype"]?.stringValue ?? ""
      guard subtype == "can_use_tool", let tool = request["tool_name"]?.stringValue else {
        return [.unsupportedControlRequest(requestID: requestID, subtype: subtype)]
      }
      return [
        .permissionRequest(
          AgentPermissionRequest(
            requestID: requestID, toolName: tool, input: request["input"] ?? .object([:]),
            toolUseID: request["tool_use_id"]?.stringValue))
      ]

    case "control_cancel_request":
      guard let requestID = value["request_id"]?.stringValue else { return [] }
      return [.controlRequestCancelled(requestID: requestID)]

    case "result":
      return [
        .turnFinished(
          AgentTurnResult(
            isError: value["is_error"]?.boolValue ?? false,
            subtype: value["subtype"]?.stringValue ?? "",
            text: value["result"]?.stringValue,
            costUSD: value["total_cost_usd"]?.doubleValue))
      ]

    default:
      return []
    }
  }

  private static func contentBlocks(of value: JSONValue) -> [JSONValue] {
    value["message"]?["content"]?.arrayValue ?? []
  }

  /// A tool result's content is either a string or a list of text blocks.
  private static func resultText(_ content: JSONValue?) -> String {
    switch content {
    case .string(let text)?: return text
    case .array(let blocks)?:
      return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    default: return ""
    }
  }
}

/// What the panel writes to the CLI's stdin, one line each.
public enum AgentStreamEncoder {

  /// A user turn.
  public static func userMessage(_ text: String) -> String {
    line(
      .object([
        "type": .string("user"),
        "message": .object([
          "role": .string("user"),
          "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]),
      ]))
  }

  /// Let the tool call run, with exactly the input that was shown.
  public static func allow(requestID: String, input: JSONValue) -> String {
    response(
      requestID: requestID,
      .object(["behavior": .string("allow"), "updatedInput": input]))
  }

  /// Refuse the tool call. The message is what the assistant is told, so it
  /// can say so rather than retrying.
  public static func deny(requestID: String, message: String) -> String {
    response(
      requestID: requestID,
      .object(["behavior": .string("deny"), "message": .string(message)]))
  }

  /// Refuse a control request the panel does not implement.
  public static func error(requestID: String, message: String) -> String {
    line(
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("error"),
          "request_id": .string(requestID),
          "error": .string(message),
        ]),
      ]))
  }

  private static func response(requestID: String, _ body: JSONValue) -> String {
    line(
      .object([
        "type": .string("control_response"),
        "response": .object([
          "subtype": .string("success"),
          "request_id": .string(requestID),
          "response": body,
        ]),
      ]))
  }

  /// One line, newline-terminated: the framing is the newline.
  private static func line(_ value: JSONValue) -> String {
    value.jsonString() + "\n"
  }
}
