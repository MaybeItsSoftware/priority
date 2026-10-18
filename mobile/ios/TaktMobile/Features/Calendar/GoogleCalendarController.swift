import Foundation
import Observation
import OSLog
import TaktWorkspace
import UIKit

/// The iPhone's hold on Google Calendar (docs/google-calendar.md): the
/// sign-in, the two-way pass while the app is in front, and today's agenda
/// for the Today screen.
///
/// Everything that decides anything is the Rust core's, reached through
/// `GoogleCalendarClient`, which the Mac shares. The lease in the core means
/// a phone and a Mac signed into one account never both push.
@MainActor
@Observable
final class GoogleCalendarController {
  /// The one controller, once the workspace is open. Nil in UI tests.
  private(set) static var shared: GoogleCalendarController?

  private(set) var isConnected: Bool
  private(set) var isBusy = false
  var errorMessage: String?
  private(set) var preferences = GoogleCalendarPreferences(
    twoWayCalendarID: nil, importEvents: false, agendaCalendarIDs: [])
  private(set) var calendars: [GoogleCalendarChoice] = []
  /// Today's events and timed tasks, interleaved by time.
  private(set) var agenda: [GoogleCalendarAgendaItem] = []
  private(set) var lastSyncedAt: Date?

  @ObservationIgnored private let auth: GoogleCalendarAuth
  @ObservationIgnored private let client: GoogleCalendarClient
  @ObservationIgnored private let store: WorkspaceStore
  @ObservationIgnored private weak var model: WorkspaceModel?
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "GoogleCalendarController")

  private static let pollInterval: Duration = .seconds(15 * 60)

  init(model: WorkspaceModel) {
    self.model = model
    store = model.store
    let auth = GoogleCalendarAuth()
    self.auth = auth
    client = GoogleCalendarClient(store: model.store) { try await auth.accessToken() }
    isConnected = auth.isConnected
    if let stored = try? model.store.googleCalendarPreferences() { preferences = stored }
  }

  /// Installed from `featureInstallers`.
  static func install(on model: WorkspaceModel) {
    guard !AppGroup.isUITesting, shared == nil else { return }
    let controller = GoogleCalendarController(model: model)
    shared = controller
    controller.observeForeground()
  }

  var isConfigured: Bool { GoogleCalendarAuth.isConfigured }

  // MARK: - Rhythm

  private func observeForeground() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.startPolling() }
      })
    observers.append(
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.stopPolling() }
      })
  }

  private func startPolling() {
    guard poll == nil else { return }
    poll = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  private func stopPolling() {
    poll?.cancel()
    poll = nil
  }

  /// One two-way pass (when this device holds the lease), then today's
  /// agenda. Quietly nothing while disconnected.
  func refresh() async {
    guard isConnected, !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    preferences = (try? store.googleCalendarPreferences()) ?? preferences
    do {
      if let summary = try await client.runPass() {
        lastSyncedAt = .now
        if summary.tasksUpdated + summary.tasksImported > 0 { model?.didChange() }
        if let failure = summary.failures.first { logger.error("Calendar write refused: \(failure, privacy: .public)") }
      }
      agenda = try await client.agenda(for: .now)
      errorMessage = nil
    } catch {
      report(error)
    }
  }

  // MARK: - Settings

  func connect() async {
    errorMessage = nil
    do {
      try await auth.connect()
      isConnected = auth.isConnected
      await loadCalendars()
      await refresh()
    } catch GoogleCalendarAuthError.cancelled {
      return
    } catch {
      report(error)
    }
  }

  func disconnect() {
    auth.disconnect()
    isConnected = false
    calendars = []
    agenda = []
  }

  func loadCalendars() async {
    guard isConnected else { return }
    do {
      calendars = try await client.calendars()
    } catch {
      report(error)
    }
  }

  func update(_ change: (inout GoogleCalendarPreferences) -> Void) {
    var next = preferences
    change(&next)
    do {
      try store.setGoogleCalendarPreferences(next)
      preferences = next
      Task { await refresh() }
    } catch {
      report(error)
    }
  }

  private func report(_ error: Error) {
    if case GoogleCalendarClientError.unauthorized = error {
      auth.forget()
      isConnected = false
    } else if case GoogleCalendarAuthError.notConnected = error {
      isConnected = false
    }
    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    logger.error("Google Calendar: \(self.errorMessage ?? "", privacy: .public)")
  }
}
