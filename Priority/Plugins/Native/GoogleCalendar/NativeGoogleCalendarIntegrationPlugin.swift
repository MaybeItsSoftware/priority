import AppKit
import CryptoKit
import Foundation
import Observation
import Security

@MainActor
@Observable final class NativeGoogleCalendarIntegrationPlugin: GoogleCalendarIntegrationPlugin
{
  let pluginIdentifier = "native.google.calendar.integration"
  let displayName = "Native Google Calendar Integration"
  let pluginDescription = "Create Google Calendar events from tasks using your Google account."

  var oauthClientID: String {
    didSet {
      let normalized = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
      defaults.set(normalized, forKey: Self.oauthClientIDDefaultsKey)
      isAuthenticated = Self.canUseTokenPayload(tokenPayload, forClientID: normalized)
      updateAuthenticationStatusDescription()
    }
  }

  var targetCalendarID: String {
    didSet {
      defaults.set(
        targetCalendarID.trimmingCharacters(in: .whitespacesAndNewlines),
        forKey: Self.targetCalendarIDDefaultsKey
      )
    }
  }

  var openCreatedEventInBrowser: Bool {
    didSet {
      defaults.set(openCreatedEventInBrowser, forKey: Self.openCreatedEventInBrowserDefaultsKey)
    }
  }

  private(set) var isAuthenticating = false
  private(set) var isAuthenticated = false
  private(set) var authenticationStatusDescription =
    "Set a Google OAuth client ID to enable Calendar event creation."

  var requiresAuthentication: Bool { !normalizedOAuthClientID.isEmpty }
  var hasOAuthClientConfiguration: Bool { !normalizedOAuthClientID.isEmpty }

  private static let oauthClientIDDefaultsKey = "googleCalendarOAuthClientID"
  private static let targetCalendarIDDefaultsKey = "googleCalendarTargetCalendarID"
  private static let openCreatedEventInBrowserDefaultsKey =
    "googleCalendarOpenCreatedEventInBrowser"
  private static let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  private static let eventDescriptionSourceName = "Priority"
  private static let oauthScope =
    "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly"

  private let defaultEventDurationMinutes: Int
  private let calendar: Calendar
  private let session: URLSession
  private let defaults: UserDefaults
  private let tokenStore: GoogleCalendarOAuthTokenStore
  private var tokenPayload: GoogleCalendarOAuthTokenPayload?
  private var hasLoadedStoredToken = false
  private var normalizedOAuthClientID: String {
    oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  init(
    defaultEventDurationMinutes: Int = 30,
    calendar: Calendar = .current,
    session: URLSession = .shared,
    defaults: UserDefaults = .standard,
    tokenStore: GoogleCalendarOAuthTokenStore = GoogleCalendarOAuthTokenStore()
  ) {
    self.defaultEventDurationMinutes = max(defaultEventDurationMinutes, 1)
    self.calendar = calendar
    self.session = session
    self.defaults = defaults
    self.tokenStore = tokenStore
    self.oauthClientID =
      defaults.string(forKey: Self.oauthClientIDDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    let storedCalendarID =
      defaults.string(forKey: Self.targetCalendarIDDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    self.targetCalendarID = storedCalendarID.isEmpty ? "primary" : storedCalendarID
    self.openCreatedEventInBrowser =
      defaults.object(forKey: Self.openCreatedEventInBrowserDefaultsKey) as? Bool ?? true
    self.tokenPayload = nil
    self.isAuthenticated = Self.canUseTokenPayload(
      tokenPayload, forClientID: normalizedOAuthClientID)
    self.updateAuthenticationStatusDescription()
  }

  func makeCreateEventURL(task: CheckvistTask, listId: String, now: Date) -> URL? {
    var components = URLComponents(string: "https://calendar.google.com/calendar/render")

    let title =
      task.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Checkvist Task #\(task.id)" : task.content

    let details = """
      Created from \(Self.eventDescriptionSourceName)
      List ID: \(listId)
      Task ID: \(task.id)
      """

    var queryItems: [URLQueryItem] = [
      .init(name: "action", value: "TEMPLATE"),
      .init(name: "text", value: title),
      .init(name: "details", value: details),
      .init(name: "ctz", value: calendar.timeZone.identifier),
    ]

    if let datesValue = eventDatesValue(task: task, now: now) {
      queryItems.append(.init(name: "dates", value: datesValue))
    }

    components?.queryItems = queryItems
    return components?.url
  }

  func createEvent(task: CheckvistTask, listId: String, now: Date) async throws
    -> GoogleCalendarEventCreationOutcome
  {
    if normalizedOAuthClientID.isEmpty {
      throw GoogleCalendarPluginError.missingOAuthClientID
    }

    let validAccessToken = try await ensureValidAccessToken()
    let createdEventURL = try await createEventWithGoogleAPI(
      accessToken: validAccessToken,
      task: task,
      listId: listId,
      now: now
    )
    let urlToOpen = openCreatedEventInBrowser ? createdEventURL : nil
    return GoogleCalendarEventCreationOutcome(urlToOpen: urlToOpen, usedGoogleCalendarAPI: true)
  }

  func beginAuthentication() async throws {
    guard !normalizedOAuthClientID.isEmpty else {
      throw GoogleCalendarPluginError.missingOAuthClientID
    }
    guard !isAuthenticating else { return }
    isAuthenticating = true
    updateAuthenticationStatusDescription()
    defer {
      isAuthenticating = false
      updateAuthenticationStatusDescription()
    }

    let state = try Self.makeOAuthState()
    let verifier = try Self.makePKCECodeVerifier()
    let challenge = Self.makePKCECodeChallenge(from: verifier)
    let callbackReceiver = GoogleOAuthLoopbackReceiver()

    let redirectURI = try await callbackReceiver.start()
    defer { callbackReceiver.stop() }

    let authorizationURL = try makeAuthorizationURL(
      redirectURI: redirectURI,
      state: state,
      codeChallenge: challenge
    )

    NSWorkspace.shared.open(authorizationURL)
    let callbackURL = try await callbackReceiver.waitForCallback(timeout: 180)
    let code = try extractAuthorizationCode(from: callbackURL, expectedState: state)
    let tokenResponse = try await exchangeAuthorizationCode(
      authorizationCode: code,
      redirectURI: redirectURI,
      codeVerifier: verifier
    )
    storeTokenResponse(tokenResponse)
  }

  func disconnectAuthentication() {
    tokenPayload = nil
    tokenStore.clear()
    isAuthenticated = false
    updateAuthenticationStatusDescription()
  }

  private func eventDatesValue(task: CheckvistTask, now: Date) -> String? {
    if let dueDate = task.dueDate {
      if hasExplicitDueTime(rawDue: task.due) {
        let end = dueDate.addingTimeInterval(Double(defaultEventDurationMinutes * 60))
        return "\(formatDateTimeUTC(dueDate))/\(formatDateTimeUTC(end))"
      }

      let startOfDay = calendar.startOfDay(for: dueDate)
      guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
        return nil
      }
      return "\(formatDateOnly(startOfDay))/\(formatDateOnly(endOfDay))"
    }

    let start = now
    let end = start.addingTimeInterval(Double(defaultEventDurationMinutes * 60))
    return "\(formatDateTimeUTC(start))/\(formatDateTimeUTC(end))"
  }

  private func hasExplicitDueTime(rawDue: String?) -> Bool {
    guard let rawDue else { return false }
    let normalized = rawDue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty, normalized != "asap" else { return false }

    if normalized.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
      return false
    }

    return normalized.contains(":")
      || normalized.contains("t")
      || normalized.contains("am")
      || normalized.contains("pm")
  }

  private func formatDateTimeUTC(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private func formatDateOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: date)
  }

  private func ensureValidAccessToken() async throws -> String {
    guard !normalizedOAuthClientID.isEmpty else {
      throw GoogleCalendarPluginError.missingOAuthClientID
    }
    loadStoredTokenIfNeeded()
    guard var payload = tokenPayload else {
      isAuthenticated = false
      updateAuthenticationStatusDescription()
      throw GoogleCalendarPluginError.authenticationRequired
    }
    guard payload.clientID == normalizedOAuthClientID else {
      disconnectAuthentication()
      throw GoogleCalendarPluginError.authenticationRequired
    }

    let refreshThreshold = Date().addingTimeInterval(60)
    if payload.expiryDate > refreshThreshold {
      return payload.accessToken
    }

    let refreshResponse = try await refreshAccessToken(refreshToken: payload.refreshToken)
    payload = GoogleCalendarOAuthTokenPayload(
      accessToken: refreshResponse.accessToken,
      refreshToken: payload.refreshToken,
      expiryDate: Date().addingTimeInterval(TimeInterval(refreshResponse.expiresIn)),
      grantedScopes: refreshResponse.scope ?? payload.grantedScopes,
      clientID: normalizedOAuthClientID
    )
    tokenPayload = payload
    tokenStore.save(payload)
    isAuthenticated = true
    updateAuthenticationStatusDescription()
    return payload.accessToken
  }

  /// Reads the keychain only after the user explicitly asks Priority to create
  /// a Calendar event. This keeps a stale or differently-signed token from
  /// prompting for a macOS password simply because the app launched.
  private func loadStoredTokenIfNeeded() {
    guard !hasLoadedStoredToken else { return }
    hasLoadedStoredToken = true
    tokenPayload = tokenStore.load()
    isAuthenticated = Self.canUseTokenPayload(tokenPayload, forClientID: normalizedOAuthClientID)
    updateAuthenticationStatusDescription()
  }

  private func createEventWithGoogleAPI(
    accessToken: String,
    task: CheckvistTask,
    listId: String,
    now: Date
  ) async throws -> URL? {
    guard let eventURL = makeEventsAPIURL() else {
      throw GoogleCalendarPluginError.invalidCalendarID
    }

    let payload = makeGoogleCalendarEventPayload(task: task, listId: listId, now: now)
    var request = URLRequest(url: eventURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw GoogleCalendarPluginError.invalidResponse
    }

    if httpResponse.statusCode == 401 {
      // Token likely expired/revoked unexpectedly: clear local state and ask for re-auth.
      disconnectAuthentication()
      throw GoogleCalendarPluginError.authenticationRequired
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown Google Calendar API error."
      throw GoogleCalendarPluginError.apiError(message)
    }

    let decoded = try JSONDecoder().decode(GoogleCalendarCreateEventResponse.self, from: data)
    if let htmlLink = decoded.htmlLink {
      return URL(string: htmlLink)
    }
    return nil
  }

  private func makeEventsAPIURL() -> URL? {
    let trimmedCalendarID = targetCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
    let calendarID = trimmedCalendarID.isEmpty ? "primary" : trimmedCalendarID
    let encodedCalendarID =
      calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    return URL(
      string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")
  }

  private func makeGoogleCalendarEventPayload(task: CheckvistTask, listId: String, now: Date)
    -> GoogleCalendarCreateEventPayload
  {
    let rawTitle = task.content.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = rawTitle.isEmpty ? "Checkvist Task #\(task.id)" : rawTitle
    let details = """
      Created from \(Self.eventDescriptionSourceName)
      List ID: \(listId)
      Task ID: \(task.id)
      """

    if let dueDate = task.dueDate {
      if hasExplicitDueTime(rawDue: task.due) {
        let end = dueDate.addingTimeInterval(Double(defaultEventDurationMinutes * 60))
        return GoogleCalendarCreateEventPayload(
          summary: title,
          description: details,
          start: .init(
            date: nil, dateTime: formatRFC3339(dueDate), timeZone: calendar.timeZone.identifier),
          end: .init(
            date: nil, dateTime: formatRFC3339(end), timeZone: calendar.timeZone.identifier)
        )
      }

      let startDateOnly = formatDateOnlyForAPI(calendar.startOfDay(for: dueDate))
      let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dueDate))
      let endDateOnly = formatDateOnlyForAPI(nextDay ?? dueDate)
      return GoogleCalendarCreateEventPayload(
        summary: title,
        description: details,
        start: .init(date: startDateOnly, dateTime: nil, timeZone: nil),
        end: .init(date: endDateOnly, dateTime: nil, timeZone: nil)
      )
    }

    let start = now
    let end = now.addingTimeInterval(Double(defaultEventDurationMinutes * 60))
    return GoogleCalendarCreateEventPayload(
      summary: title,
      description: details,
      start: .init(
        date: nil, dateTime: formatRFC3339(start), timeZone: calendar.timeZone.identifier),
      end: .init(date: nil, dateTime: formatRFC3339(end), timeZone: calendar.timeZone.identifier)
    )
  }

  private func formatDateOnlyForAPI(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private func formatRFC3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = calendar.timeZone
    return formatter.string(from: date)
  }

  private func updateAuthenticationStatusDescription() {
    if normalizedOAuthClientID.isEmpty {
      authenticationStatusDescription =
        "OAuth not configured. Calendar event creation is unavailable."
      isAuthenticated = false
      return
    }

    if isAuthenticating {
      authenticationStatusDescription = "Signing in with Google…"
      return
    }

    if isAuthenticated {
      authenticationStatusDescription = "Connected to Google Calendar API."
    } else {
      authenticationStatusDescription = "OAuth configured. Sign in required."
    }
  }

  private func makeAuthorizationURL(
    redirectURI: URL,
    state: String,
    codeChallenge: String
  ) throws -> URL {
    var components = URLComponents(url: Self.authorizationURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      .init(name: "client_id", value: normalizedOAuthClientID),
      .init(name: "redirect_uri", value: redirectURI.absoluteString),
      .init(name: "response_type", value: "code"),
      .init(name: "scope", value: Self.oauthScope),
      .init(name: "access_type", value: "offline"),
      .init(name: "prompt", value: "consent"),
      .init(name: "include_granted_scopes", value: "true"),
      .init(name: "code_challenge", value: codeChallenge),
      .init(name: "code_challenge_method", value: "S256"),
      .init(name: "state", value: state),
    ]
    guard let url = components?.url else {
      throw GoogleCalendarPluginError.invalidAuthorizationURL
    }
    return url
  }

  private func extractAuthorizationCode(from callbackURL: URL, expectedState: String) throws
    -> String
  {
    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
      throw GoogleCalendarPluginError.invalidOAuthCallback
    }
    // Keep the first occurrence of each parameter rather than using
    // `Dictionary(uniqueKeysWithValues:)`, which traps on a duplicate key. The
    // callback is attacker-reachable (anything that can reach the loopback
    // port), so a repeated `code`/`state` must not be able to crash sign-in.
    let items = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
      if result[item.name] == nil {
        result[item.name] = item.value ?? ""
      }
    }
    if let error = items["error"], !error.isEmpty {
      throw GoogleCalendarPluginError.authorizationDenied(error)
    }
    guard items["state"] == expectedState else {
      throw GoogleCalendarPluginError.invalidOAuthState
    }
    guard let code = items["code"], !code.isEmpty else {
      throw GoogleCalendarPluginError.invalidOAuthCallback
    }
    return code
  }

  private func exchangeAuthorizationCode(
    authorizationCode: String,
    redirectURI: URL,
    codeVerifier: String
  ) async throws -> GoogleCalendarOAuthTokenResponse {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formEncodedData(
      [
        ("code", authorizationCode),
        ("client_id", normalizedOAuthClientID),
        ("code_verifier", codeVerifier),
        ("redirect_uri", redirectURI.absoluteString),
        ("grant_type", "authorization_code"),
      ]
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw GoogleCalendarPluginError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown OAuth token exchange error."
      throw GoogleCalendarPluginError.apiError(message)
    }

    return try JSONDecoder().decode(GoogleCalendarOAuthTokenResponse.self, from: data)
  }

  private func refreshAccessToken(refreshToken: String) async throws
    -> GoogleCalendarRefreshResponse
  {
    var request = URLRequest(url: Self.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formEncodedData(
      [
        ("client_id", normalizedOAuthClientID),
        ("refresh_token", refreshToken),
        ("grant_type", "refresh_token"),
      ]
    )

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw GoogleCalendarPluginError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown OAuth refresh error."
      throw GoogleCalendarPluginError.apiError(message)
    }

    return try JSONDecoder().decode(GoogleCalendarRefreshResponse.self, from: data)
  }

  private func storeTokenResponse(_ response: GoogleCalendarOAuthTokenResponse) {
    let existingRefreshToken = tokenPayload?.refreshToken
    let resolvedRefreshToken = response.refreshToken ?? existingRefreshToken

    guard let resolvedRefreshToken, !resolvedRefreshToken.isEmpty else {
      isAuthenticated = false
      updateAuthenticationStatusDescription()
      return
    }

    let payload = GoogleCalendarOAuthTokenPayload(
      accessToken: response.accessToken,
      refreshToken: resolvedRefreshToken,
      expiryDate: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
      grantedScopes: response.scope ?? Self.oauthScope,
      clientID: normalizedOAuthClientID
    )
    tokenPayload = payload
    tokenStore.save(payload)
    isAuthenticated = true
    updateAuthenticationStatusDescription()
  }

  private static func makeOAuthState() throws -> String {
    try makeRandomBase64URLString(byteCount: 32)
  }

  private static func makePKCECodeVerifier() throws -> String {
    try makeRandomBase64URLString(byteCount: 64)
  }

  private static func makePKCECodeChallenge(from verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return base64URLEncode(Data(digest))
  }

  private static func makeRandomBase64URLString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: max(byteCount, 1))
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw GoogleCalendarPluginError.randomGenerationFailed
    }
    return base64URLEncode(Data(bytes))
  }

  private static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func formEncodedData(_ pairs: [(String, String)]) -> Data? {
    let query = pairs.map { key, value in
      "\(percentEncode(key))=\(percentEncode(value))"
    }.joined(separator: "&")
    return query.data(using: .utf8)
  }

  private static func percentEncode(_ value: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)!
  }

  private static func canUseTokenPayload(
    _ payload: GoogleCalendarOAuthTokenPayload?,
    forClientID clientID: String
  ) -> Bool {
    guard let payload else { return false }
    guard !clientID.isEmpty else { return false }
    return payload.clientID == clientID && !payload.refreshToken.isEmpty
  }
}

private struct GoogleCalendarCreateEventPayload: Encodable {
  struct EventDatePayload: Encodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
  }

  let summary: String
  let description: String
  let start: EventDatePayload
  let end: EventDatePayload
}

private struct GoogleCalendarCreateEventResponse: Decodable {
  let htmlLink: String?
}

private struct GoogleCalendarOAuthTokenResponse: Decodable {
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

private struct GoogleCalendarRefreshResponse: Decodable {
  let accessToken: String
  let expiresIn: Int
  let scope: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case scope
  }
}

private enum GoogleCalendarPluginError: LocalizedError {
  case missingOAuthClientID
  case invalidAuthorizationURL
  case invalidOAuthCallback
  case invalidOAuthState
  case authorizationDenied(String)
  case authenticationRequired
  case invalidResponse
  case invalidCalendarID
  case apiError(String)
  case randomGenerationFailed

  var errorDescription: String? {
    switch self {
    case .missingOAuthClientID:
      return "Set a Google OAuth client ID first."
    case .invalidAuthorizationURL:
      return "Could not build Google authorization URL."
    case .invalidOAuthCallback:
      return "Google sign-in callback was invalid."
    case .invalidOAuthState:
      return "Google sign-in state mismatch. Try again."
    case .authorizationDenied(let reason):
      return "Google authorization failed: \(reason)"
    case .authenticationRequired:
      return "Sign in to Google Calendar in Preferences."
    case .invalidResponse:
      return "Received an invalid response from Google."
    case .invalidCalendarID:
      return "Google Calendar ID is invalid."
    case .apiError(let message):
      return "Google Calendar API error: \(message)"
    case .randomGenerationFailed:
      return "Could not generate secure OAuth parameters."
    }
  }
}
