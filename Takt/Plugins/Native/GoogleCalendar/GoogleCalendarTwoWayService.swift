import Foundation
import Observation
import TaktWorkspace
import os

/// Keeps timed tasks and the chosen Google calendar in step on the Mac
/// (docs/google-calendar.md).
///
/// It decides nothing. The Rust core builds every request, merges what
/// Google sent with the workspace and says what to write back
/// (`GoogleCalendarClient` is the shared Apple transport); this owns the
/// timing, the sign-in and what the settings page shows. Which device pushes
/// is the core's lease, so a Mac and a phone signed into the same account
/// do not both write.
@MainActor
@Observable final class GoogleCalendarTwoWayService {
  enum State: Equatable {
    case idle
    case syncing
    case failed(String)
  }

  private(set) var state: State = .idle
  private(set) var lastSyncedAt: Date?
  /// The last pass that ran here; nil while another device holds the lease.
  private(set) var lastSummary: GoogleCalendarPassSummary?
  private(set) var calendars: [GoogleCalendarChoice] = []
  private(set) var preferences = GoogleCalendarPreferences(
    twoWayCalendarID: nil, importEvents: false, agendaCalendarIDs: [])

  private static let debounce: Duration = .seconds(5)
  private static let pollInterval: Duration = .seconds(300)

  private let account: GoogleAccount
  private let storeProvider: () -> WorkspaceStore?
  private let isEnabled: () -> Bool
  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "GoogleCalendarTwoWayService")

  /// Called after a pass moved, renamed or made tasks, which the view
  /// model's external-write poll would otherwise not notice.
  var onWroteLocally: (() -> Void)?

  private var pendingSync: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var isRunning = false

  init(
    account: GoogleAccount,
    storeProvider: @escaping () -> WorkspaceStore?,
    isEnabled: @escaping () -> Bool
  ) {
    self.account = account
    self.storeProvider = storeProvider
    self.isEnabled = isEnabled
  }

  private var canRun: Bool { isEnabled() && account.hasGrantedScopes(GoogleAPIScope.calendar) }

  private func client(_ store: WorkspaceStore) -> GoogleCalendarClient {
    let account = account
    return GoogleCalendarClient(store: store) {
      try await account.accessToken(requiring: GoogleAPIScope.calendar, service: "Google Calendar")
    }
  }

  // MARK: - Settings

  func reloadPreferences() {
    guard let store = storeProvider(), let stored = try? store.googleCalendarPreferences() else {
      return
    }
    preferences = stored
  }

  func update(_ change: (inout GoogleCalendarPreferences) -> Void) {
    guard let store = storeProvider() else { return }
    var next = preferences
    change(&next)
    do {
      try store.setGoogleCalendarPreferences(next)
      preferences = next
      syncNow()
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func loadCalendars() async {
    guard canRun, let store = storeProvider() else { return }
    do {
      calendars = try await client(store).calendars()
    } catch {
      report(error)
    }
  }

  // MARK: - Triggers

  func scheduleSync() {
    guard canRun else { return }
    pendingSync?.cancel()
    pendingSync = Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      await self?.sync()
    }
  }

  func syncNow() {
    pendingSync?.cancel()
    pendingSync = Task { [weak self] in await self?.sync() }
  }

  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.pollInterval)
        guard !Task.isCancelled else { return }
        await self?.sync()
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    pendingSync?.cancel()
    pendingSync = nil
  }

  // MARK: - One pass

  func sync() async {
    guard canRun, !isRunning, let store = storeProvider() else { return }
    isRunning = true
    defer { isRunning = false }
    reloadPreferences()
    state = .syncing
    do {
      let summary = try await client(store).runPass()
      lastSummary = summary
      lastSyncedAt = .now
      state = .idle
      if let summary, summary.tasksUpdated + summary.tasksImported > 0 {
        onWroteLocally?()
      }
      if let failure = summary?.failures.first {
        logger.error("Google Calendar refused a write: \(failure, privacy: .public)")
      }
    } catch {
      report(error)
    }
  }

  private func report(_ error: Error) {
    if case GoogleCalendarClientError.unauthorized = error {
      account.invalidateAfterUnauthorized()
    }
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    logger.error("Google Calendar pass failed: \(message, privacy: .public)")
    state = .failed(message)
  }
}
