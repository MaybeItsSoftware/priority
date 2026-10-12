import Foundation
import Observation
import TaktCore

/// Checkvist, as far as the app still needs it: the account, its lists, and
/// copying those lists into the workspace.
///
/// What this replaced was the Checkvist-era task stack (`TaskRepository`,
/// `SyncService`, `TaskMutationService` and the offline store), which kept a
/// list's tasks in memory and wrote back to Checkvist. The workspace is the
/// only task model now, so Checkvist is an import source and nothing more:
/// requests and answers are the Rust core's (`core/src/checkvist.rs`), sent by
/// `NativeCheckvistSyncPlugin`; the remote key stays in the keychain.
@MainActor
@Observable final class CheckvistAccount {
  @ObservationIgnored let plugin: any CheckvistSyncPlugin
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let defaults: UserDefaults
  /// Whether the key goes to the keychain; read when it is saved, because a
  /// debug build can switch it at runtime.
  @ObservationIgnored var usesKeychainStorage: () -> Bool = { true }
  /// Told when the account the app signs in with changes, and whether the
  /// `takt` command's seeded copy of it is now stale: a new name always makes
  /// it so, a new key only when the key was cleared (signing out).
  @ObservationIgnored var onCredentialsChanged: ((_ seedIsStale: Bool) -> Void)?
  /// Told every failure, for the diagnostics log; `errorMessage` keeps only the
  /// last one.
  @ObservationIgnored var onErrorMessageSet: ((String) -> Void)?

  private static let excludedImportListIDsKey = "checkvistImportExcludedListIDsV1"

  var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      preferencesStore.set(isEnabled, for: .checkvistIntegrationEnabled)
    }
  }

  var username: String {
    didSet {
      guard username != oldValue else { return }
      preferencesStore.set(username, for: .checkvistUsername)
      // The settings field writes this on every keystroke. The token belongs to
      // the name it was fetched with, so it is dropped once, when the name
      // first departs from the one the session has been using.
      let typed = CheckvistCredentials(username: username, remoteKey: "").normalizedUsername
      guard let inUse = usernameInUse, typed != inUse else { return }
      usernameInUse = nil
      plugin.clearAuthentication()
      onCredentialsChanged?(true)
    }
  }
  @ObservationIgnored private var usernameInUse: String?

  var remoteKey: String {
    didSet {
      guard remoteKey != oldValue, !isLoadingStoredKey else { return }
      plugin.clearAuthentication()
      let trimmed = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
      onCredentialsChanged?(trimmed.isEmpty)
      if let failure = plugin.persistRemoteKey(remoteKey, useKeychainStorage: usesKeychainStorage()) {
        errorMessage = failure
      }
    }
  }
  @ObservationIgnored private var isLoadingStoredKey = false
  @ObservationIgnored private var hasAttemptedKeyBootstrap = false

  /// The list the `takt` command's Checkvist tools default to, seeded into its
  /// config by the MCP setup. It used to be the list the app synced with.
  var defaultListId: String {
    didSet {
      guard defaultListId != oldValue else { return }
      preferencesStore.set(defaultListId, for: .checkvistListId)
    }
  }

  var availableLists: [CheckvistList] = []
  var isLoading = false
  var errorMessage: String? {
    didSet {
      if let errorMessage, !errorMessage.isEmpty, errorMessage != oldValue {
        onErrorMessageSet?(errorMessage)
      }
    }
  }
  /// When lists last loaded. In memory only: it answers "is this current?"
  /// for this run of the app.
  private(set) var lastSuccessfulLoadAt: Date?

  /// Checkvist lists the user has asked not to copy into the workspace.
  /// Stored as exclusions so a list that appears on Checkvist later is copied
  /// by default, as every list always was.
  var excludedImportListIDs: Set<String> {
    didSet {
      defaults.set(Array(excludedImportListIDs).sorted(), forKey: Self.excludedImportListIDsKey)
    }
  }

  init(
    plugin: any CheckvistSyncPlugin,
    preferencesStore: PreferencesStore,
    initialRemoteKey: String,
    defaults: UserDefaults = .standard
  ) {
    self.plugin = plugin
    self.preferencesStore = preferencesStore
    self.defaults = defaults
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedListId = preferencesStore.string(.checkvistListId)
    let hasLegacyCheckvist =
      !storedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    self.isEnabled = preferencesStore.optionalBool(.checkvistIntegrationEnabled) ?? hasLegacyCheckvist
    self.username = storedUsername
    self.defaultListId = storedListId
    self.remoteKey = initialRemoteKey
    self.excludedImportListIDs = Set(defaults.stringArray(forKey: Self.excludedImportListIDsKey) ?? [])
  }

  // MARK: - State

  var hasCredentials: Bool {
    !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Whether the app should reach Checkvist on its own: switched on and signed
  /// in.
  var canImport: Bool { isEnabled && hasCredentials }

  var connectionState: CheckvistConnectionState {
    if !hasCredentials { return .disconnected }
    if availableLists.isEmpty {
      return isLoading ? .connecting : .awaitingConnect
    }
    return .connected(listCount: availableLists.count)
  }

  /// Every request reads this, which is what makes it the place to note which
  /// name the session is signed in under; see `username`.
  var activeCredentials: CheckvistCredentials {
    let credentials = CheckvistCredentials(username: username, remoteKey: remoteKey)
    usernameInUse = credentials.normalizedUsername
    return credentials
  }

  func isImportEnabled(listId: Int) -> Bool {
    !excludedImportListIDs.contains(String(listId))
  }

  func setImportEnabled(_ enabled: Bool, listId: Int) {
    if enabled {
      excludedImportListIDs.remove(String(listId))
    } else {
      excludedImportListIDs.insert(String(listId))
    }
  }

  // MARK: - Keychain

  /// Reads the saved key, once, only when the user asks: a stale code
  /// signature on the keychain item would otherwise prompt at launch.
  func loadRemoteKeyFromKeychainIfNeeded() {
    guard usesKeychainStorage(),
      remoteKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !hasAttemptedKeyBootstrap
    else { return }
    hasAttemptedKeyBootstrap = true
    guard let stored = plugin.loadRemoteKeyFromKeychain(), !stored.isEmpty else { return }
    isLoadingStoredKey = true
    remoteKey = stored
    isLoadingStoredKey = false
  }

  /// The settings button: always reads, even after an earlier attempt.
  func loadCredentialsFromKeychain() {
    hasAttemptedKeyBootstrap = false
    loadRemoteKeyFromKeychainIfNeeded()
  }

  /// A debug build switched between the keychain and the preferences plist.
  func credentialStorageModeChanged() {
    let current = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if usesKeychainStorage() {
      if !current.isEmpty {
        if let failure = plugin.persistRemoteKey(current, useKeychainStorage: true) {
          errorMessage = failure
        }
      } else {
        loadCredentialsFromKeychain()
      }
    } else {
      plugin.persistRemoteKeyForDebugStorageMode(current)
    }
  }

  // MARK: - Requests

  /// Signs in and loads the account's lists. Returns whether both worked.
  @discardableResult
  func loadLists() async -> Bool {
    let credentials = activeCredentials
    guard !credentials.normalizedUsername.isEmpty, !credentials.normalizedRemoteKey.isEmpty else {
      errorMessage = "Username or Remote Key is missing."
      return false
    }
    errorMessage = nil
    isLoading = true
    defer { isLoading = false }
    do {
      guard try await plugin.login(credentials: credentials) else {
        errorMessage = "Login failed. Check your credentials."
        return false
      }
    } catch {
      errorMessage = "Network error: \(error.localizedDescription)"
      return false
    }
    do {
      availableLists = try await plugin.fetchLists(credentials: activeCredentials)
      lastSuccessfulLoadAt = .now
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      errorMessage = "Checkvist needs you to sign in again. Check your credentials in Settings."
      return false
    } catch {
      errorMessage = "Failed to fetch lists: \(error.localizedDescription)"
      return false
    }
  }

  /// A list's open tasks, parents before their children.
  func openTasks(listId: Int) async throws -> [CheckvistTask] {
    try await plugin.fetchOpenTasks(listId: String(listId), credentials: activeCredentials)
  }

  /// Fetches the lists to copy into the workspace: every loaded list the user
  /// has not excluded and `alreadyImported` does not hold. A list that fails
  /// is reported through `onFailure` and skipped; the rest still come in.
  func importSnapshots(
    alreadyImported: Set<String>,
    onFailure: (CheckvistList, Error) -> Void
  ) async -> [(list: CheckvistList, tasks: [CheckvistTask])] {
    var snapshots: [(list: CheckvistList, tasks: [CheckvistTask])] = []
    for list in availableLists
    where isImportEnabled(listId: list.id)
      && !alreadyImported.contains(String(list.id))
    {
      do {
        snapshots.append((list, try await openTasks(listId: list.id)))
      } catch {
        onFailure(list, error)
      }
    }
    return snapshots
  }

  /// Signs out of this session without forgetting the saved key.
  func signOut() {
    plugin.clearAuthentication()
    availableLists = []
    errorMessage = nil
  }
}

extension CheckvistAccount: IntegrationDataSource {
  var listId: String { defaultListId }
}
