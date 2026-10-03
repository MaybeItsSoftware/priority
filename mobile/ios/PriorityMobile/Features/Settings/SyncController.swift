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
    guard session.isSignedIn else { return }
    await session.syncNow()
  }

  /// Asks for a background refresh in a quarter of an hour or so. The
  /// system decides when; a paired device is all that asks.
  func scheduleBackgroundRefresh() {
    guard session.isSignedIn else { return }
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
    guard session.isSignedIn else { return }
    await session.syncNow()
    scheduleBackgroundRefresh()
  }

  // MARK: - Signing in

  /// Signs in to an existing account. True when signed in.
  @discardableResult
  func signIn(email: String, password: String, serverURL: URL) async -> Bool {
    await attempt { try await self.session.signIn(email: email, password: password, serverURL: serverURL) }
  }

  /// Makes an account and signs in to it. True when signed in.
  @discardableResult
  func signUp(email: String, password: String, serverURL: URL) async -> Bool {
    await attempt { try await self.session.signUp(email: email, password: password, serverURL: serverURL) }
  }

  /// Joins with a link scanned, pasted or opened. True when signed in.
  @discardableResult
  func pair(with link: SyncPairingLink) async -> Bool {
    await attempt { try await self.session.pair(with: link) }
  }

  /// Joins with a typed code (or a pasted link). True when signed in.
  @discardableResult
  func pair(codeOrLink: String, serverURL: URL) async -> Bool {
    await attempt { try await self.session.pair(codeOrLink: codeOrLink, serverURL: serverURL) }
  }

  /// Emails a link for setting a new password. The confirmation to show when
  /// it was sent; nil, with `pairingError` set, when it wasn't.
  func requestPasswordReset(email: String, serverURL: URL) async -> String? {
    var sent: String?
    await attempt { sent = try await self.session.requestPasswordReset(email: email, serverURL: serverURL) }
    return sent.map(SyncSession.passwordResetSentMessage(for:))
  }

  /// Signs this device out. Its tasks stay.
  func signOut() async {
    await session.signOut()
  }

  /// Deletes the account on the server. True when it is gone.
  @discardableResult
  func deleteAccount(password: String) async -> Bool {
    await attempt { try await self.session.deleteAccount(password: password) }
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
}

/// The phase in words, shared by the status line and the settings screen.
enum SyncPhaseText {
  static func describe(_ phase: SyncSession.Phase, now: Date = .now) -> String {
    switch phase {
    case .unpaired: return "Not set up"
    case .needsSignIn: return "Signed out — sign in again"
    case .syncing: return "Syncing…"
    case .failed(let message): return "Couldn't sync: \(message)"
    case .idle(let last):
      guard let last else { return "Signed in" }
      if now.timeIntervalSince(last) < 60 { return "Synced just now" }
      let relative = RelativeDateTimeFormatter()
      relative.unitsStyle = .short
      return "Synced \(relative.localizedString(for: last, relativeTo: now))"
    }
  }

  static func short(_ phase: SyncSession.Phase) -> String {
    switch phase {
    case .unpaired: "Off"
    case .needsSignIn: "Signed out"
    case .syncing: "Syncing"
    case .failed: "Error"
    case .idle: "On"
    }
  }

  static func symbol(_ phase: SyncSession.Phase) -> String {
    switch phase {
    case .unpaired: "icloud.slash"
    case .needsSignIn, .failed: "exclamationmark.icloud"
    case .syncing: "arrow.triangle.2.circlepath"
    case .idle: "checkmark.icloud"
    }
  }

  /// Whether the phase is something the user has to deal with.
  static func isProblem(_ phase: SyncSession.Phase) -> Bool {
    switch phase {
    case .needsSignIn, .failed: true
    default: false
    }
  }
}
