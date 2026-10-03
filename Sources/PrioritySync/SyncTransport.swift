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

/// Where both apps sync unless told otherwise: the hosted server on Railway,
/// and the Supabase project whose accounts it trusts. A self-hosted server
/// goes in the field under "Use a different server"; it has to trust the same
/// Supabase project, since that is who the apps sign in with.
public enum SyncServer {
  public static let defaultURL = URL(string: "https://takt-sync.up.railway.app")!

  /// Where the default was before the product was renamed from Priority to
  /// Takt: the same server under its old address. A device signed in there is
  /// signed in to the default, not to a server of its own, so it is moved
  /// along with it rather than left on an address that may not last.
  public static let legacyDefaultURLs = [URL(string: "https://priority-sync.up.railway.app")!]

  /// `url`, or the default if `url` is one of its old addresses.
  public static func current(_ url: URL) -> URL {
    legacyDefaultURLs.contains(url) ? defaultURL : url
  }

  /// The Supabase project accounts live in. The publishable key is meant to
  /// ship in apps: it names the project and grants nothing a signed-out
  /// visitor couldn't already do.
  public static let supabaseURL = URL(string: "https://rsckzmldfpfjdrvulwke.supabase.co")!
  public static let supabasePublishableKey = "sb_publishable_htC171zOquUGx7bBi8MrIQ_ZuIdqL5U"

  /// Where Supabase sends the browser back to after Google or Apple on the
  /// web, and where the links in its emails (confirming an address, resetting
  /// a password) open the app. It must be on the project's allowed redirect
  /// URLs.
  public static let authCallbackURL = URL(string: "takt://auth-callback")!

  /// Whether `url` is Supabase coming back to the app.
  public static func isAuthCallback(_ url: URL) -> Bool {
    url.scheme == authCallbackURL.scheme && url.host() == authCallbackURL.host()
  }

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

/// What a device remembers about its sync sign-in, kept outside the database:
/// in the Keychain on Apple platforms. The secret itself, the Supabase
/// session, is kept by the Supabase client in an item of its own.
public struct SyncCredentials: Codable, Equatable, Sendable {
  public var serverURL: URL
  public var deviceId: String
  public var accountId: String?
  public var email: String?
  /// Supabase refused to refresh the session: signed out from elsewhere, the
  /// password changed, or the account deleted. Kept rather than cleared, so
  /// the sign-in form can offer the same email and server again.
  public var isSignedOut: Bool
  /// Saved before accounts moved to Supabase, with a token from the old
  /// server that no server accepts now. Read, never written.
  public private(set) var hasLegacyToken = false

  public init(
    serverURL: URL, deviceId: String, accountId: String? = nil, email: String? = nil, isSignedOut: Bool = false
  ) {
    self.serverURL = serverURL
    self.deviceId = deviceId
    self.accountId = accountId
    self.email = email
    self.isSignedOut = isSignedOut
  }

  private enum CodingKeys: String, CodingKey {
    case serverURL, deviceId, accountId, email, isSignedOut, token
  }

  // An item saved by an older build may hold a token, and may lack the
  // account, the email and the signed-out flag.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serverURL = SyncServer.current(try container.decode(URL.self, forKey: .serverURL))
    deviceId = try container.decode(String.self, forKey: .deviceId)
    accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
    email = try container.decodeIfPresent(String.self, forKey: .email)
    isSignedOut = try container.decodeIfPresent(Bool.self, forKey: .isSignedOut) ?? false
    hasLegacyToken = try container.decodeIfPresent(String.self, forKey: .token) != nil
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(serverURL, forKey: .serverURL)
    try container.encode(deviceId, forKey: .deviceId)
    try container.encodeIfPresent(accountId, forKey: .accountId)
    try container.encodeIfPresent(email, forKey: .email)
    try container.encode(isSignedOut, forKey: .isSignedOut)
  }
}

public protocol SyncTransport: Sendable {
  func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse
  func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesResponse
}

/// Where the transport gets the access token every request carries: the
/// Supabase client in the apps (`SupabaseSyncAuth`), a fake in tests.
public protocol SyncAccessTokenProvider: Sendable {
  /// A token good for now: the stored one, or a refreshed one if it has
  /// expired. Throws `SyncError.unauthorized` when there is no session left.
  func accessToken() async throws -> String
  /// A new token, whether or not the old one looked expired, because the
  /// server refused it. Throws `SyncError.unauthorized` when Supabase refuses
  /// the refresh, and anything else (offline, say) as it is.
  func refreshedAccessToken() async throws -> String
}

public enum SyncError: LocalizedError, Equatable {
  /// The server said no; `message` is its `{"error": "..."}` text.
  case server(status: Int, message: String)
  /// The session is gone: signed out elsewhere, or the account deleted.
  case unauthorized
  case notPaired
  /// Something the app caught before asking anyone.
  case invalid(String)
  /// The person closed the sign-in window. Not worth a message.
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .server(let status, let message):
      return message.isEmpty ? "The sync server answered \(status)." : Self.sentence(message)
    case .unauthorized: return "Signed out. Sign in again to keep syncing."
    case .notPaired: return "This device isn't signed in to sync."
    case .invalid(let message): return message
    case .cancelled: return "Sign-in was cancelled."
    }
  }

  /// The server writes lowercase fragments; the apps show sentences.
  static func sentence(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return trimmed }
    let capitalised = first.uppercased() + trimmed.dropFirst()
    return [".", "!", "?"].contains(capitalised.last) ? capitalised : capitalised + "."
  }
}

/// The transport over HTTPS, and the account routes beside it.
///
/// Every request carries `Authorization: Bearer <Supabase access token>` and
/// `X-Priority-Device: <device id>`. The token is asked for before each
/// request, so an expired one is refreshed first. A `401` all the same means
/// the server disagrees, so the token is refreshed once and the request sent
/// again. Only a refused refresh, or a second `401`, is
/// `SyncError.unauthorized`.
public struct HTTPSyncTransport: SyncTransport {
  public static let deviceHeader = "X-Priority-Device"

  public let serverURL: URL
  public let deviceId: String
  let tokens: any SyncAccessTokenProvider
  let session: URLSession

  public init(
    serverURL: URL, deviceId: String, tokens: any SyncAccessTokenProvider, session: URLSession = .shared
  ) {
    self.serverURL = serverURL
    self.deviceId = deviceId
    self.tokens = tokens
    self.session = session
  }

  public func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse {
    try await send(post("v1/push", body: ["changes": changes]))
  }

  public func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesResponse {
    var components = URLComponents(url: serverURL.appending(path: "v1/changes"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "since", value: String(cursor)),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "wait", value: String(wait)),
    ]
    var request = URLRequest(url: components.url!)
    // A long-poll holds the request open on purpose.
    request.timeoutInterval = TimeInterval(wait + 30)
    return try await send(request)
  }

  /// Records this device on the account. Sent after every sign-in.
  public func registerDevice(name: String, platform: String) async throws {
    let body = ["id": deviceId, "name": name, "platform": platform]
    let _: SyncOK = try await send(post("v1/devices", body: body))
  }

  /// Takes this device off the account's list.
  public func signOut() async throws {
    let _: SyncOK = try await send(post("v1/sign-out", body: [String: String]()))
  }

  /// Who this device is signed in as, and the account's devices.
  public func account() async throws -> SyncAccount {
    try await send(URLRequest(url: serverURL.appending(path: "v1/account")))
  }

  /// Deletes the account: its rows, its devices and the Supabase user. The
  /// apps ask the person to confirm first.
  public func deleteAccount() async throws {
    let _: SyncOK = try await send(post("v1/account/delete", body: [String: String]()))
  }

  private func post(_ path: String, body: some Encodable) throws -> URLRequest {
    var request = URLRequest(url: serverURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  /// Sends `request` with a token, and once more with a refreshed one if the
  /// server refuses the first. A refusal carries the server's own
  /// `{"error": "..."}` message.
  private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
    var (data, status) = try await send(request, token: tokens.accessToken())
    if status == 401 {
      (data, status) = try await send(request, token: tokens.refreshedAccessToken())
      if status == 401 { throw SyncError.unauthorized }
    }
    guard (200..<300).contains(status) else {
      let message = (try? JSONDecoder().decode(SyncErrorBody.self, from: data))?.error ?? ""
      throw SyncError.server(status: status, message: message)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func send(_ request: URLRequest, token: String) async throws -> (Data, Int) {
    var request = request
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(deviceId, forHTTPHeaderField: Self.deviceHeader)
    let (data, response) = try await session.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}

private struct SyncErrorBody: Decodable {
  var error: String
}

/// `{"ok": true}`, or anything else: only the status matters.
private struct SyncOK: Decodable {}
