import Foundation
import PrioritySync
import PriorityWorkspace
import XCTest

/// The account routes from `docs/sync.md` ("Accounts", "POST /v1/pair") as
/// the transport sends and reads them, and what the session does with the
/// answers — above all, that a refused token stops sync rather than retrying.
final class SyncTransportTests: XCTestCase {
  private let server = URL(string: "https://sync.example.com")!
  private var urlSession: URLSession!
  private var directory: URL!

  override func setUpWithError() throws {
    StubURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    urlSession = URLSession(configuration: configuration)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTransport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    StubURLProtocol.reset()
    try? FileManager.default.removeItem(at: directory)
  }

  private let signedIn = #"{"accountId":"acc-1","email":"me@example.com","deviceId":"dev-1","token":"tok-1"}"#

  private func credentials(token: String = "tok-1") -> SyncCredentials {
    SyncCredentials(serverURL: server, deviceId: "dev-1", token: token, accountId: "acc-1", email: "me@example.com")
  }

  // MARK: - Transport

  func testSignUpPostsTheFormAndKeepsTheAccountWithTheToken() async throws {
    StubURLProtocol.respond(to: "/v1/accounts", status: 200, body: signedIn)
    let result = try await HTTPSyncTransport.signUp(
      serverURL: server, email: "me@example.com", password: "correct horse", deviceName: "Mac", platform: "macos",
      session: urlSession)

    XCTAssertEqual(result, credentials())
    let request = try XCTUnwrap(StubURLProtocol.requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertNil(request.authorization)
    XCTAssertEqual(
      request.json,
      ["email": "me@example.com", "password": "correct horse", "deviceName": "Mac", "platform": "macos"])
  }

  func testSignInGoesToSessions() async throws {
    StubURLProtocol.respond(to: "/v1/sessions", status: 200, body: signedIn)
    _ = try await HTTPSyncTransport.signIn(
      serverURL: server, email: "me@example.com", password: "pw123456", deviceName: "Mac", platform: "macos",
      session: urlSession)
    XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/sessions"])
  }

  func testRefusalsCarryTheServersOwnMessage() async throws {
    StubURLProtocol.respond(to: "/v1/sessions", status: 401, body: #"{"error":"wrong email or password"}"#)
    StubURLProtocol.respond(
      to: "/v1/accounts", status: 409, body: #"{"error":"there is already an account with that email; sign in instead"}"#)

    do {
      _ = try await HTTPSyncTransport.signIn(
        serverURL: server, email: "me@example.com", password: "nope nope", deviceName: "Mac", platform: "macos",
        session: urlSession)
      XCTFail("a wrong password signed in")
    } catch {
      // A wrong password at sign-in is a message to show, not a dead token.
      XCTAssertEqual(error as? SyncError, .server(status: 401, message: "wrong email or password"))
      XCTAssertEqual(error.localizedDescription, "Wrong email or password.")
    }

    do {
      _ = try await HTTPSyncTransport.signUp(
        serverURL: server, email: "me@example.com", password: "pw123456", deviceName: "Mac", platform: "macos",
        session: urlSession)
      XCTFail("a taken email signed up")
    } catch {
      XCTAssertEqual(error.localizedDescription, "There is already an account with that email; sign in instead.")
    }
  }

  func testABodyWithoutAMessageStillSaysWhatHappened() async throws {
    StubURLProtocol.respond(to: "/v1/sessions", status: 502, body: "<html>bad gateway</html>")
    do {
      _ = try await HTTPSyncTransport.signIn(
        serverURL: server, email: "a@b.co", password: "pw123456", deviceName: "Mac", platform: "macos",
        session: urlSession)
      XCTFail("a 502 signed in")
    } catch {
      XCTAssertEqual(error.localizedDescription, "The sync server answered 502.")
    }
  }

  func testPairingSendsOnlyTheCodeAndAnswersLikeSigningIn() async throws {
    StubURLProtocol.respond(to: "/v1/pair", status: 200, body: signedIn)
    let result = try await HTTPSyncTransport.pair(
      serverURL: server, code: "ABCD-EFGH", deviceName: "Adam's iPhone", platform: "ios", session: urlSession)
    XCTAssertEqual(result.email, "me@example.com")
    XCTAssertEqual(result.accountId, "acc-1")
    XCTAssertEqual(
      StubURLProtocol.requests.first?.json, ["code": "ABCD-EFGH", "deviceName": "Adam's iPhone", "platform": "ios"])
  }

  func testAccountListsDevicesWithTheServersTimestamps() async throws {
    StubURLProtocol.respond(
      to: "/v1/account", status: 200,
      body: """
        {"accountId":"acc-1","email":"me@example.com","devices":[
          {"id":"dev-1","name":"Mac","platform":"macos","createdAt":"2026-10-03T09:00:00.123456789Z",
           "lastSeenAt":"2026-10-03T10:00:00Z","current":true},
          {"id":"dev-2","name":null,"platform":"android","createdAt":"2026-10-03T09:30:00.5Z",
           "lastSeenAt":null,"current":false}]}
        """)
    let account = try await HTTPSyncTransport(credentials: credentials(), session: urlSession).account()

    XCTAssertEqual(StubURLProtocol.requests.first?.method, "GET")
    XCTAssertEqual(StubURLProtocol.requests.first?.authorization, "Bearer tok-1")
    XCTAssertEqual(account.email, "me@example.com")
    XCTAssertEqual(account.devices.map(\.current), [true, false])
    XCTAssertEqual(account.devices[1].displayName, "Android")
    let created = try XCTUnwrap(account.devices[0].createdDate)
    XCTAssertEqual(created.timeIntervalSince1970, 1_791_018_000.123, accuracy: 0.001)
    XCTAssertNotNil(account.devices[0].lastSeenDate)
    XCTAssertNotNil(account.devices[1].createdDate)
    XCTAssertNil(account.devices[1].lastSeenDate)
  }

  func testPairingCodeExpiryParses() async throws {
    StubURLProtocol.respond(
      to: "/v1/pairing-codes", status: 200, body: #"{"code":"ABCD-EFGH","expiresAt":"2026-10-03T09:10:00.987654Z"}"#)
    let code = try await HTTPSyncTransport(credentials: credentials(), session: urlSession).createPairingCode()
    XCTAssertEqual(code.code, "ABCD-EFGH")
    XCTAssertNotNil(code.expiryDate)
    XCTAssertEqual(StubURLProtocol.requests.first?.authorization, "Bearer tok-1")
  }

  func testA401OnADeviceRouteMeansTheTokenIsGone() async throws {
    StubURLProtocol.respond(to: "/v1/push", status: 401, body: #"{"error":"missing or unknown bearer token"}"#)
    do {
      _ = try await HTTPSyncTransport(credentials: credentials(), session: urlSession).push([])
      XCTFail("pushed with a dead token")
    } catch {
      XCTAssertEqual(error as? SyncError, .unauthorized)
    }
  }

  func testDeletingWithTheWrongPasswordIsNotASignOut() async throws {
    StubURLProtocol.respond(to: "/v1/account/delete", status: 401, body: #"{"error":"wrong email or password"}"#)
    let transport = HTTPSyncTransport(credentials: credentials(), session: urlSession)
    do {
      try await transport.deleteAccount(password: "nope nope")
      XCTFail("deleted with a wrong password")
    } catch {
      XCTAssertEqual(error as? SyncError, .server(status: 401, message: "wrong email or password"))
    }
    XCTAssertEqual(StubURLProtocol.requests.first?.json, ["password": "nope nope"])

    StubURLProtocol.respond(to: "/v1/account/delete", status: 200, body: #"{"ok":true}"#)
    try await transport.deleteAccount(password: "correct horse")
    StubURLProtocol.respond(to: "/v1/sign-out", status: 200, body: #"{"ok":true}"#)
    try await transport.signOut()
    XCTAssertEqual(StubURLProtocol.requests.last?.path, "/v1/sign-out")
    XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
  }

  func testCredentialsSavedBeforeAccountsStillLoad() throws {
    let old = #"{"serverURL":"https://sync.example.com","deviceId":"dev-1","token":"tok-1"}"#
    let decoded = try JSONDecoder().decode(SyncCredentials.self, from: Data(old.utf8))
    XCTAssertEqual(decoded, SyncCredentials(serverURL: server, deviceId: "dev-1", token: "tok-1"))
    XCTAssertFalse(decoded.isSignedOut)
    XCTAssertNil(decoded.email)
  }

  func testATypedServerAddressGetsAScheme() {
    XCTAssertEqual(SyncServer.url(from: " sync.example.com "), URL(string: "https://sync.example.com"))
    XCTAssertEqual(SyncServer.url(from: "http://localhost:8080"), URL(string: "http://localhost:8080"))
    XCTAssertNil(SyncServer.url(from: ""))
    XCTAssertNil(SyncServer.url(from: "ftp://example.com"))
    XCTAssertEqual(SyncServer.defaultURL.absoluteString, "https://priority-sync.up.railway.app")
  }

  // MARK: - Session

  private func store() throws -> WorkspaceStore {
    let store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("\(UUID().uuidString).sqlite"))
    _ = try store.bootstrapIfNeeded()
    return store
  }

  @MainActor
  func testSigningInPairsTheStoreAndSigningOutForgetsIt() async throws {
    StubURLProtocol.respond(to: "/v1/sessions", status: 200, body: signedIn)
    StubURLProtocol.respond(to: "/v1/sign-out", status: 200, body: #"{"ok":true}"#)
    let store = try store()
    let keychain = InMemorySyncCredentialStore()
    let session = SyncSession(
      store: store, credentialStore: keychain, deviceName: "Mac", platform: "macos", urlSession: urlSession)

    try await session.signIn(email: "  me@example.com ", password: "correct horse", serverURL: server)
    session.deactivate()
    XCTAssertTrue(session.isSignedIn)
    XCTAssertEqual(session.email, "me@example.com")
    XCTAssertEqual(keychain.load(), credentials())
    XCTAssertEqual(try store.syncState()?.deviceId, "dev-1")
    XCTAssertEqual(StubURLProtocol.requests.first { $0.path == "/v1/sessions" }?.json?["email"], "me@example.com")

    await session.signOut()
    XCTAssertEqual(session.phase, .unpaired)
    XCTAssertNil(keychain.load())
    XCTAssertNil(try store.syncState())
    XCTAssertEqual(StubURLProtocol.requests.last { $0.path == "/v1/sign-out" }?.authorization, "Bearer tok-1")
  }

  @MainActor
  func testEmptyFieldsAreCaughtBeforeTheServer() async throws {
    let session = SyncSession(
      store: try store(), credentialStore: InMemorySyncCredentialStore(), deviceName: "Mac", platform: "macos",
      urlSession: urlSession)
    do {
      try await session.signUp(email: " ", password: "x", serverURL: server)
      XCTFail("signed up without an email")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Enter your email address.")
    }
    XCTAssertTrue(StubURLProtocol.requests.isEmpty)
  }

  @MainActor
  func testARefusedTokenStopsSyncAndAsksForSignInAgain() async throws {
    StubURLProtocol.respond(to: "/v1/push", status: 401, body: #"{"error":"missing or unknown bearer token"}"#)
    StubURLProtocol.respond(to: "/v1/changes", status: 401, body: #"{"error":"missing or unknown bearer token"}"#)
    let store = try store()
    try store.beginSync(deviceId: "dev-1", serverURL: server.absoluteString)
    let keychain = InMemorySyncCredentialStore(credentials())
    let session = SyncSession(
      store: store, credentialStore: keychain, deviceName: "Mac", platform: "macos", urlSession: urlSession)
    XCTAssertTrue(session.isSignedIn)

    let synced = await session.syncNow()
    XCTAssertFalse(synced)
    XCTAssertEqual(session.phase, .needsSignIn)
    XCTAssertFalse(session.isSignedIn)
    XCTAssertEqual(session.rememberedEmail, "me@example.com")
    XCTAssertEqual(session.rememberedServerURL, server)
    XCTAssertEqual(keychain.load()?.isSignedOut, true)
    // The outbox keeps recording, so what changes meanwhile goes up later.
    XCTAssertNotNil(try store.syncState())

    // No further attempts: there is no token to try.
    let attempts = StubURLProtocol.requests.count
    session.activate()
    let retried = await session.syncNow()
    XCTAssertFalse(retried)
    XCTAssertEqual(StubURLProtocol.requests.count, attempts)

    // And it is still signed out after a relaunch.
    let relaunched = SyncSession(
      store: store, credentialStore: keychain, deviceName: "Mac", platform: "macos", urlSession: urlSession)
    XCTAssertEqual(relaunched.phase, .needsSignIn)
    XCTAssertEqual(relaunched.rememberedEmail, "me@example.com")
  }

  @MainActor
  func testAnAccountCallThatFindsTheTokenGoneSignsOutToo() async throws {
    StubURLProtocol.respond(to: "/v1/account", status: 401, body: #"{"error":"missing or unknown bearer token"}"#)
    let store = try store()
    try store.beginSync(deviceId: "dev-1", serverURL: server.absoluteString)
    let session = SyncSession(
      store: store, credentialStore: InMemorySyncCredentialStore(credentials()), deviceName: "Mac",
      platform: "macos", urlSession: urlSession)
    do {
      try await session.refreshAccount()
      XCTFail("read the account with a dead token")
    } catch {
      XCTAssertEqual(error as? SyncError, .unauthorized)
    }
    XCTAssertEqual(session.phase, .needsSignIn)
  }

  @MainActor
  func testDeletingTheAccountKeepsTheWorkspaceAndLeavesSync() async throws {
    StubURLProtocol.respond(to: "/v1/account/delete", status: 200, body: #"{"ok":true}"#)
    let store = try store()
    let workspaces = try store.workspaces()
    try store.beginSync(deviceId: "dev-1", serverURL: server.absoluteString)
    let keychain = InMemorySyncCredentialStore(credentials())
    let session = SyncSession(
      store: store, credentialStore: keychain, deviceName: "Mac", platform: "macos", urlSession: urlSession)

    try await session.deleteAccount(password: "correct horse")
    XCTAssertEqual(session.phase, .unpaired)
    XCTAssertNil(keychain.load())
    XCTAssertNil(try store.syncState())
    XCTAssertEqual(try store.workspaces(), workspaces)
  }

  @MainActor
  func testATypedCodeUsesTheChosenServerAndAPastedLinkItsOwn() async throws {
    StubURLProtocol.respond(to: "/v1/pair", status: 200, body: signedIn)
    let session = SyncSession(
      store: try store(), credentialStore: InMemorySyncCredentialStore(), deviceName: "Mac", platform: "macos",
      urlSession: urlSession)
    try await session.pair(codeOrLink: " abcd-efgh ", serverURL: server)
    session.deactivate()
    XCTAssertEqual(StubURLProtocol.requests.first?.host, "sync.example.com")
    XCTAssertEqual(StubURLProtocol.requests.first?.json?["code"], "abcd-efgh")

    let other = URL(string: "https://other.example.com")!
    try await session.pair(codeOrLink: SyncPairingLink(serverURL: other, code: "WXYZ-2345").url.absoluteString)
    session.deactivate()
    XCTAssertEqual(StubURLProtocol.requests.last { $0.path == "/v1/pair" }?.host, "other.example.com")
    XCTAssertEqual(session.credentials?.serverURL, other)
  }

  func testTheSchedulerStopsAfterARefusedToken() async throws {
    let transport = RefusingTransport()
    let store = try store()
    try store.beginSync(deviceId: "dev-1", serverURL: "memory://")
    let engine = SyncEngine(store: store, transport: transport, deviceId: "dev-1")
    let statuses = StatusLog()
    let scheduler = SyncScheduler(engine: engine) { status, _ in await statuses.append(status) }

    let first = await scheduler.syncNow()
    let second = await scheduler.syncNow()
    await scheduler.start()
    XCTAssertFalse(first)
    XCTAssertFalse(second)
    XCTAssertEqual(transport.calls, 1)
    let isSignedOut = await scheduler.isSignedOut
    XCTAssertTrue(isSignedOut)
    let last = await statuses.last
    XCTAssertEqual(last, .signedOut)
    let engineStatus = await engine.status
    XCTAssertEqual(engineStatus, .signedOut)
  }
}

private actor StatusLog {
  var all: [SyncEngine.Status] = []
  var last: SyncEngine.Status? { all.last }
  func append(_ status: SyncEngine.Status) { all.append(status) }
}

/// A server that has forgotten the device.
private final class RefusingTransport: SyncTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var calls: Int { lock.withLock { count } }

  func push(_ changes: [SyncPushChange]) async throws -> SyncPushResponse {
    lock.withLock { count += 1 }
    throw SyncError.unauthorized
  }

  func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesResponse {
    lock.withLock { count += 1 }
    throw SyncError.unauthorized
  }
}

/// Answers requests from a table of canned responses keyed by path, and
/// records what was asked. Paths without an answer get an empty sync page, so
/// a session that starts its rhythm in a test has something to talk to.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Recorded {
    var method: String
    var host: String?
    var path: String
    var authorization: String?
    var body: Data?
    var json: [String: String]? {
      body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var responses: [String: (Int, String)] = [:]
  nonisolated(unsafe) private static var recorded: [Recorded] = []

  static var requests: [Recorded] { lock.withLock { recorded } }

  static func respond(to path: String, status: Int, body: String) {
    lock.withLock { responses[path] = (status, body) }
  }

  static func reset() {
    lock.withLock {
      responses = [:]
      recorded = []
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let path = url.path()
    let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
    let canned = Self.lock.withLock { () -> (Int, String)? in
      Self.recorded.append(
        Recorded(
          method: request.httpMethod ?? "GET", host: url.host(), path: path,
          authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
      return Self.responses[path]
    }
    let (status, text) = canned ?? Self.fallback(for: path)
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    // A long-poll answered at once would spin the session's loop; hold it.
    let delay: TimeInterval = path == "/v1/changes" && url.query()?.contains("wait=25") == true ? 0.5 : 0
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [client] in
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(text.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  private static func fallback(for path: String) -> (Int, String) {
    switch path {
    case "/v1/push": (200, #"{"accepted":0,"cursor":0}"#)
    case "/v1/changes": (200, #"{"rows":[],"cursor":0,"hasMore":false}"#)
    default: (404, #"{"error":"not found"}"#)
    }
  }

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
