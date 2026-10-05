import AppKit
import Foundation
import Observation

@MainActor
@Observable final class NativeGoogleCalendarIntegrationPlugin: GoogleCalendarIntegrationPlugin
{
  let pluginIdentifier = "native.google.calendar.integration"
  let displayName = "Native Google Calendar Integration"
  let pluginDescription = "Create Google Calendar events from tasks using your Google account."

  /// Sign-in belongs to the Google account, not to this integration: Tasks
  /// signs in through the same one, and two integrations should not mean two
  /// trips through consent for the same Google user.
  let account: GoogleAccount

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

  var oauthClientID: String {
    get { account.clientID }
    set { account.clientID = newValue }
  }

  var isAuthenticating: Bool { account.isAuthenticating }
  var isAuthenticated: Bool { account.hasGrantedScopes(GoogleAPIScope.calendar) }
  var authenticationStatusDescription: String {
    guard account.hasClientConfiguration else {
      return "OAuth not configured. Calendar event creation is unavailable."
    }
    if account.isAuthenticating { return "Signing in with Google…" }
    if isAuthenticated { return "Connected to the Google Calendar API." }
    if account.isAuthenticated {
      return "Signed in, but this grant predates Calendar. Sign in again."
    }
    return "OAuth configured. Sign in required."
  }

  var requiresAuthentication: Bool { account.hasClientConfiguration }
  var hasOAuthClientConfiguration: Bool { account.hasClientConfiguration }

  private static let targetCalendarIDDefaultsKey = "googleCalendarTargetCalendarID"
  private static let openCreatedEventInBrowserDefaultsKey =
    "googleCalendarOpenCreatedEventInBrowser"
  private static let eventDescriptionSourceName = "Takt"

  private let defaultEventDurationMinutes: Int
  private let calendar: Calendar
  private let session: URLSession
  private let defaults: UserDefaults

  init(
    account: GoogleAccount,
    defaultEventDurationMinutes: Int = 30,
    calendar: Calendar = .current,
    session: URLSession = .shared,
    defaults: UserDefaults = .standard
  ) {
    self.account = account
    self.defaultEventDurationMinutes = max(defaultEventDurationMinutes, 1)
    self.calendar = calendar
    self.session = session
    self.defaults = defaults
    let storedCalendarID =
      defaults.string(forKey: Self.targetCalendarIDDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    self.targetCalendarID = storedCalendarID.isEmpty ? "primary" : storedCalendarID
    self.openCreatedEventInBrowser =
      defaults.object(forKey: Self.openCreatedEventInBrowserDefaultsKey) as? Bool ?? true
    account.requireScopes(GoogleAPIScope.calendar)
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
    let rawTitle = task.content.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = rawTitle.isEmpty ? "Checkvist Task #\(task.id)" : rawTitle
    let details = """
      Created from \(Self.eventDescriptionSourceName)
      List ID: \(listId)
      Task ID: \(task.id)
      """
    return try await createEvent(
      title: title, details: details, date: task.dueDate,
      isAllDay: task.dueDate != nil && !hasExplicitDueTime(rawDue: task.due), now: now)
  }

  func createEvent(
    title: String, details: String, date: Date?, isAllDay: Bool, now: Date
  ) async throws -> GoogleCalendarEventCreationOutcome {
    let validAccessToken = try await account.accessToken(
      requiring: GoogleAPIScope.calendar, service: "Google Calendar")
    let createdEventURL = try await createEventWithGoogleAPI(
      accessToken: validAccessToken, title: title, details: details,
      date: date, isAllDay: isAllDay, now: now
    )
    let urlToOpen = openCreatedEventInBrowser ? createdEventURL.url : nil
    return GoogleCalendarEventCreationOutcome(
      urlToOpen: urlToOpen, usedGoogleCalendarAPI: true, eventID: createdEventURL.id)
  }

  func prepareAuthentication() {
    account.prepare()
  }

  func beginAuthentication() async throws {
    try await account.beginAuthentication()
  }

  func disconnectAuthentication() {
    account.disconnect()
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

  /// Whether an event Priority created is still on the calendar.
  ///
  /// Google keeps a deleted event as `cancelled` for a while and then stops
  /// returning it at all, so both answers mean the same thing here: somebody
  /// cleared it, and the task it stood for is done.
  func eventState(id: String) async throws -> GoogleCalendarEventState {
    guard let url = makeEventURL(id: id) else { throw GoogleCalendarPluginError.invalidCalendarID }
    let token = try await account.accessToken(
      requiring: GoogleAPIScope.calendar, service: "Google Calendar")
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GoogleCalendarPluginError.invalidResponse
    }
    if http.statusCode == 404 || http.statusCode == 410 { return .gone }
    if http.statusCode == 401 {
      account.invalidateAfterUnauthorized()
      throw GoogleAccountError.authenticationRequired
    }
    guard (200...299).contains(http.statusCode) else {
      throw GoogleCalendarPluginError.apiError(
        String(data: data, encoding: .utf8) ?? "Unknown Google Calendar API error.")
    }
    let decoded = try JSONDecoder().decode(GoogleCalendarEventResponse.self, from: data)
    return decoded.status == "cancelled" ? .gone : .active
  }

  private func makeEventURL(id: String) -> URL? {
    guard let base = makeEventsAPIURL(),
      let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else { return nil }
    return URL(string: "\(base.absoluteString)/\(encoded)")
  }

  private func createEventWithGoogleAPI(
    accessToken: String,
    title: String,
    details: String,
    date: Date?,
    isAllDay: Bool,
    now: Date
  ) async throws -> (url: URL?, id: String?) {
    guard let eventURL = makeEventsAPIURL() else {
      throw GoogleCalendarPluginError.invalidCalendarID
    }

    let payload = makeGoogleCalendarEventPayload(
      title: title, details: details, date: date, isAllDay: isAllDay, now: now)
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
      // Accepted at refresh, rejected at use: the grant was revoked at
      // Google's end, so the local sign-in is worthless and goes too.
      account.invalidateAfterUnauthorized()
      throw GoogleAccountError.authenticationRequired
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown Google Calendar API error."
      throw GoogleCalendarPluginError.apiError(message)
    }

    let decoded = try JSONDecoder().decode(GoogleCalendarCreateEventResponse.self, from: data)
    return (decoded.htmlLink.flatMap { URL(string: $0) }, decoded.id)
  }

  private func makeEventsAPIURL() -> URL? {
    let trimmedCalendarID = targetCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
    let calendarID = trimmedCalendarID.isEmpty ? "primary" : trimmedCalendarID
    let encodedCalendarID =
      calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    return URL(
      string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")
  }

  private func makeGoogleCalendarEventPayload(
    title: String, details: String, date: Date?, isAllDay: Bool, now: Date
  )
    -> GoogleCalendarCreateEventPayload
  {
    if let dueDate = date {
      if !isAllDay {
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
  let id: String?
}

private struct GoogleCalendarEventResponse: Decodable {
  let status: String?
}

/// What is left once sign-in moved to `GoogleAccount`: the errors that are
/// about calendars rather than about OAuth.
private enum GoogleCalendarPluginError: LocalizedError {
  case invalidResponse
  case invalidCalendarID
  case apiError(String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Received an invalid response from Google."
    case .invalidCalendarID:
      return "Google Calendar ID is invalid."
    case .apiError(let message):
      return "Google Calendar API error: \(message)"
    }
  }
}
