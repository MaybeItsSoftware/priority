import AuthenticationServices
import CryptoKit
import Foundation
import Auth

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Who Supabase says is signed in.
public struct SyncAuthUser: Equatable, Sendable {
  public var id: String
  public var email: String?

  public init(id: String, email: String?) {
    self.id = id
    self.email = email
  }
}

/// The providers signed in to through Supabase's web flow.
public enum SyncOAuthProvider: String, Sendable {
  case google
  case apple
}

/// Accounts, as `SyncSession` needs them: signing in and out with Supabase,
/// and the access token the transport sends. `SupabaseSyncAuth` is the real
/// one; tests use a fake, so they never reach the network.
public protocol SyncAuthenticating: SyncAccessTokenProvider {
  /// The user of the stored session, if there is one. It may have expired.
  var currentUser: SyncAuthUser? { get }
  func signIn(email: String, password: String) async throws -> SyncAuthUser
  /// Makes an account. Nil when Supabase wants the address confirmed first,
  /// which it says by sending an email rather than a session.
  func signUp(email: String, password: String) async throws -> SyncAuthUser?
  /// Emails a link that opens the app signed in, to choose a new password.
  func resetPassword(email: String) async throws
  /// Google or Apple in a browser sheet. `SyncError.cancelled` when closed.
  func signIn(with provider: SyncOAuthProvider) async throws -> SyncAuthUser
  /// Sign in with Apple done natively: the identity token, and the nonce
  /// whose hash went into the request.
  func signInWithApple(idToken: String, nonce: String) async throws -> SyncAuthUser
  /// A link from one of Supabase's emails, opened in the app.
  func signIn(fromCallback url: URL) async throws -> SyncAuthUser
  func updatePassword(_ password: String) async throws
  /// Forgets the session here. Other devices stay signed in.
  func signOut() async
}

/// Supabase Auth, keeping its session in the Keychain.
public final class SupabaseSyncAuth: SyncAuthenticating {
  let client: AuthClient

  public init(
    projectURL: URL = SyncServer.supabaseURL, publishableKey: String = SyncServer.supabasePublishableKey,
    keychainService: String = "uk.co.maybeitsadam.priority.supabase"
  ) {
    client = AuthClient(
      url: projectURL.appending(path: "auth/v1"),
      headers: ["apikey": publishableKey],
      flowType: .pkce,
      redirectToURL: SyncServer.authCallbackURL,
      // The SDK's own Keychain storage, readable after first unlock so a
      // background refresh can sync.
      localStorage: KeychainLocalStorage(service: keychainService),
      // The transport asks for a token before every request, and that
      // refreshes one about to expire; no timer is needed besides.
      autoRefreshToken: false,
      emitLocalSessionAsInitialSession: true)
  }

  public var currentUser: SyncAuthUser? { client.currentSession.map { Self.user($0.user) } }

  public func accessToken() async throws -> String {
    do {
      return try await client.session.accessToken
    } catch {
      throw Self.refreshError(error)
    }
  }

  public func refreshedAccessToken() async throws -> String {
    do {
      return try await client.refreshSession().accessToken
    } catch {
      throw Self.refreshError(error)
    }
  }

  public func signIn(email: String, password: String) async throws -> SyncAuthUser {
    Self.user(try await client.signIn(email: email, password: password).user)
  }

  public func signUp(email: String, password: String) async throws -> SyncAuthUser? {
    switch try await client.signUp(email: email, password: password, redirectTo: SyncServer.authCallbackURL) {
    case .session(let session): Self.user(session.user)
    case .user: nil
    }
  }

  public func resetPassword(email: String) async throws {
    try await client.resetPasswordForEmail(email, redirectTo: SyncServer.authCallbackURL)
  }

  public func signIn(with provider: SyncOAuthProvider) async throws -> SyncAuthUser {
    let session = try await client.signInWithOAuth(
      provider: provider == .google ? .google : .apple, redirectTo: SyncServer.authCallbackURL
    ) { @MainActor url in
      try await WebSignIn.run(url, callbackScheme: SyncServer.authCallbackURL.scheme ?? "priority")
    }
    return Self.user(session.user)
  }

  public func signInWithApple(idToken: String, nonce: String) async throws -> SyncAuthUser {
    let session = try await client.signInWithIdToken(
      credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
    return Self.user(session.user)
  }

  public func signIn(fromCallback url: URL) async throws -> SyncAuthUser {
    Self.user(try await client.session(from: url).user)
  }

  public func updatePassword(_ password: String) async throws {
    try await client.update(user: UserAttributes(password: password))
  }

  public func signOut() async {
    // Local: signing this device out shouldn't sign out every other one.
    try? await client.signOut(scope: .local)
  }

  private static func user(_ user: User) -> SyncAuthUser {
    SyncAuthUser(id: user.id.uuidString.lowercased(), email: user.email)
  }

  /// A refresh Supabase refused, or no session to refresh, is signed out.
  /// Anything else, being offline above all, is only a failed attempt.
  static func refreshError(_ error: any Error) -> any Error {
    switch error as? AuthError {
    case .sessionMissing?:
      return SyncError.unauthorized
    case .api(_, _, _, let response)? where [400, 401, 403].contains(response.statusCode):
      return SyncError.unauthorized
    default:
      return error
    }
  }
}

/// A web sign-in in the system's browser sheet, hung from the key window.
/// The callback scheme needs no registering: the sheet catches the redirect
/// itself.
@MainActor
private final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  /// The sheet showing now, held so it lives until it answers.
  private static var current: ASWebAuthenticationSession?
  private static let anchor = WebSignIn()

  static func run(_ url: URL, callbackScheme: String) async throws -> URL {
    defer { current = nil }
    return try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { url, error in
        if let url {
          continuation.resume(returning: url)
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          continuation.resume(throwing: SyncError.cancelled)
        } else {
          continuation.resume(throwing: error ?? SyncError.cancelled)
        }
      }
      session.presentationContextProvider = anchor
      current = session
      if !session.start() {
        current = nil
        continuation.resume(throwing: SyncError.invalid("Couldn't open the sign-in window."))
      }
    }
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated { Self.keyWindow() }
  }

  private static func keyWindow() -> ASPresentationAnchor {
    #if canImport(UIKit)
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    #else
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #endif
  }
}

/// The nonce for Sign in with Apple: the request carries its SHA-256, and
/// Supabase checks the identity token against the original.
public enum SyncAppleNonce {
  public static func make(length: Int = 32) -> String {
    let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    var generator = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
  }

  public static func sha256(_ nonce: String) -> String {
    SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
