import Foundation
import Security

/// The tokens one Google sign-in leaves behind.
///
/// `grantedScopes` is what Google actually consented to, which is not always
/// what was asked for: a second integration added later gets its scope only
/// once the user signs in again. Storing it is what lets the app say "sign in
/// again to grant Tasks access" instead of failing with a 403 from the API.
struct GoogleOAuthTokenPayload: Codable, Sendable {
  let accessToken: String
  let refreshToken: String
  let expiryDate: Date
  let grantedScopes: String
  let clientID: String

  var scopes: Set<String> {
    Set(grantedScopes.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
  }
}

/// The keychain item behind a Google sign-in.
///
/// `account` is a parameter rather than a constant because the app kept its
/// first Google token under a Calendar-specific name, and the migration out of
/// that name has to be able to read both.
final class GoogleOAuthTokenStore {
  /// The product was Priority when this was chosen, and the name is kept on
  /// purpose: it is a storage key, not a label, and changing it would sign
  /// everyone out. The Takt rename left it — and every other keychain service
  /// — exactly as it was.
  private static let service = "uk.co.maybeitsadam.priority"
  /// Where a shared sign-in lives now: one account, however many Google APIs
  /// are switched on.
  static let sharedAccount = "googleOAuthTokenPayload"
  /// Where the Calendar integration used to keep its own token, before Tasks
  /// existed and made a single account worth having.
  static let legacyCalendarAccount = "googleCalendarOAuthTokenPayload"

  private let account: String

  init(account: String = GoogleOAuthTokenStore.sharedAccount) {
    self.account = account
  }

  func load() -> GoogleOAuthTokenPayload? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(GoogleOAuthTokenPayload.self, from: data)
  }

  func save(_ payload: GoogleOAuthTokenPayload) {
    guard let data = try? JSONEncoder().encode(payload) else { return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
    ]

    if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
      let attrs: [String: Any] = [kSecValueData as String: data]
      SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    } else {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
