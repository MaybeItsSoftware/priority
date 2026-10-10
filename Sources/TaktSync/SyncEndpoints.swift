import Foundation
import TaktRustCore

/// Where a device syncs: the sync server, and the Supabase project whose
/// accounts that server trusts. Takt's own (`hosted`) unless "Use a different
/// server" names a self-hosted pair; see `docs/self-hosting.md`.
///
/// The three travel together because they only work together: the server
/// checks every access token against one Supabase project, so signing in to
/// another project gets a token it refuses.
public struct SyncEndpoints: Codable, Equatable, Sendable {
  public var serverURL: URL
  public var supabaseURL: URL
  /// The project's publishable key (`sb_publishable_…`) or legacy anon key.
  /// Made to ship in apps: it names the project and grants nothing a
  /// signed-out visitor couldn't already do.
  public var supabaseKey: String

  public init(serverURL: URL, supabaseURL: URL, supabaseKey: String) {
    self.serverURL = serverURL
    self.supabaseURL = supabaseURL
    self.supabaseKey = supabaseKey
  }

  public static let hosted = SyncEndpoints(
    serverURL: SyncServer.defaultURL, supabaseURL: SyncServer.supabaseURL,
    supabaseKey: SyncServer.supabasePublishableKey)

  public var isHosted: Bool { self == .hosted }

  /// Accounts are Takt's own, whatever server holds the rows.
  public var usesHostedAccounts: Bool {
    supabaseURL == Self.hosted.supabaseURL && supabaseKey == Self.hosted.supabaseKey
  }

  /// The endpoints as typed under "Use a different server". A blank server
  /// is Takt's; a blank Supabase URL *and* key are Takt's project. Throws
  /// `SyncError.invalid` with something to show for anything else that
  /// can't be used. The Rust core's `sync_resolve_endpoints`, which Android
  /// calls too, so a typed address means the same on every device.
  public static func resolve(server: String, supabaseURL: String, supabaseKey: String) throws -> SyncEndpoints {
    let resolution = syncResolveEndpoints(
      server: server, supabaseUrl: supabaseURL, supabaseKey: supabaseKey,
      hosted: SyncEndpointsRecord(
        serverUrl: hosted.serverURL.absoluteString, supabaseUrl: hosted.supabaseURL.absoluteString,
        supabaseKey: hosted.supabaseKey))
    guard let resolved = resolution.endpoints else {
      throw SyncError.invalid(resolution.problem ?? "Those addresses can't be used.")
    }
    guard let server = URL(string: resolved.serverUrl) else {
      throw SyncError.invalid("The sync server address isn't a web address.")
    }
    guard let project = URL(string: resolved.supabaseUrl) else {
      throw SyncError.invalid("The Supabase URL isn't a web address.")
    }
    return SyncEndpoints(serverURL: server, supabaseURL: project, supabaseKey: resolved.supabaseKey)
  }

  private enum CodingKeys: String, CodingKey {
    case serverURL, supabaseURL, supabaseKey
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serverURL = SyncServer.current(try container.decode(URL.self, forKey: .serverURL))
    supabaseURL = try container.decode(URL.self, forKey: .supabaseURL)
    supabaseKey = try container.decode(String.self, forKey: .supabaseKey)
  }
}

/// Asks both halves of a self-hosted setup whether they are there before the
/// app switches to them: the sync server's `/health`, and the Supabase
/// project's `/auth/v1/settings` with the key, which Supabase's gateway
/// refuses for a wrong one.
public enum SyncEndpointCheck {
  public static func check(_ endpoints: SyncEndpoints, session: URLSession = .shared) async throws {
    try await checkServer(endpoints.serverURL, session: session)
    try await checkSupabase(endpoints.supabaseURL, key: endpoints.supabaseKey, session: session)
  }

  static func checkServer(_ server: URL, session: URLSession) async throws {
    var request = URLRequest(url: server.appending(path: "health"))
    request.timeoutInterval = 15
    let host = server.host() ?? server.absoluteString
    let (data, status) = try await fetch(request, session: session) { reason in
      "Couldn't reach the sync server at \(host): \(reason)"
    }
    guard status == 200, syncHealthIsOk(body: String(decoding: data, as: UTF8.self)) else {
      throw SyncError.invalid(
        "\(host) answered \(status) to /health, not a Takt sync server's {\"ok\":true}. Check the address.")
    }
  }

  static func checkSupabase(_ project: URL, key: String, session: URLSession) async throws {
    var request = URLRequest(url: project.appending(path: "auth/v1/settings"))
    request.timeoutInterval = 15
    request.setValue(key, forHTTPHeaderField: "apikey")
    let host = project.host() ?? project.absoluteString
    let (data, status) = try await fetch(request, session: session) { reason in
      "Couldn't reach the Supabase project at \(host): \(reason)"
    }
    switch status {
    case 200:
      guard syncBodyIsJsonObject(body: String(decoding: data, as: UTF8.self)) else {
        throw SyncError.invalid("\(host) answered, but not as a Supabase project would. Check the URL.")
      }
    case 401, 403:
      throw SyncError.invalid("Supabase refused that key. Use the project's publishable (or anon) key.")
    default:
      throw SyncError.invalid(
        "\(host) answered \(status) to /auth/v1/settings. Check that the URL is the project's own.")
    }
  }

  private static func fetch(
    _ request: URLRequest, session: URLSession, unreachable: (String) -> String
  ) async throws -> (Data, Int) {
    do {
      let (data, response) = try await session.data(for: request)
      return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    } catch {
      throw SyncError.invalid(unreachable(error.localizedDescription))
    }
  }
}
