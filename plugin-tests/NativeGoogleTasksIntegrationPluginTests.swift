import Foundation
import XCTest

@testable import PriorityPlugins

@MainActor
final class NativeGoogleTasksIntegrationPluginTests: XCTestCase {
  /// The mirror pages through lists and tasks, so the query it builds is the
  /// difference between reading a whole list and reading its first hundred.
  func testListRequestsCarryTheirPagingCursor() throws {
    let url = try NativeGoogleTasksIntegrationPlugin.makeURL(
      root: "https://tasks.googleapis.com/tasks/v1", "/lists/abc/tasks",
      query: [
        .init(name: "maxResults", value: "100"),
        .init(name: "pageToken", value: "next-page"),
        .init(name: "showDeleted", value: "true"),
      ])

    XCTAssertEqual(
      url.absoluteString,
      "https://tasks.googleapis.com/tasks/v1/lists/abc/tasks?maxResults=100&pageToken=next-page&showDeleted=true"
    )
  }

  /// The bug this pins: `URL(string:relativeTo:)` silently drops `v1` unless
  /// the base ends in a slash, and every request 404s against the real API.
  func testTaskURLKeepsTheAPIVersionInThePath() throws {
    let url = try NativeGoogleTasksIntegrationPlugin.makeURL(
      root: "https://tasks.googleapis.com/tasks/v1", "/users/@me/lists", query: [])

    XCTAssertEqual(url.absoluteString, "https://tasks.googleapis.com/tasks/v1/users/@me/lists")
  }

  func testCreateTaskRequiresASignedInAccount() async {
    let defaults = makeIsolatedDefaults()
    let plugin = NativeGoogleTasksIntegrationPlugin(
      account: GoogleAccount(defaults: defaults, legacyTokenStore: nil))

    do {
      _ = try await plugin.fetchTaskLists()
      XCTFail("Expected the mirror to require a Google client ID")
    } catch {
      XCTAssertEqual(
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        "Set a Google OAuth client ID first.")
    }
  }

  /// A grant made before Tasks existed is the failure a user cannot otherwise
  /// diagnose, so it has to read as "sign in again", not as a Google error.
  func testStatusSaysToSignInAgainWhenTheGrantPredatesTasks() {
    let defaults = makeIsolatedDefaults()
    let account = GoogleAccount(defaults: defaults, legacyTokenStore: nil)
    account.clientID = "client-123.apps.googleusercontent.com"
    let plugin = NativeGoogleTasksIntegrationPlugin(account: account)

    XCTAssertFalse(plugin.isAuthenticated)
    XCTAssertEqual(plugin.authenticationStatusDescription, "OAuth configured. Sign in required.")
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "priority-plugin-tests-google-tasks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}

@MainActor
final class GoogleAccountTests: XCTestCase {
  func testCallbackYieldsTheAuthorizationCode() throws {
    let url = URL(string: "http://127.0.0.1:8787/callback?code=abc123&state=xyz")!

    XCTAssertEqual(
      try GoogleAccount.extractAuthorizationCode(from: url, expectedState: "xyz"), "abc123")
  }

  func testCallbackRejectsAMismatchedState() {
    let url = URL(string: "http://127.0.0.1:8787/callback?code=abc123&state=someone-elses")!

    XCTAssertThrowsError(
      try GoogleAccount.extractAuthorizationCode(from: url, expectedState: "xyz")
    ) { error in
      XCTAssertEqual(error as? GoogleAccountError, .invalidState)
    }
  }

  /// The callback is reachable by anything that can hit the loopback port, so
  /// a repeated parameter must not be able to crash sign-in.
  func testCallbackKeepsTheFirstOfARepeatedParameter() throws {
    let url = URL(string: "http://127.0.0.1:8787/callback?code=first&code=second&state=xyz")!

    XCTAssertEqual(
      try GoogleAccount.extractAuthorizationCode(from: url, expectedState: "xyz"), "first")
  }

  func testCallbackSurfacesADeniedAuthorization() {
    let url = URL(string: "http://127.0.0.1:8787/callback?error=access_denied&state=xyz")!

    XCTAssertThrowsError(
      try GoogleAccount.extractAuthorizationCode(from: url, expectedState: "xyz")
    ) { error in
      XCTAssertEqual(error as? GoogleAccountError, .authorizationDenied("access_denied"))
    }
  }

  /// PKCE, against the worked example in RFC 7636 appendix B.
  func testCodeChallengeMatchesTheRFCExample() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    XCTAssertEqual(
      GoogleAccount.makePKCECodeChallenge(from: verifier),
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  func testGrantedScopesSplitTheStoredScopeString() {
    let payload = GoogleOAuthTokenPayload(
      accessToken: "a", refreshToken: "r", expiryDate: .now,
      grantedScopes: "\(GoogleAPIScope.tasks) \(GoogleAPIScope.calendarEvents)",
      clientID: "c")

    XCTAssertTrue(GoogleAPIScope.taskLists.isSubset(of: payload.scopes))
    XCTAssertFalse(GoogleAPIScope.calendar.isSubset(of: payload.scopes))
  }
}
