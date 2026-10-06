import Foundation
@testable import TaktSync
import TaktWorkspace
import XCTest

/// "Use a different server": what the three typed fields resolve to, how
/// the pair is checked before the app switches, and that switching signs the
/// device out of the old pair. See `docs/self-hosting.md`.
final class SyncEndpointsTests: XCTestCase {
  private var urlSession: URLSession!
  private var directory: URL!

  override func setUpWithError() throws {
    StubURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    urlSession = URLSession(configuration: configuration)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncEndpoints-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    StubURLProtocol.reset()
    try? FileManager.default.removeItem(at: directory)
  }

  private let own = SyncEndpoints(
    serverURL: URL(string: "https://sync.example.com")!, supabaseURL: URL(string: "https://abc.supabase.co")!,
    supabaseKey: "sb_publishable_own")

  // MARK: - Resolving what was typed

  func testBlankFieldsAreTaktsOwn() throws {
    XCTAssertEqual(try SyncEndpoints.resolve(server: "", supabaseURL: "", supabaseKey: ""), .hosted)
    XCTAssertEqual(try SyncEndpoints.resolve(server: "  ", supabaseURL: " \n", supabaseKey: ""), .hosted)
    XCTAssertTrue(SyncEndpoints.hosted.isHosted)
    XCTAssertTrue(SyncEndpoints.hosted.usesHostedAccounts)
  }

  func testAServerAloneKeepsTaktsAccounts() throws {
    let endpoints = try SyncEndpoints.resolve(server: "sync.example.com/", supabaseURL: "", supabaseKey: "")
    XCTAssertEqual(endpoints.serverURL.absoluteString, "https://sync.example.com")
    XCTAssertTrue(endpoints.usesHostedAccounts)
    XCTAssertFalse(endpoints.isHosted)
  }

  func testAllThreeAreNormalised() throws {
    let endpoints = try SyncEndpoints.resolve(
      server: " https://sync.example.com/takt/?x=1 ", supabaseURL: "abc.supabase.co/rest/v1/",
      supabaseKey: "  sb_publishable_own ")
    XCTAssertEqual(endpoints.serverURL.absoluteString, "https://sync.example.com/takt")
    XCTAssertEqual(endpoints.supabaseURL.absoluteString, "https://abc.supabase.co")
    XCTAssertEqual(endpoints.supabaseKey, "sb_publishable_own")
    XCTAssertFalse(endpoints.usesHostedAccounts)

    let pasted = try SyncEndpoints.resolve(
      server: "http://localhost:8080", supabaseURL: "http://127.0.0.1:54321/auth/v1", supabaseKey: "eyJhbGciOi.x.y")
    XCTAssertEqual(pasted.serverURL.absoluteString, "http://localhost:8080")
    XCTAssertEqual(pasted.supabaseURL.absoluteString, "http://127.0.0.1:54321")
  }

  func testWhatCantBeUsedSaysWhy() {
    let cases: [(String, String, String, String)] = [
      ("ftp://sync.example.com", "", "", "sync server address"),
      ("", "https://abc.supabase.co", "", "publishable key"),
      ("", "", "sb_publishable_own", "URL as well"),
      ("", "ftp://abc", "sb_publishable_own", "Supabase URL isn't"),
      ("", "https://abc.supabase.co", "sb_secret_oops", "secret key"),
      ("", "https://abc.supabase.co", "sb_publishable own", "space"),
    ]
    for (server, project, key, expected) in cases {
      XCTAssertThrowsError(try SyncEndpoints.resolve(server: server, supabaseURL: project, supabaseKey: key)) {
        XCTAssertTrue(
          $0.localizedDescription.contains(expected), "\($0.localizedDescription) should mention \(expected)")
      }
    }
  }

  func testSavedEndpointsFollowTheOldDefaultsMove() throws {
    let saved = #"{"serverURL":"https://priority-sync.up.railway.app","supabaseURL":"https://abc.supabase.co","supabaseKey":"k"}"#
    let decoded = try JSONDecoder().decode(SyncEndpoints.self, from: Data(saved.utf8))
    XCTAssertEqual(decoded.serverURL, SyncServer.defaultURL)
    XCTAssertEqual(try JSONDecoder().decode(SyncEndpoints.self, from: JSONEncoder().encode(own)), own)
  }

  // MARK: - Checking

  func testACheckAsksBothHalves() async throws {
    StubURLProtocol.respond(to: "/health", status: 200, body: #"{"ok":true}"#)
    StubURLProtocol.respond(to: "/auth/v1/settings", status: 200, body: #"{"external":{"email":true}}"#)
    try await SyncEndpointCheck.check(own, session: urlSession)
    XCTAssertEqual(
      StubURLProtocol.requests.map { "\($0.host ?? "")\($0.path)" },
      ["sync.example.com/health", "abc.supabase.co/auth/v1/settings"])
  }

  func testACheckSaysWhichHalfFailed() async throws {
    StubURLProtocol.respond(to: "/auth/v1/settings", status: 200, body: #"{"external":{}}"#)
    await assertCheckFails(containing: "/health")

    StubURLProtocol.respond(to: "/health", status: 200, body: #"{"ok":true}"#)
    StubURLProtocol.respond(to: "/auth/v1/settings", status: 401, body: #"{"message":"Invalid API key"}"#)
    await assertCheckFails(containing: "refused that key")

    StubURLProtocol.respond(to: "/auth/v1/settings", status: 404, body: "")
    await assertCheckFails(containing: "404")
  }

  private func assertCheckFails(containing expected: String, line: UInt = #line) async {
    do {
      try await SyncEndpointCheck.check(own, session: urlSession)
      XCTFail("the check passed", line: line)
    } catch {
      XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription, line: line)
    }
  }

  // MARK: - Switching

  @MainActor
  func testSwitchingSignsOutOfTheOldPairAndUsesTheNew() async throws {
    StubURLProtocol.respond(to: "/health", status: 200, body: #"{"ok":true}"#)
    StubURLProtocol.respond(to: "/auth/v1/settings", status: 200, body: #"{}"#)
    let store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("w.sqlite"))
    _ = try store.bootstrapIfNeeded()
    let keychain = InMemorySyncCredentialStore(deviceId: "5b0c2f0e-8a0e-4c1e-9d5e-0a1b2c3d4e5f")
    var made: [(SyncEndpoints, FakeAuth)] = []
    let session = SyncSession(
      store: store, credentialStore: keychain,
      makeAuth: { endpoints in
        let auth = FakeAuth()
        made.append((endpoints, auth))
        return auth
      },
      deviceName: "Mac", platform: "macos", urlSession: urlSession)
    XCTAssertEqual(session.endpoints, .hosted)
    XCTAssertEqual(made.map(\.0), [.hosted])

    try await session.signIn(email: "me@example.com", password: "pw")
    session.deactivate()
    XCTAssertEqual(session.credentials?.serverURL, SyncServer.defaultURL)

    try await session.use(own)
    XCTAssertFalse(session.isSignedIn)
    XCTAssertEqual(session.phase, .unpaired)
    XCTAssertNil(try store.syncState())
    XCTAssertEqual(made.first?.1.signOuts, 1, "signed out of Takt's project")
    XCTAssertEqual(made.map(\.0), [.hosted, own], "a client for the new project")
    XCTAssertEqual(keychain.loadEndpoints(), own)
    XCTAssertNotNil(StubURLProtocol.requests.first { $0.path == "/v1/sign-out" })

    try await session.signIn(email: "me@example.com", password: "pw")
    session.deactivate()
    XCTAssertEqual(session.credentials?.serverURL, own.serverURL)
    let register = try XCTUnwrap(StubURLProtocol.requests.last { $0.path == "/v1/devices" })
    XCTAssertEqual(register.host, "sync.example.com")

    // The same pair again changes nothing; going back forgets the saved one.
    try await session.use(own)
    XCTAssertTrue(session.isSignedIn)
    try await session.use(.hosted)
    XCTAssertNil(keychain.loadEndpoints())
    XCTAssertEqual(made.count, 3)

    // A relaunch keeps a chosen pair.
    keychain.saveEndpoints(own)
    let relaunched = SyncSession(
      store: store, credentialStore: keychain, auth: FakeAuth(), deviceName: "Mac", platform: "macos",
      urlSession: urlSession)
    XCTAssertEqual(relaunched.endpoints, own)
  }

  @MainActor
  func testAPairThatDoesntAnswerIsNotSwitchedTo() async throws {
    let store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("w.sqlite"))
    _ = try store.bootstrapIfNeeded()
    let keychain = InMemorySyncCredentialStore()
    let session = SyncSession(
      store: store, credentialStore: keychain, auth: FakeAuth(), deviceName: "Mac", platform: "macos",
      urlSession: urlSession)
    do {
      try await session.use(own)
      XCTFail("switched to a server with no /health")
    } catch {}
    XCTAssertEqual(session.endpoints, .hosted)
    XCTAssertNil(keychain.loadEndpoints())
  }

  @MainActor
  func testADeviceThatChoseOnlyAServerKeepsIt() throws {
    let store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("w.sqlite"))
    _ = try store.bootstrapIfNeeded()
    let keychain = InMemorySyncCredentialStore(
      SyncCredentials(serverURL: own.serverURL, deviceId: "d", isSignedOut: true))
    let session = SyncSession(
      store: store, credentialStore: keychain, auth: FakeAuth(), deviceName: "Mac", platform: "macos",
      urlSession: urlSession)
    XCTAssertEqual(session.endpoints.serverURL, own.serverURL)
    XCTAssertTrue(session.endpoints.usesHostedAccounts)
  }
}
