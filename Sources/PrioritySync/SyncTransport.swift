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

/// Where both apps sync unless told otherwise: the hosted server on Railway.
/// A self-hosted server goes in the field under "Use a different server".
public enum SyncServer {
  public static let defaultURL = URL(string: "https://priority-sync.up.railway.app")!

  /// A server address as typed: trimmed, and given `https://` when it has no
  /// scheme. Nil when it still isn't an http(s) URL with a host.
  public static func url(from typed: String) -> URL? {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard let url = URL(string: withScheme), url.scheme?.hasPrefix("http") == true, url.host() != nil
    else { return nil }
    return url
  }
}

/// What signing up, signing in and pairing all answer with.
public struct SyncSignedIn: Codable, Equatable, Sendable {
  public var accountId: String
  /// Nil only for an account carried over from before accounts existed.
  public var email: String?
  public var deviceId: String
  public var token: String
  public init(accountId: String, email: String?, deviceId: String, token: String) {
    self.accountId = accountId
    self.email = email
    self.deviceId = deviceId
    self.token = token
  }
}

public struct SyncPairingCode: Codable, Equatable, Sendable {
  public var code: String
  public var expiresAt: String

  public init(code: String, expiresAt: String) {
    self.code = code
    self.expiresAt = expiresAt
  }

  public var expiryDate: Date? { SyncDate.parse(expiresAt) }
}

/// `GET /v1/account`: who this device is signed in as, and every device on
/// the account.
public struct SyncAccount: Codable, Equatable, Sendable {
  public var accountId: String
  public var email: String?
  public var devices: [SyncDevice]
  public init(accountId: String, email: String?, devices: [SyncDevice]) {
    self.accountId = accountId
    self.email = email
    self.devices = devices
  }
}

public struct SyncDevice: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String?
  public var platform: String?
  public var createdAt: String
  public var lastSeenAt: String?
  /// The device asking.
  public var current: Bool

  public init(
    id: String, name: String?, platform: String?, createdAt: String, lastSeenAt: String?, current: Bool
  ) {
    self.id = id
    self.name = name
    self.platform = platform
    self.createdAt = createdAt
    self.lastSeenAt = lastSeenAt
    self.current = current
  }

  public var createdDate: Date? { SyncDate.parse(createdAt) }
  public var lastSeenDate: Date? { lastSeenAt.flatMap(SyncDate.parse) }

  /// The platform in words, for a device list.
  public var platformName: String {
    switch platform {
    case "macos": "Mac"
    case "ios": "iPhone"
    case "android": "Android"
    case let other?: other
    case nil: "Device"
    }
  }

  /// The name, or the platform when the device never gave one.
  public var displayName: String {
    guard let name, !name.isEmpty else { return platformName }
    return name
  }
}

/// The server's timestamps are RFC 3339 with up to nine fractional digits
/// (chrono's default), which `ISO8601DateFormatter` refuses past three, so
/// the fraction is cut to milliseconds before parsing.
public enum SyncDate {
  public static func parse(_ string: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: string) { return date }
    guard let dot = string.firstIndex(of: ".") else { return nil }
    let afterDot = string[string.index(after: dot)...]
    let digits = afterDot.prefix(while: \.isNumber)
    let zone = afterDot[digits.endIndex...]
    let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string[..<dot] + "." + millis + zone)
  }
}

/// What a device needs to talk to the server, kept outside the database: in
/// the Keychain on Apple platforms.
public struct SyncCredentials: Codable, Equatable, Sendable {
  public var serverURL: URL
  public var deviceId: String
  public var token: String
  public var accountId: String?
  public var email: String?
  /// The server refused the token: signed out from another device, or the
  /// account deleted. Kept rather than cleared, so the sign-in form can offer
  /// the same email and server again.
  public var isSignedOut: Bool

  public init(
    serverURL: URL, deviceId: String, token: String, accountId: String? = nil, email: String? = nil,
    isSignedOut: Bool = false
  ) {
    self.serverURL = serverURL
    self.deviceId = deviceId
    self.token = token
    self.accountId = accountId
    self.email = email
    self.isSignedOut = isSignedOut
  }

  public init(serverURL: URL, signedIn: SyncSignedIn) {
    self.init(
      serverURL: serverURL, deviceId: signedIn.deviceId, token: signedIn.token,
      accountId: signedIn.accountId, email: signedIn.email)
  }

  // An item saved before accounts has no account, email or signed-out flag.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serverURL = try container.decode(URL.self, forKey: .serverURL)
    deviceId = try container.decode(String.self, forKey: .deviceId)
    token = try container.decode(String.self, forKey: .token)
    accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
    email = try container.decodeIfPresent(String.self, forKey: .email)
    isSignedOut = try container.decodeIfPresent(Bool.self, forKey: .isSignedOut) ?? false
  }
}

public protocol SyncTransport: Sendable {
  func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse
  func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesResponse
}

public enum SyncError: LocalizedError, Equatable {
  /// The server said no; `message` is its `{"error": "..."}` text.
  case server(status: Int, message: String)
  /// The device's token is gone: signed out elsewhere, or the account deleted.
  case unauthorized
  case notPaired
  /// Something the app caught before asking the server.
  case invalid(String)

  /// The one 401 that is about a password rather than the token.
  static let wrongPasswordMessage = "wrong email or password"

  public var errorDescription: String? {
    switch self {
    case .server(let status, let message):
      return message.isEmpty ? "The sync server answered \(status)." : Self.sentence(message)
    case .unauthorized: return "Signed out. Sign in again to keep syncing."
    case .notPaired: return "This device isn't signed in to sync."
    case .invalid(let message): return message
    }
  }

  /// The server writes lowercase fragments ("wrong email or password"); the
  /// apps show sentences.
  static func sentence(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return trimmed }
    let capitalised = first.uppercased() + trimmed.dropFirst()
    return [".", "!", "?"].contains(capitalised.last) ? capitalised : capitalised + "."
  }
}

/// The transport over HTTPS, and the account routes beside it.
public struct HTTPSyncTransport: SyncTransport {
  public let credentials: SyncCredentials
  let session: URLSession

  public init(credentials: SyncCredentials, session: URLSession = .shared) {
    self.credentials = credentials
    self.session = session
  }

  public func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse {
    try await send(authorized("v1/push", body: ["changes": changes]))
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
    try await send(authorized("v1/pairing-codes", body: [String: String]()))
  }

  /// Forgets this device's token on the server.
  public func signOut() async throws {
    let _: SyncOK = try await send(authorized("v1/sign-out", body: [String: String]()))
  }

  /// Who this device is signed in as, and the account's devices.
  public func account() async throws -> SyncAccount {
    try await send(authorized("v1/account"))
  }

  /// Deletes the account, its rows and its devices. The password is asked
  /// for again so a device left unlocked can't wipe the account.
  public func deleteAccount(password: String) async throws {
    let _: SyncOK = try await send(authorized("v1/account/delete", body: ["password": password]))
  }

  /// Makes an account and signs this device in to it.
  public static func signUp(
    serverURL: URL, email: String, password: String, deviceName: String, platform: String,
    session: URLSession = .shared
  ) async throws -> SyncCredentials {
    try await signIn(
      path: "v1/accounts", serverURL: serverURL, email: email, password: password,
      deviceName: deviceName, platform: platform, session: session)
  }

  /// Signs this device in to an existing account.
  public static func signIn(
    serverURL: URL, email: String, password: String, deviceName: String, platform: String,
    session: URLSession = .shared
  ) async throws -> SyncCredentials {
    try await signIn(
      path: "v1/sessions", serverURL: serverURL, email: email, password: password,
      deviceName: deviceName, platform: platform, session: session)
  }

  private static func signIn(
    path: String, serverURL: URL, email: String, password: String, deviceName: String, platform: String,
    session: URLSession
  ) async throws -> SyncCredentials {
    let body = ["email": email, "password": password, "deviceName": deviceName, "platform": platform]
    let signedIn: SyncSignedIn = try await send(
      post(serverURL.appending(path: path), body: body), session: session, authenticated: false)
    return SyncCredentials(serverURL: serverURL, signedIn: signedIn)
  }

  /// Joins the account of the device that minted `code`.
  public static func pair(
    serverURL: URL, code: String, deviceName: String, platform: String, session: URLSession = .shared
  ) async throws -> SyncCredentials {
    let body = ["code": code, "deviceName": deviceName, "platform": platform]
    let signedIn: SyncSignedIn = try await send(
      post(serverURL.appending(path: "v1/pair"), body: body), session: session, authenticated: false)
    return SyncCredentials(serverURL: serverURL, signedIn: signedIn)
  }

  private static func post(_ url: URL, body: some Encodable) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  private func authorized(_ path: String) -> URLRequest {
    var request = URLRequest(url: credentials.serverURL.appending(path: path))
    request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func authorized(_ path: String, body: some Encodable) throws -> URLRequest {
    var request = authorized(path)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
    try await Self.send(request, session: session, authenticated: true)
  }

  /// Sends a request and decodes the answer. A refusal carries the server's
  /// own `{"error": "..."}` message. A 401 on a device route means the token
  /// is gone, except the one saying the password was wrong (deleting an
  /// account asks for it again).
  private static func send<T: Decodable>(
    _ request: URLRequest, session: URLSession, authenticated: Bool
  ) async throws -> T {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let message = (try? JSONDecoder().decode(SyncErrorBody.self, from: data))?.error ?? ""
      if status == 401, authenticated, message != SyncError.wrongPasswordMessage {
        throw SyncError.unauthorized
      }
      throw SyncError.server(status: status, message: message)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}

private struct SyncErrorBody: Decodable {
  var error: String
}

/// `{"ok": true}`, or anything else: only the status matters.
private struct SyncOK: Decodable {}
