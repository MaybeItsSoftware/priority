import BackgroundTasks
import Foundation
import Observation
import OSLog
import PrioritySync
import UIKit

/// The app's hold on sync: one `SyncSession` over the workspace store, kept
/// running while the app is in front, refreshed in the background, and
/// reported back into the workspace when a pull changes it.
///
/// All of the protocol lives in `PrioritySync`; this is only the iOS rhythm
/// around it — scene phases, the background refresh task, pairing links.
@MainActor
@Observable
final class SyncController {
  /// The one controller, once the workspace is open. Nil in UI tests, which
  /// run on a throwaway workspace that must never reach a server.
  private(set) static var shared: SyncController?

  static let refreshTaskID = "uk.co.maybeitsadam.priority.ios.sync"

  let session: SyncSession
  /// The last pairing attempt's failure, for the settings screen.
  var pairingError: String?
  var isPairing = false

  @ObservationIgnored private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "SyncController")

  init(model: WorkspaceModel) {
    session = SyncSession(store: model.store, deviceName: UIDevice.current.name, platform: "ios")
    session.onRemoteChanges = { [weak model] in model?.didChange() }
  }

  /// Installed from `featureInstallers`.
  static func install(on model: WorkspaceModel) {
    guard !AppGroup.isUITesting, shared == nil else { return }
    shared = SyncController(model: model)
  }

  // MARK: - Rhythm

  func sceneBecameActive() {
    session.activate()
  }

  func sceneLeftForeground() {
    session.deactivate()
    scheduleBackgroundRefresh()
  }

  /// Pull-to-refresh and "Sync now". Quietly nothing when unpaired.
  func syncNow() async {
    guard session.isPaired else { return }
    await session.syncNow()
  }

  /// Asks for a background refresh in a quarter of an hour or so. The
  /// system decides when; a paired device is all that asks.
  func scheduleBackgroundRefresh() {
    guard session.isPaired else { return }
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      logger.debug("Background refresh not scheduled: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// The background refresh task's body: one cycle, then ask for the next.
  func backgroundRefresh() async {
    guard session.isPaired else { return }
    await session.syncNow()
    scheduleBackgroundRefresh()
  }

  // MARK: - Pairing

  /// Joins with a link scanned, pasted or opened. True when paired.
  @discardableResult
  func pair(with link: SyncPairingLink) async -> Bool {
    await attempt { try await self.session.pair(with: link) }
  }

  @discardableResult
  func pair(serverURL: URL, adminToken: String) async -> Bool {
    await attempt { try await self.session.pair(serverURL: serverURL, adminToken: adminToken) }
  }

  private func attempt(_ work: () async throws -> Void) async -> Bool {
    isPairing = true
    pairingError = nil
    defer { isPairing = false }
    do {
      try await work()
      return true
    } catch {
      pairingError = error.localizedDescription
      return false
    }
  }

  func unpair() {
    do {
      try session.unpair()
    } catch {
      pairingError = error.localizedDescription
    }
  }
}

/// The phase in words, shared by the status line and the settings screen.
enum SyncPhaseText {
  static func describe(_ phase: SyncSession.Phase, now: Date = .now) -> String {
    switch phase {
    case .unpaired: return "Not set up"
    case .syncing: return "Syncing…"
    case .failed(let message): return "Couldn't sync: \(message)"
    case .idle(let last):
      guard let last else { return "Paired" }
      if now.timeIntervalSince(last) < 60 { return "Synced just now" }
      let relative = RelativeDateTimeFormatter()
      relative.unitsStyle = .short
      return "Synced \(relative.localizedString(for: last, relativeTo: now))"
    }
  }

  static func short(_ phase: SyncSession.Phase) -> String {
    switch phase {
    case .unpaired: "Off"
    case .syncing: "Syncing"
    case .failed: "Error"
    case .idle: "On"
    }
  }

  static func symbol(_ phase: SyncSession.Phase) -> String {
    switch phase {
    case .unpaired: "icloud.slash"
    case .syncing: "arrow.triangle.2.circlepath"
    case .failed: "exclamationmark.icloud"
    case .idle: "checkmark.icloud"
    }
  }
}
