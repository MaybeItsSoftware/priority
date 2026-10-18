import Foundation
import TaktRustCore

/// The account's calendar choices (docs/google-calendar.md), kept in the
/// workspace's synced preferences so every device agrees on them.
public struct GoogleCalendarPreferences: Sendable, Equatable {
  /// The calendar timed tasks are kept in step with; nil is two-way off.
  public var twoWayCalendarID: String?
  /// Whether events created in Google on that calendar become tasks.
  public var importEvents: Bool
  /// The calendars a phone's Today shows.
  public var agendaCalendarIDs: [String]

  public init(twoWayCalendarID: String?, importEvents: Bool, agendaCalendarIDs: [String]) {
    self.twoWayCalendarID = twoWayCalendarID
    self.importEvents = importEvents
    self.agendaCalendarIDs = agendaCalendarIDs
  }
}

/// A calendar on the account's calendar list.
public struct GoogleCalendarChoice: Sendable, Equatable, Identifiable, Hashable {
  public let id: String
  public let summary: String
  public let isPrimary: Bool
  /// Whether Takt may write events into it: only these can be two-way.
  public let canWrite: Bool
  public let colorHex: String?
}

/// One line of a day's schedule: an event, or a timed task.
public struct GoogleCalendarAgendaItem: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable { case event, task }
  public let kind: Kind
  /// The event's id, or the task's.
  public let id: String
  public let title: String
  public let start: Date?
  public let end: Date?
  public let isAllDay: Bool
  public let calendarID: String?
  public let isDone: Bool
  public let link: URL?
}

/// What one two-way pass did.
public struct GoogleCalendarPassSummary: Sendable, Equatable {
  public var tasksUpdated = 0
  public var tasksImported = 0
  public var eventsWritten = 0
  /// Writes Google refused; each is retried next pass.
  public var failures: [String] = []
}

public enum GoogleCalendarClientError: LocalizedError, Equatable {
  /// Google refused the token: sign in again.
  case unauthorized
  case http(status: Int, detail: String)

  public var errorDescription: String? {
    switch self {
    case .unauthorized: "Google refused the sign-in. Connect Google Calendar again."
    case .http(let status, let detail):
      detail.isEmpty ? "Google Calendar answered \(status)." : detail
    }
  }
}

/// The Apple side of Google Calendar: HTTP, and nothing else.
///
/// Every request is built, and every answer read, by the Rust core
/// (`core/src/google_calendar.rs`); so is the merge, the lease and what the
/// links remember. This sends what the core built and hands back what came
/// back, the way the Checkvist plugin does. The Mac and the iPhone share it;
/// each brings its own sign-in as `accessToken`.
public final class GoogleCalendarClient: @unchecked Sendable {
  private let store: WorkspaceStore
  private let session: URLSession
  private let accessToken: @Sendable () async throws -> String

  public init(
    store: WorkspaceStore,
    session: URLSession = .shared,
    accessToken: @escaping @Sendable () async throws -> String
  ) {
    self.store = store
    self.session = session
    self.accessToken = accessToken
  }

  /// Every calendar on the account's list.
  public func calendars() async throws -> [GoogleCalendarChoice] {
    let token = try await accessToken()
    var pageToken: String?
    var out: [GoogleCalendarChoice] = []
    repeat {
      let body = try await sendExpectingSuccess(
        googleCalendarRequest(call: .calendars(pageToken: pageToken), accessToken: token))
      let page = try WorkspaceStore.mappingCoreErrors { try googleCalendarCalendars(body: body) }
      out += page.calendars.map {
        GoogleCalendarChoice(
          id: $0.id, summary: $0.summary, isPrimary: $0.isPrimary, canWrite: $0.canWrite,
          colorHex: $0.color)
      }
      pageToken = page.nextPageToken
    } while pageToken != nil
    return out
  }

  /// One two-way pass. Nil when two-way is off, or another device holds the
  /// lease and is doing the pushing.
  public func runPass(now: Date = Date(), zone: TimeZone = .current) async throws
    -> GoogleCalendarPassSummary?
  {
    let core = store.core
    guard let pass = try WorkspaceStore.mappingCoreErrors({ try core.googleCalendarBeginPass(nowMs: now.ms) })
    else { return nil }
    let token = try await accessToken()
    let calendarID = pass.calendarId

    var syncToken = pass.syncToken
    var events: [GoogleCalendarEvent] = []
    var pageToken: String?
    var nextSync: String?
    while true {
      let request = googleCalendarRequest(
        call: .changes(calendarId: calendarID, syncToken: syncToken, pageToken: pageToken),
        accessToken: token)
      let (status, body) = try await send(request)
      if status == 410 {
        // The feed forgot where this device was: start it again, whole.
        try WorkspaceStore.mappingCoreErrors {
          try core.setGoogleCalendarSyncToken(calendarId: calendarID, syncToken: nil, nowMs: now.ms)
        }
        syncToken = nil
        pageToken = nil
        events = []
        continue
      }
      try check(status: status, body: body)
      let page = try WorkspaceStore.mappingCoreErrors {
        try googleCalendarEventsPage(calendarId: calendarID, body: body)
      }
      events += page.events
      if let next = page.nextPageToken {
        pageToken = next
      } else {
        nextSync = page.nextSyncToken
        break
      }
    }

    let reconciled = try WorkspaceStore.mappingCoreErrors {
      try core.googleCalendarReconcile(
        calendarId: calendarID, events: events, full: syncToken == nil, accessToken: token,
        nowMs: now.ms, zone: zone.identifier)
    }
    var summary = GoogleCalendarPassSummary(
      tasksUpdated: Int(reconciled.tasksUpdated), tasksImported: Int(reconciled.tasksImported))
    for push in reconciled.pushes {
      var (status, body) = try await send(push.request)
      if status == 409, let retry = push.onConflict {
        (status, body) = try await send(retry)
      }
      let outcome = try WorkspaceStore.mappingCoreErrors {
        try core.googleCalendarRecordPush(push: push, status: UInt16(clamping: status), body: body, nowMs: now.ms)
      }
      switch outcome {
      case .done: summary.eventsWritten += 1
      case .unauthorized: throw GoogleCalendarClientError.unauthorized
      case .failed(let detail): summary.failures.append(detail)
      }
    }
    try WorkspaceStore.mappingCoreErrors {
      try core.setGoogleCalendarSyncToken(calendarId: calendarID, syncToken: nextSync, nowMs: now.ms)
    }
    return summary
  }

  /// The day holding `day`: events from the agenda calendars (and the
  /// two-way one) interleaved with the timed tasks, all-day first.
  public func agenda(for day: Date, calendar: Calendar = .current) async throws
    -> [GoogleCalendarAgendaItem]
  {
    let start = calendar.startOfDay(for: day)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    let preferences = try store.googleCalendarPreferences()
    var ids = preferences.agendaCalendarIDs
    if let twoWay = preferences.twoWayCalendarID, !ids.contains(twoWay) { ids.append(twoWay) }
    var events: [GoogleCalendarEvent] = []
    if !ids.isEmpty {
      let token = try await accessToken()
      for id in ids {
        var pageToken: String?
        repeat {
          let body = try await sendExpectingSuccess(
            googleCalendarRequest(
              call: .window(calendarId: id, fromMs: start.ms, toMs: end.ms, pageToken: pageToken),
              accessToken: token))
          let page = try WorkspaceStore.mappingCoreErrors {
            try googleCalendarEventsPage(calendarId: id, body: body)
          }
          events += page.events
          pageToken = page.nextPageToken
        } while pageToken != nil
      }
    }
    return try store.googleCalendarAgenda(events: events, from: start, to: end)
  }

  // MARK: - Transport

  private func send(_ request: GoogleCalendarHttpRequest) async throws -> (Int, String) {
    guard let url = URL(string: request.url) else {
      throw GoogleCalendarClientError.http(status: 0, detail: "Bad Google Calendar address.")
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    for header in request.headers {
      urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
    }
    urlRequest.httpBody = request.body.map { Data($0.utf8) }
    let (data, response) = try await session.data(for: urlRequest)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, String(decoding: data, as: UTF8.self))
  }

  private func sendExpectingSuccess(_ request: GoogleCalendarHttpRequest) async throws -> String {
    let (status, body) = try await send(request)
    try check(status: status, body: body)
    return body
  }

  private func check(status: Int, body: String) throws {
    if status == 401 { throw GoogleCalendarClientError.unauthorized }
    guard (200..<300).contains(status) else {
      let message =
        (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
      throw GoogleCalendarClientError.http(status: status, detail: message)
    }
  }
}

extension WorkspaceStore {
  public func googleCalendarPreferences() throws -> GoogleCalendarPreferences {
    let stored = try Self.mappingCoreErrors { try core.googleCalendarSettings() }
    return GoogleCalendarPreferences(
      twoWayCalendarID: stored.calendarId, importEvents: stored.importEvents,
      agendaCalendarIDs: stored.agendaCalendarIds)
  }

  /// Choosing another two-way calendar forgets the links to the old one's
  /// events, which stay where they are.
  public func setGoogleCalendarPreferences(_ preferences: GoogleCalendarPreferences, now: Date = Date())
    throws
  {
    let settings = GoogleCalendarSettings(
      calendarId: preferences.twoWayCalendarID, importEvents: preferences.importEvents,
      agendaCalendarIds: preferences.agendaCalendarIDs)
    try Self.mappingCoreErrors { try core.setGoogleCalendarSettings(settings: settings, nowMs: now.ms) }
  }

  /// The day's schedule from `events` and the workspace's timed tasks.
  func googleCalendarAgenda(events: [GoogleCalendarEvent], from: Date, to: Date) throws
    -> [GoogleCalendarAgendaItem]
  {
    try Self.mappingCoreErrors {
      try core.googleCalendarAgenda(events: events, fromMs: from.ms, toMs: to.ms)
    }
    .map { entry in
      GoogleCalendarAgendaItem(
        kind: entry.kind == .event ? .event : .task, id: entry.id, title: entry.title,
        start: entry.startMs.map(Date.init(ms:)), end: entry.endMs.map(Date.init(ms:)),
        isAllDay: entry.allDay, calendarID: entry.calendarId, isDone: entry.isDone,
        link: entry.htmlLink.flatMap(URL.init(string:)))
    }
  }
}

extension Date {
  fileprivate var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
  fileprivate init(ms: Int64) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
