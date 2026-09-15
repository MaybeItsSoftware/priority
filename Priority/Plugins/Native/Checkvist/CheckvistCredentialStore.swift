import Foundation
import OSLog
import Security

final class CheckvistCredentialStore {
  static let keychainService = "uk.co.maybeitsadam.priority"

  /// Service names this app has previously stored credentials under, newest
  /// first. The keychain is keyed by service, so a rename orphans the item —
  /// the user is silently signed out and has to find their remote key again.
  /// Append here rather than replacing, so someone updating from two names ago
  /// still lands on their credentials.
  static let legacyKeychainServices = [
    "uk.co.maybeitsadam.bar-tasker",
    "uk.co.maybeitsadam.checkvist-focus",
  ]
  static let remoteKeyDefaultsKey = "checkvistRemoteKey"
  static let ignoreKeychainInDebugDefaultsKey = "ignoreKeychainInDebug"
  static let onboardingCompletedDefaultsKey = "onboardingCompleted"

  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "keychain")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String {
    if useKeychainStorageAtInit {
      // Keychain reads (and migrations that write to the keychain) may surface
      // a macOS password prompt for an item created by an older signature.
      // Keep app launch entirely credential-free; an intentional Connect or
      // "Use saved key" action performs this work instead.
      return ""
    }
    let stored = defaults.string(forKey: Self.remoteKeyDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !stored.isEmpty { return stored }
    // One-time migration off keychain: if a prior install stashed the key in
    // the keychain, copy it into UserDefaults and delete the keychain copy so
    // future launches never trigger a keychain access prompt.
    guard let migrated = keychainValue(forKey: Self.remoteKeyDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !migrated.isEmpty
    else { return "" }
    defaults.set(migrated, forKey: Self.remoteKeyDefaultsKey)
    deleteKeychainValue(forKey: Self.remoteKeyDefaultsKey)
    return migrated
  }

  /// Returns a user-facing description of the failure, or `nil` on success.
  ///
  /// Callers must surface a non-nil result. A silently-dropped keychain write is
  /// indistinguishable from a successful one until the next launch, when the app
  /// comes up signed out — which is exactly how the sandboxed release build
  /// managed to discard the remote key on every relaunch for days.
  @discardableResult
  func persistRemoteKey(_ value: String, useKeychainStorage: Bool) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if useKeychainStorage {
      if normalized.isEmpty {
        return deleteKeychainValue(forKey: Self.remoteKeyDefaultsKey)
      }
      return setKeychainValue(normalized, forKey: Self.remoteKeyDefaultsKey)
    }
    if normalized.isEmpty {
      defaults.removeObject(forKey: Self.remoteKeyDefaultsKey)
    } else {
      defaults.set(normalized, forKey: Self.remoteKeyDefaultsKey)
    }
    return nil
  }

  func persistRemoteKeyForDebugStorageMode(_ value: String) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      defaults.removeObject(forKey: Self.remoteKeyDefaultsKey)
    } else {
      defaults.set(normalized, forKey: Self.remoteKeyDefaultsKey)
    }
  }

  func loadRemoteKeyFromKeychain() -> String? {
    migrateLegacyRemoteKeyIntoKeychainIfNeeded()
    return keychainValue(forKey: Self.remoteKeyDefaultsKey)
  }

  private func migrateLegacyRemoteKeyIntoKeychainIfNeeded() {
    if let legacyKey = defaults.string(forKey: Self.remoteKeyDefaultsKey), !legacyKey.isEmpty {
      setKeychainValue(legacyKey, forKey: Self.remoteKeyDefaultsKey)
      defaults.removeObject(forKey: Self.remoteKeyDefaultsKey)
    }
  }

  private func keychainValue(forKey key: String) -> String? {
    let scopedQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var result: AnyObject?
    if SecItemCopyMatching(scopedQuery as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    {
      return String(data: data, encoding: .utf8)
    }

    // Compatibility: migrate entries scoped to any service name this app has
    // shipped under. Tried newest-first, and the old entry is removed once it
    // has been rewritten so a later rename doesn't have to walk the whole chain.
    for legacyService in Self.legacyKeychainServices {
      let legacyServiceQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: legacyService,
        kSecAttrAccount as String: key,
        kSecReturnData as String: true,
      ]
      var legacyServiceResult: AnyObject?
      if SecItemCopyMatching(legacyServiceQuery as CFDictionary, &legacyServiceResult)
        == errSecSuccess,
        let legacyData = legacyServiceResult as? Data,
        let legacyValue = String(data: legacyData, encoding: .utf8)
      {
        logger.notice("Migrating keychain item from \(legacyService, privacy: .public)")
        setKeychainValue(legacyValue, forKey: key)
        SecItemDelete(legacyServiceQuery as CFDictionary)
        return legacyValue
      }
    }

    // Compatibility: migrate legacy entries that were saved without kSecAttrService.
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var legacyResult: AnyObject?
    guard SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
      let legacyData = legacyResult as? Data,
      let legacyValue = String(data: legacyData, encoding: .utf8)
    else { return nil }
    setKeychainValue(legacyValue, forKey: key)
    SecItemDelete(legacyQuery as CFDictionary)
    return legacyValue
  }

  @discardableResult
  private func setKeychainValue(_ value: String, forKey key: String) -> String? {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: key,
    ]
    if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
      let status = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard status != errSecSuccess else { return nil }
      logger.error("SecItemUpdate failed for key \(key, privacy: .public): \(status)")
      return Self.failureDescription(status, verb: "update")
    }

    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    var status = SecItemAdd(add as CFDictionary, nil)

    // The probe above only sees items this code signature is allowed to read, so
    // an unreadable leftover — e.g. one written by a differently-signed build of
    // the same bundle — surfaces here rather than there. Replacing it is safe:
    // the item is ours by (service, account), we just couldn't read it back.
    if status == errSecDuplicateItem {
      logger.warning(
        "Replacing unreadable keychain item for key \(key, privacy: .public)")
      let deleteStatus = SecItemDelete(query as CFDictionary)
      if deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound {
        status = SecItemAdd(add as CFDictionary, nil)
      }
    }

    guard status != errSecSuccess else { return nil }
    logger.error("SecItemAdd failed for key \(key, privacy: .public): \(status)")
    return Self.failureDescription(status, verb: "save")
  }

  @discardableResult
  private func deleteKeychainValue(forKey key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: key,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status != errSecSuccess && status != errSecItemNotFound else { return nil }
    logger.error("SecItemDelete failed for key \(key, privacy: .public): \(status)")
    return Self.failureDescription(status, verb: "remove")
  }

  private static func failureDescription(_ status: OSStatus, verb: String) -> String {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    // -34018 is the one worth calling out by name: it means the app has no
    // keychain access group, which is a signing/entitlements problem rather than
    // anything the user can fix by retrying.
    if status == errSecMissingEntitlement {
      return
        "Couldn't \(verb) the Checkvist key in the keychain: the app is missing the keychain entitlement (\(detail)). Check the build's code signing."
    }
    return "Couldn't \(verb) the Checkvist key in the keychain: \(detail)"
  }
}
