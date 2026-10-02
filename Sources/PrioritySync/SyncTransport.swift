import Foundation
import PriorityWorkspace

// The wire shapes from `docs/sync.md`, and the one thing that sends them.

public struct SyncPushChange: Codable, Equatable, Sendable {
  public var table: String
  public var id: String
  public var op: String
  public var hlc: String
  public var values: [String: SyncValue]?

  public init(table: String, id: String, op: String, hlc: String, values: [String: SyncValue]?) {
    self.table = table
    self.id = id
    self.op = op
    self.hlc = hlc
    self.values = values
  }
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
  public var accepted: Int
  public var cursor: Int64
  public init(accepted: Int, cursor: Int64) {
    self.accepted = accepted
    self.cursor = cursor
  }
}

public struct SyncChangesResponse: Codable, Equatable, Sendable {
  public var rows: [SyncIncomingRow]
  public var cursor: Int64
  public var hasMore: Bool
  public init(rows: [SyncIncomingRow], cursor: Int64, hasMore: Bool) {
    self.rows = rows
    self.cursor = cursor
    self.hasMore = hasMore
  }
}

public struct SyncPairing: Codable, Equatable, Sendable {
  public var deviceId: String
  public var token: String
  public init(deviceId: String, token: String) {
    self.deviceId = deviceId
    self.token = token
  }
}

public struct SyncPairingCode: Codable, Equatable, Sendable {
  public var code: String
  public var expiresAt: String
}

/// What a device needs to talk to the server, kept outside the database: in
/// the Keychain on Apple platforms.
public struct SyncCredentials: Codable, Equatable, Sendable {
  public var serverURL: URL
  public var deviceId: String
  public var token: String
  public init(serverURL: URL, deviceId: String, token: String) {
    self.serverURL = serverURL
    self.deviceId = deviceId
    self.token = token
  }
}

public protocol SyncTransport: Sendable {
  func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse
  func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesResponse
}

public enum SyncError: LocalizedError, Equatable {
  case server(status: Int, message: String)
  case unauthorized
  case notPaired

  public var errorDescription: String? {
    switch self {
    case .server(let status, let message): return "The sync server answered \(status): \(message)"
    case .unauthorized: return "The sync server no longer recognises this device. Pair it again."
    case .notPaired: return "This device is not paired with a sync server."
    }
  }
}

/// The transport over HTTPS.
public struct HTTPSyncTransport: SyncTransport {
  public let credentials: SyncCredentials
  let session: URLSession

  public init(credentials: SyncCredentials, session: URLSession = .shared) {
    self.credentials = credentials
    self.session = session
  }

  public func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse {
    var request = authorized("v1/push")
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(["changes": changes])
    return try await send(request)
  }

  public func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesResponse {
    var components = URLComponents(
      url: credentials.serverURL.appending(path: "v1/changes"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "since", value: String(cursor)),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "wait", value: String(wait)),
    ]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
    // A long-poll holds the request open on purpose.
    request.timeoutInterval = TimeInterval(wait + 30)
    return try await send(request)
  }

  /// Asks the server for a one-time code another device can pair with.
  public func createPairingCode() async throws -> SyncPairingCode {
    var request = authorized("v1/pairing-codes")
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    return try await send(request)
  }

  /// Pairs a new device, with either a code from a paired device or the
  /// server's admin token.
  public static func pair(
    serverURL: URL, code: String? = nil, adminToken: String? = nil, deviceName: String, platform: String,
    session: URLSession = .shared
  ) async throws -> SyncCredentials {
    var request = URLRequest(url: serverURL.appending(path: "v1/pair"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body = ["deviceName": deviceName, "platform": platform]
    if let code { body["code"] = code }
    if let adminToken { body["adminToken"] = adminToken }
    request.httpBody = try JSONEncoder().encode(body)
    let pairing: SyncPairing = try await send(request, session: session)
    return SyncCredentials(serverURL: serverURL, deviceId: pairing.deviceId, token: pairing.token)
  }

  private func authorized(_ path: String) -> URLRequest {
    var request = URLRequest(url: credentials.serverURL.appending(path: path))
    request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
    try await Self.send(request, session: session)
  }

  private static func send<T: Decodable>(_ request: URLRequest, session: URLSession) async throws -> T {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 { throw SyncError.unauthorized }
    guard (200..<300).contains(status) else {
      throw SyncError.server(status: status, message: String(bytes: data.prefix(300), encoding: .utf8) ?? "")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}
