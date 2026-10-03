import Foundation
import Security

/// Where a device keeps what it knows about its sync sign-in, and its own
/// device id. On Apple platforms that is the Keychain, beside the Supabase
/// session, rather than the database or defaults.
public protocol SyncCredentialStore: Sendable {
  func load() -> SyncCredentials?
  func save(_ credentials: SyncCredentials) throws
  func clear()
  /// This device's id, made once and kept: through signing out, and through
  /// signing in to another account.
  func loadDeviceId() -> String?
  func saveDeviceId(_ id: String)
}

extension SyncCredentialStore {
  /// The device id, made and saved the first time it is asked for. A device
  /// signed in before the id had its own item keeps the id it had.
  public func deviceId() -> String {
    if let id = loadDeviceId() { return id }
    let legacy = load().flatMap { UUID(uuidString: $0.deviceId) }
    let id = (legacy ?? UUID()).uuidString.lowercased()
    saveDeviceId(id)
    return id
  }
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

  private func query(_ account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }

  private func read(_ account: String) -> Data? {
    var query = query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  private func write(_ data: Data, to account: String) throws {
    SecItemDelete(query(account) as CFDictionary)
    var item = query(account)
    item[kSecValueData as String] = data
    // Readable after first unlock, so background refresh can sync.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  public func load() -> SyncCredentials? {
    read("device").flatMap { try? JSONDecoder().decode(SyncCredentials.self, from: $0) }
  }

  public func save(_ credentials: SyncCredentials) throws {
    try write(JSONEncoder().encode(credentials), to: "device")
  }

  public func clear() {
    SecItemDelete(query("device") as CFDictionary)
  }

  public func loadDeviceId() -> String? {
    read("device-id").flatMap { String(data: $0, encoding: .utf8) }
  }

  public func saveDeviceId(_ id: String) {
    try? write(Data(id.utf8), to: "device-id")
  }
}

/// Credentials held in memory, for tests and previews.
public final class InMemorySyncCredentialStore: SyncCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var credentials: SyncCredentials?
  private var device: String?
  public init(_ credentials: SyncCredentials? = nil, deviceId: String? = nil) {
    self.credentials = credentials
    self.device = deviceId
  }
  public func load() -> SyncCredentials? { lock.withLock { credentials } }
  /// Through JSON, as the Keychain item is, so what isn't saved is lost.
  public func save(_ credentials: SyncCredentials) throws {
    let copy = try JSONDecoder().decode(SyncCredentials.self, from: JSONEncoder().encode(credentials))
    lock.withLock { self.credentials = copy }
  }
  public func clear() { lock.withLock { credentials = nil } }
  public func loadDeviceId() -> String? { lock.withLock { device } }
  public func saveDeviceId(_ id: String) { lock.withLock { device = id } }
}
