import Foundation
import Security

/// Where a device keeps its sync token. The token is a password in all but
/// name, so on Apple platforms it lives in the Keychain, not in the database
/// or in defaults.
public protocol SyncCredentialStore: Sendable {
  func load() -> SyncCredentials?
  func save(_ credentials: SyncCredentials) throws
  func clear()
}

public struct KeychainSyncCredentialStore: SyncCredentialStore {
  let service: String
  let accessGroup: String?

  /// `accessGroup` lets an app and its extensions share the item; nil keeps
  /// it to the calling app.
  public init(service: String = "uk.co.maybeitsadam.priority.sync", accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  private var query: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "device",
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }

  public func load() -> SyncCredentials? {
    var query = self.query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
    else { return nil }
    return try? JSONDecoder().decode(SyncCredentials.self, from: data)
  }

  public func save(_ credentials: SyncCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = data
    // Readable after first unlock, so background refresh can sync.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  public func clear() {
    SecItemDelete(query as CFDictionary)
  }
}

/// Credentials held in memory, for tests and previews.
public final class InMemorySyncCredentialStore: SyncCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var credentials: SyncCredentials?
  public init(_ credentials: SyncCredentials? = nil) { self.credentials = credentials }
  public func load() -> SyncCredentials? { lock.withLock { credentials } }
  public func save(_ credentials: SyncCredentials) throws { lock.withLock { self.credentials = credentials } }
  public func clear() { lock.withLock { credentials = nil } }
}
