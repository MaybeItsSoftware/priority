import Foundation
import Observation
import TaktCore
import TaktWorkspace
import os

/// Completes a task once its calendar event has been cleared.
///
/// The counterpart to ticking something off in Google Tasks, for the other
/// Google surface a task can end up on. Clearing an event off a calendar is
/// what a person does once it has happened, so Priority treats it the way it
/// treats a tick: not as a disagreement to be overruled, but as the same
/// answer arriving by another route.
///
/// Only events Priority created are watched, and only until they resolve. A
/// meeting somebody else put in the calendar is not a task and is never read.
@MainActor
@Observable final class GoogleCalendarCompletionWatcher {
  /// How often the calendar is asked. Slower than the Tasks mirror: an event
  /// being cleared is a once-a-day event, not a once-a-minute one.
  private static let pollInterval: Duration = .seconds(900)

  private let plugin: any GoogleCalendarIntegrationPlugin
  private let store: GoogleCalendarEventLedgerStore
  private let storeProvider: () -> WorkspaceStore?
  private let isEnabled: () -> Bool
  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "GoogleCalendarCompletionWatcher")

  private var pollTask: Task<Void, Never>?
  private var isRunning = false

  private(set) var watchedEventCount: Int

  init(
    plugin: any GoogleCalendarIntegrationPlugin,
    storeProvider: @escaping () -> WorkspaceStore?,
    isEnabled: @escaping () -> Bool,
    store: GoogleCalendarEventLedgerStore = GoogleCalendarEventLedgerStore()
  ) {
    self.plugin = plugin
    self.storeProvider = storeProvider
    self.isEnabled = isEnabled
    self.store = store
    self.watchedEventCount = store.load().count
  }

  /// Remembers that this task now has an event standing for it.
  func watch(eventID: String, forTask taskID: String) {
    var ledger = store.load()
    ledger[taskID] = eventID
    try? store.save(ledger)
    watchedEventCount = ledger.count
  }

  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.pollInterval)
        guard !Task.isCancelled else { return }
        await self?.check()
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  func check() async {
    guard isEnabled(), plugin.isAuthenticated, !isRunning else { return }
    guard let workspaceStore = storeProvider() else { return }
    var ledger = store.load()
    guard !ledger.isEmpty else { return }
    isRunning = true
    defer { isRunning = false }

    for (taskID, eventID) in ledger {
      // A task that is already finished, or gone from the workspace entirely,
      // has nothing left to learn from its event.
      let existing = try? workspaceStore.task(id: taskID)
      guard let task = existing ?? nil, task.status == TaskStatus.open else {
        ledger.removeValue(forKey: taskID)
        continue
      }
      do {
        guard try await plugin.eventState(id: eventID) == .gone else { continue }
        try workspaceStore.setStatus(.completed, for: taskID)
        ledger.removeValue(forKey: taskID)
        logger.info("Completed a task whose calendar event was cleared")
      } catch {
        // A transient failure leaves the entry alone: the next pass asks again
        // rather than losing track of the event.
        continue
      }
    }

    try? store.save(ledger)
    watchedEventCount = ledger.count
  }
}

/// Priority task id → the Google Calendar event standing for it.
///
/// Small, whole-file and atomically replaced, like the Tasks mirror's ledger
/// and for the same reason: it is a current belief about the far side rather
/// than a history of it.
struct GoogleCalendarEventLedgerStore {
  private let url: URL

  init(directory: URL = DailyLogService.defaultStoreDirectoryURL()) {
    self.url = directory.appendingPathComponent("google-calendar-events.json")
  }

  func load() -> [String: String] {
    guard let data = try? Data(contentsOf: url),
      let ledger = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return ledger
  }

  func save(_ ledger: [String: String]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(ledger).write(to: url, options: .atomic)
  }
}
