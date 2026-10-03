import Foundation
import Observation
import PriorityWorkspace

/// What a signed-in device shows another to let it join: the server and a
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

/// Sync as the apps see it: signed in or not, what it is doing, and the
/// handful of things a settings screen does. The Mac and iOS apps both hold
/// one, so signing in, the rhythm and the status read the same on each.
@MainActor
@Observable
public final class SyncSession {
  public enum Phase: Equatable {
    /// Never signed in, or signed out on purpose.
    case unpaired
    /// The server refused this device's token (signed out from another
    /// device, or the account deleted). Nothing syncs until it signs in again.
    case needsSignIn
    case idle(lastSyncedAt: Date?)
    case syncing
    case failed(String)
  }

  public private(set) var phase: Phase = .unpaired
  /// Set only while the device holds a token the server accepts.
  public private(set) var credentials: SyncCredentials?
  /// The email and server last used here, to fill in the sign-in form.
  public private(set) var rememberedEmail: String?
  public private(set) var rememberedServerURL: URL?
  /// The account and its devices, from `refreshAccount()`.
  public private(set) var account: SyncAccount?
  /// The latest code this device minted for another to join with.
  public private(set) var pairingLink: SyncPairingLink?
  public private(set) var pairingCodeExpiresAt: Date?

  @ObservationIgnored private let store: WorkspaceStore
  @ObservationIgnored private let credentialStore: any SyncCredentialStore
  @ObservationIgnored private let urlSession: URLSession
  @ObservationIgnored private let deviceName: String
  @ObservationIgnored private let platform: String
  @ObservationIgnored private var scheduler: SyncScheduler?
  @ObservationIgnored private var outboxWatch: Task<Void, Never>?
  /// Called on the main actor after a pull has changed the workspace.
  @ObservationIgnored public var onRemoteChanges: (() -> Void)?

  public init(
    store: WorkspaceStore, credentialStore: any SyncCredentialStore = KeychainSyncCredentialStore(),
    deviceName: String, platform: String, urlSession: URLSession = .shared
  ) {
    self.store = store
    self.credentialStore = credentialStore
    self.urlSession = urlSession
    self.deviceName = deviceName
    self.platform = platform
    if let saved = credentialStore.load(), (try? store.syncState()) != nil {
      rememberedEmail = saved.email
      rememberedServerURL = saved.serverURL
      if saved.isSignedOut {
        phase = .needsSignIn
      } else {
        credentials = saved
        phase = .idle(lastSyncedAt: try? store.syncState()?.lastSyncedAt)
      }
    }
  }

  public var isSignedIn: Bool { credentials != nil }

  /// The email shown as "Signed in as …": the account's, once known.
  public var email: String? { account?.email ?? credentials?.email }

  // MARK: - Rhythm

  /// Starts the rhythm: a cycle now, a long-poll while the app is in front,
  /// and a cycle shortly after any local write. Safe to call repeatedly.
  public func activate() {
    guard let credentials, scheduler == nil else { return }
    let scheduler = SyncScheduler(engine: engine(for: credentials)) { [weak self] status, outcome in
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
    do {
      let outcome = try await engine(for: credentials).sync()
      report(.idle(lastSyncedAt: Date()), outcome)
      return true
    } catch SyncError.unauthorized {
      tokenWasRefused()
      return false
    } catch {
      report(.failed(error.localizedDescription), nil)
      return false
    }
  }

  // MARK: - Signing in

  /// Makes an account and signs this device in to it.
  public func signUp(email: String, password: String, serverURL: URL = SyncServer.defaultURL) async throws {
    let email = try Self.checked(email: email, password: password)
    try adopt(
      await HTTPSyncTransport.signUp(
        serverURL: serverURL, email: email, password: password, deviceName: deviceName, platform: platform,
        session: urlSession))
  }

  /// Signs this device in to an existing account.
  public func signIn(email: String, password: String, serverURL: URL = SyncServer.defaultURL) async throws {
    let email = try Self.checked(email: email, password: password)
    try adopt(
      await HTTPSyncTransport.signIn(
        serverURL: serverURL, email: email, password: password, deviceName: deviceName, platform: platform,
        session: urlSession))
  }

  /// Asks for a password-reset email for `email` on `serverURL`, and returns
  /// the email as sent, trimmed. The server answers alike whether or not the
  /// account exists; see `passwordResetSentMessage(for:)`.
  @discardableResult
  public func requestPasswordReset(email: String, serverURL: URL = SyncServer.defaultURL) async throws -> String {
    let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !email.isEmpty else { throw SyncError.invalid("Enter your email first.") }
    try await HTTPSyncTransport.requestPasswordReset(serverURL: serverURL, email: email, session: urlSession)
    return email
  }

  /// What to show once a reset was asked for. It can't say the account
  /// exists, because the server doesn't say.
  public static func passwordResetSentMessage(for email: String) -> String {
    "If there's an account for \(email), we've sent a link to reset its password. It works for an hour."
  }

  /// Joins with a link minted by a signed-in device.
  public func pair(with link: SyncPairingLink) async throws {
    try await pair(code: link.code, serverURL: link.serverURL)
  }

  /// Joins with a code typed from a signed-in device's screen. A whole
  /// pairing link pasted into the same field works too, and names its own
  /// server.
  public func pair(codeOrLink typed: String, serverURL: URL = SyncServer.defaultURL) async throws {
    if let link = SyncPairingLink(typed) { return try await pair(with: link) }
    let code = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else { throw SyncError.invalid("Enter the code shown on your other device.") }
    try await pair(code: code, serverURL: serverURL)
  }

  private func pair(code: String, serverURL: URL) async throws {
    try adopt(
      await HTTPSyncTransport.pair(
        serverURL: serverURL, code: code, deviceName: deviceName, platform: platform, session: urlSession))
  }

  /// Mints a one-time code another device can join with.
  public func makePairingLink() async throws {
    let code = try await signedInCall { try await $0.createPairingCode() }
    guard let credentials else { return }
    pairingLink = SyncPairingLink(serverURL: credentials.serverURL, code: code.code)
    pairingCodeExpiresAt = code.expiryDate
  }

  /// Fetches the account's email and devices.
  public func refreshAccount() async throws {
    account = try await signedInCall { try await $0.account() }
  }

  /// Signs this device out. The server forgets its token (if it can be
  /// reached; signing out offline still works here), and the workspace stays
  /// on this device as it is.
  public func signOut() async {
    if let credentials {
      _ = try? await HTTPSyncTransport(credentials: credentials, session: urlSession).signOut()
    }
    try? forget()
  }

  /// Deletes the account: its rows on the server and every device's sign-in.
  /// Each device keeps its own copy of the workspace.
  public func deleteAccount(password: String) async throws {
    guard !password.isEmpty else { throw SyncError.invalid("Enter your password to delete the account.") }
    try await signedInCall { try await $0.deleteAccount(password: password) }
    try forget()
    rememberedEmail = nil
    rememberedServerURL = nil
  }

  // MARK: - Internals

  private func engine(for credentials: SyncCredentials) -> SyncEngine {
    SyncEngine(
      store: store, transport: HTTPSyncTransport(credentials: credentials, session: urlSession),
      deviceId: credentials.deviceId)
  }

  /// Runs an account call with this device's token, noticing a refusal.
  @discardableResult
  private func signedInCall<T>(_ call: (HTTPSyncTransport) async throws -> T) async throws -> T {
    guard let credentials else { throw SyncError.notPaired }
    do {
      return try await call(HTTPSyncTransport(credentials: credentials, session: urlSession))
    } catch SyncError.unauthorized {
      tokenWasRefused()
      throw SyncError.unauthorized
    }
  }

  private static func checked(email: String, password: String) throws -> String {
    let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !email.isEmpty else { throw SyncError.invalid("Enter your email address.") }
    guard !password.isEmpty else { throw SyncError.invalid("Enter your password.") }
    return email
  }

  private func adopt(_ credentials: SyncCredentials) throws {
    deactivate()
    try store.beginSync(deviceId: credentials.deviceId, serverURL: credentials.serverURL.absoluteString)
    try credentialStore.save(credentials)
    self.credentials = credentials
    rememberedEmail = credentials.email
    rememberedServerURL = credentials.serverURL
    account = nil
    pairingLink = nil
    pairingCodeExpiresAt = nil
    phase = .idle(lastSyncedAt: nil)
    activate()
  }

  /// Leaves sync on this device: no token, no outbox, the triggers off.
  private func forget() throws {
    deactivate()
    credentialStore.clear()
    credentials = nil
    account = nil
    pairingLink = nil
    pairingCodeExpiresAt = nil
    phase = .unpaired
    try store.endSync()
  }

  /// The server no longer knows this token. Syncing stops instead of
  /// retrying a request that can only fail, and the keychain item is kept,
  /// marked, so the email and server survive a relaunch for the sign-in
  /// form. The outbox keeps recording, so edits made meanwhile (deletes
  /// included) still go up after signing back in.
  private func tokenWasRefused() {
    guard var refused = credentials else { return }
    deactivate()
    refused.isSignedOut = true
    try? credentialStore.save(refused)
    credentials = nil
    account = nil
    pairingLink = nil
    pairingCodeExpiresAt = nil
    phase = .needsSignIn
  }

  private func report(_ status: SyncEngine.Status, _ outcome: SyncEngine.Outcome?) {
    guard credentials != nil else { return }
    switch status {
    case .idle(let last): phase = .idle(lastSyncedAt: last)
    case .syncing: phase = .syncing
    case .failed(let message): phase = .failed(message)
    case .signedOut: tokenWasRefused()
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
