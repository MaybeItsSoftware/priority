import Foundation
import Observation
import PriorityWorkspace

/// What a paired device shows another to let it join: the server and a
/// one-time code, as a link a phone can scan from a QR code or open from a
/// pasted message. `priority-sync://pair?server=<url>&code=<code>`.
///
/// The Android app parses the same link (`mobile/android`), so the format is
/// part of the protocol rather than a detail of either app.
public struct SyncPairingLink: Equatable, Sendable {
  public static let scheme = "priority-sync"
  public var serverURL: URL
  public var code: String

  public init(serverURL: URL, code: String) {
    self.serverURL = serverURL
    self.code = code
  }

  public init?(_ string: String) {
    guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
      components.scheme == Self.scheme, components.host == "pair",
      let server = components.queryItems?.first(where: { $0.name == "server" })?.value,
      let serverURL = URL(string: server), serverURL.scheme?.hasPrefix("http") == true,
      let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
    else { return nil }
    self.init(serverURL: serverURL, code: code)
  }

  public var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = "pair"
    components.queryItems = [
      URLQueryItem(name: "server", value: serverURL.absoluteString),
      URLQueryItem(name: "code", value: code),
    ]
    return components.url!
  }
}

/// Sync as the apps see it: paired or not, what it is doing, and the handful
/// of things a settings screen does. The Mac and iOS apps both hold one, so
/// pairing, the rhythm and the status read the same on each.
@MainActor
@Observable
public final class SyncSession {
  public enum Phase: Equatable {
    case unpaired
    case idle(lastSyncedAt: Date?)
    case syncing
    case failed(String)
  }

  public private(set) var phase: Phase = .unpaired
  public private(set) var credentials: SyncCredentials?
  /// The latest code this device minted for another to join with.
  public private(set) var pairingLink: SyncPairingLink?
  public private(set) var pairingCodeExpiresAt: Date?

  @ObservationIgnored private let store: WorkspaceStore
  @ObservationIgnored private let credentialStore: any SyncCredentialStore
  @ObservationIgnored private let deviceName: String
  @ObservationIgnored private let platform: String
  @ObservationIgnored private var scheduler: SyncScheduler?
  @ObservationIgnored private var outboxWatch: Task<Void, Never>?
  /// Called on the main actor after a pull has changed the workspace.
  @ObservationIgnored public var onRemoteChanges: (() -> Void)?

  public init(
    store: WorkspaceStore, credentialStore: any SyncCredentialStore = KeychainSyncCredentialStore(),
    deviceName: String, platform: String
  ) {
    self.store = store
    self.credentialStore = credentialStore
    self.deviceName = deviceName
    self.platform = platform
    if let saved = credentialStore.load(), (try? store.syncState()) != nil {
      credentials = saved
      phase = .idle(lastSyncedAt: try? store.syncState()?.lastSyncedAt)
    }
  }

  public var isPaired: Bool { credentials != nil }

  /// Starts the rhythm: a cycle now, a long-poll while the app is in front,
  /// and a cycle shortly after any local write. Safe to call repeatedly.
  public func activate() {
    guard let credentials, scheduler == nil else { return }
    let engine = SyncEngine(
      store: store, transport: HTTPSyncTransport(credentials: credentials), deviceId: credentials.deviceId)
    let scheduler = SyncScheduler(engine: engine) { [weak self] status, outcome in
      await self?.report(status, outcome)
    }
    self.scheduler = scheduler
    Task { await scheduler.start() }
    watchOutbox()
  }

  /// Stops the long-poll, for when the app goes to the background. Local
  /// writes still queue in the outbox and go with the next cycle.
  public func deactivate() {
    outboxWatch?.cancel()
    outboxWatch = nil
    if let scheduler { Task { await scheduler.stop() } }
    scheduler = nil
  }

  /// One cycle, for "Sync now" and for a background refresh. True when it
  /// succeeded.
  @discardableResult
  public func syncNow() async -> Bool {
    if let scheduler { return await scheduler.syncNow() }
    guard let credentials else { return false }
    let engine = SyncEngine(
      store: store, transport: HTTPSyncTransport(credentials: credentials), deviceId: credentials.deviceId)
    do {
      let outcome = try await engine.sync()
      report(.idle(lastSyncedAt: Date()), outcome)
      return true
    } catch {
      report(.failed(error.localizedDescription), nil)
      return false
    }
  }

  /// Pairs with a server: with its admin token for the first device, or with
  /// a link minted by a device already paired.
  public func pair(serverURL: URL, adminToken: String) async throws {
    let credentials = try await HTTPSyncTransport.pair(
      serverURL: serverURL, adminToken: adminToken, deviceName: deviceName, platform: platform)
    try adopt(credentials)
  }

  public func pair(with link: SyncPairingLink) async throws {
    let credentials = try await HTTPSyncTransport.pair(
      serverURL: link.serverURL, code: link.code, deviceName: deviceName, platform: platform)
    try adopt(credentials)
  }

  /// Mints a one-time code another device can join with.
  public func makePairingLink() async throws {
    guard let credentials else { throw SyncError.notPaired }
    let code = try await HTTPSyncTransport(credentials: credentials).createPairingCode()
    pairingLink = SyncPairingLink(serverURL: credentials.serverURL, code: code.code)
    pairingCodeExpiresAt = ISO8601DateFormatter().date(from: code.expiresAt)
  }

  /// Leaves the account. The workspace stays as it is on this device.
  public func unpair() throws {
    deactivate()
    try store.endSync()
    credentialStore.clear()
    credentials = nil
    pairingLink = nil
    phase = .unpaired
  }

  private func adopt(_ credentials: SyncCredentials) throws {
    try store.beginSync(deviceId: credentials.deviceId, serverURL: credentials.serverURL.absoluteString)
    try credentialStore.save(credentials)
    self.credentials = credentials
    phase = .idle(lastSyncedAt: nil)
    activate()
  }

  private func report(_ status: SyncEngine.Status, _ outcome: SyncEngine.Outcome?) {
    guard credentials != nil else { return }
    switch status {
    case .idle(let last): phase = .idle(lastSyncedAt: last)
    case .syncing: phase = .syncing
    case .failed(let message): phase = .failed(message)
    }
    if outcome?.changedWorkspace == true { onRemoteChanges?() }
  }

  /// Notices local writes, whoever made them — this app, or the CLI writing
  /// the same file — by watching the outbox rather than asking every mutation
  /// to report itself. One cheap EXISTS query a second.
  private func watchOutbox() {
    outboxWatch?.cancel()
    outboxWatch = Task { [weak self, store] in
      var lastSeq: Int64?
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        let seq = try? store.latestSyncOutboxSeq()
        if let seq, seq != lastSeq {
          lastSeq = seq
          await self?.scheduler?.noteLocalChange()
        }
      }
    }
  }
}
