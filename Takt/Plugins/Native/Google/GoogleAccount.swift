import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// The scopes Priority asks Google for, one constant per capability.
enum GoogleAPIScope {
  static let calendarEvents = "https://www.googleapis.com/auth/calendar.events"
  static let calendarReadonly = "https://www.googleapis.com/auth/calendar.readonly"
  static let tasks = "https://www.googleapis.com/auth/tasks"

  static let calendar: Set<String> = [calendarEvents, calendarReadonly]
  static let taskLists: Set<String> = [tasks]
}

/// One Google sign-in, shared by every Google integration.
///
/// Calendar used to own the whole OAuth dance — client ID, PKCE, loopback
/// receiver, keychain item and refresh — and adding Tasks beside it would have
/// meant a second copy of all of it and a second trip through the browser for
/// the same account. So the dance moved here and the integrations became
/// callers: they declare the scopes they need, ask for an access token, and
/// get told to send the user back through consent when a scope is missing.
///
/// Scopes accumulate. Signing in asks for everything any registered
/// integration wants, plus `include_granted_scopes`, so switching Tasks on
/// after Calendar widens the same grant rather than replacing it.
@MainActor
@Observable final class GoogleAccount {
  /// The OAuth client ID, from a Desktop app credential in the user's own
  /// Google Cloud project. Empty means no Google integration can run at all.
  var clientID: String {
    didSet {
      let normalized = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard normalized != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
      defaults.set(normalized, forKey: Self.clientIDDefaultsKey)
      refreshAuthenticationState()
    }
  }

  private(set) var isAuthenticating = false
  private(set) var isAuthenticated = false
  private(set) var statusDescription = "Set a Google OAuth client ID to connect an account."
  /// The scopes the stored token actually carries, so a settings page can say
  /// which integrations the current sign-in covers.
  private(set) var grantedScopes: Set<String> = []

  var hasClientConfiguration: Bool { !normalizedClientID.isEmpty }

  private static let clientIDDefaultsKey = "googleOAuthClientID"
  /// Where the client ID lived when Calendar was the only Google integration.
  private static let legacyCalendarClientIDDefaultsKey = "googleCalendarOAuthClientID"
  private static let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  /// How long before expiry a token is treated as spent. A request that starts
  /// inside this window would otherwise arrive at Google already stale.
  private static let refreshLeeway: TimeInterval = 60

  private let session: URLSession
  private let defaults: UserDefaults
  private let tokenStore: GoogleOAuthTokenStore
  private let legacyTokenStore: GoogleOAuthTokenStore?
  private let makeCallbackReceiver: () -> GoogleOAuthLoopbackReceiver
  private var tokenPayload: GoogleOAuthTokenPayload?
  private var hasLoadedStoredToken = false
  /// Scopes asked for at sign-in: the union of what every registered
  /// integration declared, so one consent covers all of them.
  private var requestedScopes: Set<String> = []

  private var normalizedClientID: String {
    clientID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  init(
    session: URLSession = .shared,
    defaults: UserDefaults = .standard,
    tokenStore: GoogleOAuthTokenStore = GoogleOAuthTokenStore(),
    legacyTokenStore: GoogleOAuthTokenStore? = GoogleOAuthTokenStore(
      account: GoogleOAuthTokenStore.legacyCalendarAccount),
    makeCallbackReceiver: @escaping () -> GoogleOAuthLoopbackReceiver = {
      GoogleOAuthLoopbackReceiver()
    }
  ) {
    self.session = session
    self.defaults = defaults
    self.tokenStore = tokenStore
    self.legacyTokenStore = legacyTokenStore
    self.makeCallbackReceiver = makeCallbackReceiver
    // A client ID configured back when this was the Calendar plugin's own
    // setting still identifies the same Google project, so it carries over
    // rather than making the user paste it again.
    let stored = defaults.string(forKey: Self.clientIDDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let legacy = defaults.string(forKey: Self.legacyCalendarClientIDDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.clientID = (stored?.isEmpty == false ? stored : legacy) ?? ""
    if stored?.isEmpty != false, let legacy, !legacy.isEmpty {
      defaults.set(legacy, forKey: Self.clientIDDefaultsKey)
    }
    updateStatusDescription()
  }

  /// Declares what an integration needs. Called once per integration at
  /// construction; the union is what the next sign-in asks for.
  func requireScopes(_ scopes: Set<String>) {
    requestedScopes.formUnion(scopes)
  }

  /// Whether the current sign-in covers a capability. False either because
  /// nobody has signed in or because they signed in before that integration
  /// existed — the settings page tells those two apart by also reading
  /// `isAuthenticated`.
  ///
  /// A pure read, deliberately: this is called from SwiftUI view bodies, and
  /// loading the token here would mean publishing observable changes during a
  /// view update. Surfaces that need the answer to be current call `prepare()`
  /// first, from a `task` or an appearance.
  func hasGrantedScopes(_ scopes: Set<String>) -> Bool {
    guard isAuthenticated else { return false }
    return scopes.isSubset(of: grantedScopes)
  }

  /// Reads the stored sign-in, once. Called when a surface is about to show
  /// or use the authentication state, rather than at launch — see
  /// `loadStoredTokenIfNeeded`.
  func prepare() {
    loadStoredTokenIfNeeded()
  }

  /// A usable access token, refreshed if it is spent.
  ///
  /// `requiring` is checked before the network call so a missing scope reads
  /// as "sign in again" rather than as a Google permission error three frames
  /// further down.
  func accessToken(requiring scopes: Set<String>, service: String) async throws -> String {
    guard !normalizedClientID.isEmpty else { throw GoogleAccountError.missingClientID }
    loadStoredTokenIfNeeded()
    guard var payload = tokenPayload else { throw GoogleAccountError.authenticationRequired }
    guard payload.clientID == normalizedClientID else {
      // The client ID changed under the token: it belongs to another project
      // and will be rejected, so drop it rather than send it.
      disconnect()
      throw GoogleAccountError.authenticationRequired
    }
    guard scopes.isSubset(of: payload.scopes) else {
      throw GoogleAccountError.missingScope(service: service)
    }

    if payload.expiryDate > Date().addingTimeInterval(Self.refreshLeeway) {
      return payload.accessToken
    }

    let refreshed = try await refreshAccessToken(refreshToken: payload.refreshToken)
    payload = GoogleOAuthTokenPayload(
      accessToken: refreshed.accessToken,
      refreshToken: payload.refreshToken,
      expiryDate: Date().addingTimeInterval(TimeInterval(refreshed.expiresIn)),
      grantedScopes: refreshed.scope ?? payload.grantedScopes,
      clientID: normalizedClientID)
    store(payload)
    return payload.accessToken
  }

  /// Sends the user through Google's consent screen and keeps what comes back.
  func beginAuthentication() async throws {
    guard !normalizedClientID.isEmpty else { throw GoogleAccountError.missingClientID }
    guard !isAuthenticating else { return }
    isAuthenticating = true
    updateStatusDescription()
    defer {
      isAuthenticating = false
      updateStatusDescription()
    }

    let state = try Self.makeRandomBase64URLString(byteCount: 32)
    let verifier = try Self.makeRandomBase64URLString(byteCount: 64)
    let challenge = Self.makePKCECodeChallenge(from: verifier)
    let receiver = makeCallbackReceiver()

    let redirectURI = try await receiver.start()
    defer { receiver.stop() }

    NSWorkspace.shared.open(
      try makeAuthorizationURL(redirectURI: redirectURI, state: state, codeChallenge: challenge))
    let callbackURL = try await receiver.waitForCallback(timeout: 180)
    let code = try Self.extractAuthorizationCode(from: callbackURL, expectedState: state)
    let response = try await exchangeAuthorizationCode(
      authorizationCode: code, redirectURI: redirectURI, codeVerifier: verifier)
    try storeTokenResponse(response)
  }

  /// Forgets the sign-in. Also clears the pre-shared-account keychain item, so
  /// "sign out" does not leave a token behind under the old name.
  func disconnect() {
    tokenPayload = nil
    grantedScopes = []
    tokenStore.clear()
    legacyTokenStore?.clear()
    isAuthenticated = false
    updateStatusDescription()
  }

  /// What an integration calls on a 401: the token was accepted at refresh
  /// time and rejected at use, which means it was revoked at Google's end.
  func invalidateAfterUnauthorized() {
    disconnect()
  }

  // MARK: - Token plumbing

  /// The keychain is read on first use rather than at launch: a token stored
  /// by a differently-signed build prompts for a macOS password, and that
  /// prompt should be the consequence of asking for a Google action.
  private func loadStoredTokenIfNeeded() {
    guard !hasLoadedStoredToken else { return }
    hasLoadedStoredToken = true
    // The Calendar-only token is adopted as the shared one, so an existing
    // sign-in survives. Its scopes come with it, which is what later tells
    // Tasks that this grant predates it.
    if let existing = tokenStore.load() {
      tokenPayload = existing
    } else if let legacy = legacyTokenStore?.load() {
      tokenPayload = legacy
      tokenStore.save(legacy)
      legacyTokenStore?.clear()
    }
    refreshAuthenticationState()
  }

  private func store(_ payload: GoogleOAuthTokenPayload) {
    tokenPayload = payload
    tokenStore.save(payload)
    refreshAuthenticationState()
  }

  private func refreshAuthenticationState() {
    let payload = tokenPayload
    let usable =
      payload.map { $0.clientID == normalizedClientID && !$0.refreshToken.isEmpty } ?? false
    isAuthenticated = usable && !normalizedClientID.isEmpty
    grantedScopes = isAuthenticated ? (payload?.scopes ?? []) : []
    updateStatusDescription()
  }

  private func updateStatusDescription() {
    if normalizedClientID.isEmpty {
      statusDescription = "No OAuth client ID. Google integrations are unavailable."
      return
    }
    if isAuthenticating {
      statusDescription = "Signing in with Google…"
      return
    }
    statusDescription = isAuthenticated ? "Signed in to Google." : "OAuth configured. Sign in required."
  }

  private func makeAuthorizationURL(redirectURI: URL, state: String, codeChallenge: String) throws
    -> URL
  {
    // Sorted so the URL is stable between runs, which makes a failed sign-in
    // something you can compare rather than something you have to re-read.
    let scope = requestedScopes.sorted().joined(separator: " ")
    var components = URLComponents(url: Self.authorizationURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      .init(name: "client_id", value: normalizedClientID),
      .init(name: "redirect_uri", value: redirectURI.absoluteString),
      .init(name: "response_type", value: "code"),
      .init(name: "scope", value: scope),
      .init(name: "access_type", value: "offline"),
      .init(name: "prompt", value: "consent"),
      .init(name: "include_granted_scopes", value: "true"),
      .init(name: "code_challenge", value: codeChallenge),
      .init(name: "code_challenge_method", value: "S256"),
      .init(name: "state", value: state),
    ]
    guard let url = components?.url else { throw GoogleAccountError.invalidAuthorizationURL }
    return url
  }

  private func exchangeAuthorizationCode(
    authorizationCode: String, redirectURI: URL, codeVerifier: String
  ) async throws -> GoogleOAuthTokenResponse {
    let data = try await postForm([
      ("code", authorizationCode),
      ("client_id", normalizedClientID),
      ("code_verifier", codeVerifier),
      ("redirect_uri", redirectURI.absoluteString),
      ("grant_type", "authorization_code"),
    ])
    return try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
  }

  private func refreshAccessToken(refreshToken: String) async throws -> GoogleOAuthRefreshResponse {
    let data = try await postForm([
      ("client_id", normalizedClientID),
      ("refresh_token", refreshToken),
      ("grant_type", "refresh_token"),
    ])
    return try JSONDecoder().decode(GoogleOAuthRefreshResponse.self, from: data)
  }

  private func postForm(_ pairs: [(String, String)]) async throws -> Data {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formEncodedData(pairs)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw GoogleAccountError.invalidResponse }
    guard (200...299).contains(http.statusCode) else {
      throw GoogleAccountError.tokenEndpoint(
        String(data: data, encoding: .utf8) ?? "Unknown OAuth error.")
    }
    return data
  }

  private func storeTokenResponse(_ response: GoogleOAuthTokenResponse) throws {
    // Google returns a refresh token on first consent only; a re-authentication
    // that widens scopes may omit it, and dropping the old one would sign the
    // user out the next time the access token expired.
    guard let refreshToken = response.refreshToken ?? tokenPayload?.refreshToken,
      !refreshToken.isEmpty
    else {
      refreshAuthenticationState()
      throw GoogleAccountError.missingRefreshToken
    }
    store(
      GoogleOAuthTokenPayload(
        accessToken: response.accessToken,
        refreshToken: refreshToken,
        expiryDate: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
        grantedScopes: response.scope ?? requestedScopes.sorted().joined(separator: " "),
        clientID: normalizedClientID))
  }

  // MARK: - PKCE and encoding

  /// Callback parsing is static and internal so it can be tested without a
  /// browser: it is the one part of the dance an attacker can reach, since
  /// anything able to hit the loopback port can call it.
  static func extractAuthorizationCode(from callbackURL: URL, expectedState: String) throws
    -> String
  {
    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
      throw GoogleAccountError.invalidCallback
    }
    // First occurrence wins rather than `Dictionary(uniqueKeysWithValues:)`,
    // which traps on a duplicate key — a repeated `code` must not crash sign-in.
    let items = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
      if result[item.name] == nil { result[item.name] = item.value ?? "" }
    }
    if let error = items["error"], !error.isEmpty {
      throw GoogleAccountError.authorizationDenied(error)
    }
    guard items["state"] == expectedState else { throw GoogleAccountError.invalidState }
    guard let code = items["code"], !code.isEmpty else { throw GoogleAccountError.invalidCallback }
    return code
  }

  static func makePKCECodeChallenge(from verifier: String) -> String {
    base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func makeRandomBase64URLString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: max(byteCount, 1))
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw GoogleAccountError.randomGenerationFailed
    }
    return base64URLEncode(Data(bytes))
  }

  static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func formEncodedData(_ pairs: [(String, String)]) -> Data? {
    pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }
      .joined(separator: "&")
      .data(using: .utf8)
  }

  private static func percentEncode(_ value: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)!
  }
}

struct GoogleOAuthTokenResponse: Decodable {
  let accessToken: String
  let expiresIn: Int
  let refreshToken: String?
  let scope: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
  }
}

struct GoogleOAuthRefreshResponse: Decodable {
  let accessToken: String
  let expiresIn: Int
  let scope: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case scope
  }
}

enum GoogleAccountError: LocalizedError, Equatable {
  case missingClientID
  case invalidAuthorizationURL
  case invalidCallback
  case invalidState
  case authorizationDenied(String)
  case authenticationRequired
  case missingScope(service: String)
  case missingRefreshToken
  case invalidResponse
  case tokenEndpoint(String)
  case randomGenerationFailed

  var errorDescription: String? {
    switch self {
    case .missingClientID:
      return "Set a Google OAuth client ID first."
    case .invalidAuthorizationURL:
      return "Could not build the Google authorization URL."
    case .invalidCallback:
      return "The Google sign-in callback was invalid."
    case .invalidState:
      return "Google sign-in state mismatch. Try again."
    case .authorizationDenied(let reason):
      return "Google authorization failed: \(reason)"
    case .authenticationRequired:
      return "Sign in to Google in Preferences."
    case .missingScope(let service):
      return "This Google sign-in predates \(service). Sign in again to grant access to it."
    case .missingRefreshToken:
      return "Google did not return a refresh token. Sign in again and grant offline access."
    case .invalidResponse:
      return "Received an invalid response from Google."
    case .tokenEndpoint(let message):
      return "Google OAuth error: \(message)"
    case .randomGenerationFailed:
      return "Could not generate secure OAuth parameters."
    }
  }
}
