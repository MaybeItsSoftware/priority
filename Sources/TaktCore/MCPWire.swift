import Foundation

/// A JSON value that can cross a concurrency boundary.
///
/// `[String: Any]` cannot: it is not `Sendable`, so a decoded MCP response
/// could not be handed back from the reader task that parsed it. This is the
/// smallest thing that can.
public enum JSONValue: Sendable, Hashable, Codable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unrecognised JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    switch self {
    case .int(let value): return value
    case .double(let value): return Int(value)
    default: return nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }
}

/// The wire format of an MCP stdio session: the handful of messages a client
/// has to send, and how to read what comes back.
///
/// Pure by design. `AFFiNEMCPSession` owns the process and the pipes; this owns
/// what goes down them, so the protocol can be tested without spawning
/// anything.
public enum MCPWire {
  /// The protocol revision announced at `initialize`. Servers negotiate down,
  /// so naming a version we understand is safer than echoing theirs.
  public static var protocolVersion: String { "2025-06-18" }

  public static func initializeRequest(
    id: Int,
    clientName: String,
    clientVersion: String
  ) -> JSONValue {
    request(
      id: id,
      method: "initialize",
      params: [
        "protocolVersion": .string(protocolVersion),
        "capabilities": .object([:]),
        "clientInfo": .object([
          "name": .string(clientName),
          "version": .string(clientVersion),
        ]),
      ]
    )
  }

  /// Sent after `initialize` returns. A notification, so it carries no id and
  /// gets no reply.
  public static func initializedNotification() -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"),
      "method": .string("notifications/initialized"),
    ])
  }

  public static func toolCallRequest(
    id: Int,
    name: String,
    arguments: [String: JSONValue]
  ) -> JSONValue {
    request(
      id: id,
      method: "tools/call",
      params: [
        "name": .string(name),
        "arguments": .object(arguments),
      ]
    )
  }

  private static func request(
    id: Int,
    method: String,
    params: [String: JSONValue]
  ) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"),
      "id": .int(id),
      "method": .string(method),
      "params": .object(params),
    ])
  }

  /// One framed message: JSON on a single line, newline-terminated. MCP's stdio
  /// transport is newline-delimited — no `Content-Length` headers, unlike LSP.
  public static func encode(_ message: JSONValue) throws -> Data {
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)
    return data
  }

  public enum Message: Sendable, Equatable {
    case result(id: Int, value: JSONValue)
    case failure(id: Int, code: Int, message: String)
    /// A notification, a log line, or anything else with no request waiting on
    /// it. Servers are entitled to write these at any point, so a client that
    /// treated an unparseable line as fatal would be wrong.
    case unrelated
  }

  public static func decode(line: String) -> Message {
    guard
      let data = line.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      let id = value["id"]?.intValue
    else { return .unrelated }

    if let error = value["error"]?.objectValue {
      return .failure(
        id: id,
        code: error["code"]?.intValue ?? 0,
        message: error["message"]?.stringValue ?? "Unknown error"
      )
    }

    guard let result = value["result"] else { return .unrelated }
    return .result(id: id, value: result)
  }

  /// The text a tool result carries, blocks joined by blank lines.
  ///
  /// Non-text content (images, embedded resources) is skipped rather than
  /// described — every caller here wants a string to show or to parse.
  public static func toolResultText(_ result: JSONValue) -> String {
    let blocks = result["content"]?.arrayValue ?? []
    return
      blocks
      .filter { $0["type"]?.stringValue == "text" }
      .compactMap { $0["text"]?.stringValue }
      .joined(separator: "\n\n")
  }

  /// A tool that failed reports it *inside* a successful JSON-RPC result, so a
  /// caller that only checks for `error` will read a failure as a success.
  public static func toolResultIsError(_ result: JSONValue) -> Bool {
    result["isError"]?.boolValue ?? false
  }

  /// The machine-readable half of a tool result, when the server sends one.
  /// Falls back to parsing the text block, which is where servers that predate
  /// `structuredContent` put their JSON.
  public static func structuredContent(_ result: JSONValue) -> JSONValue? {
    if let structured = result["structuredContent"], structured != .null {
      return structured
    }
    let text = toolResultText(result)
    guard
      !text.isEmpty,
      let data = text.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    return value
  }
}
