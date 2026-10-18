import Foundation
import Observation

/// Linking tasks to Obsidian notes and folders and to Google Drive files and
/// folders. See docs/links.md.
///
/// The vaults come from Obsidian's own list, the folder the daily log writes
/// its notes into, and any added on the settings page. Drive search goes
/// through the shared `GoogleAccount` and is off until switched on, because
/// asking for its scope makes the next Google sign-in ask for it too.
@MainActor
@Observable
final class NativeLinksPlugin: LinksIntegrationPlugin {
  let pluginIdentifier = "native.links"
  let displayName = "Links"
  let pluginDescription = "Link tasks to Obsidian notes and folders, and to Google Drive files and folders."

  static let driveSearchDefaultsKey = "linksDriveSearchEnabled"
  static let extraVaultsDefaultsKey = "linksObsidianVaultPaths"

  let account: GoogleAccount
  @ObservationIgnored private let session: URLSession
  @ObservationIgnored private let defaults: UserDefaults
  /// Folders that say where a vault is without being one, such as the daily
  /// log's notes folder: the vault is the nearest ancestor with `.obsidian`.
  @ObservationIgnored var vaultHints: () -> [URL] = { [] }

  private(set) var obsidianVaults: [ObsidianVault] = []
  private(set) var obsidianEntries: [LinkCandidate] = []
  private(set) var isIndexing = false

  var isDriveSearchEnabled: Bool {
    didSet {
      defaults.set(isDriveSearchEnabled, forKey: Self.driveSearchDefaultsKey)
      if isDriveSearchEnabled { account.requireScopes(GoogleAPIScope.driveSearch) }
    }
  }

  /// Vault folders added by hand, beyond the ones Obsidian lists.
  var extraVaultPaths: [String] {
    didSet { defaults.set(extraVaultPaths, forKey: Self.extraVaultsDefaultsKey) }
  }

  init(account: GoogleAccount, session: URLSession = .shared, defaults: UserDefaults = .standard) {
    self.account = account
    self.session = session
    self.defaults = defaults
    self.isDriveSearchEnabled = defaults.bool(forKey: Self.driveSearchDefaultsKey)
    self.extraVaultPaths = defaults.stringArray(forKey: Self.extraVaultsDefaultsKey) ?? []
    if isDriveSearchEnabled { account.requireScopes(GoogleAPIScope.driveSearch) }
  }

  // MARK: - Obsidian

  func reloadObsidianIndex() async {
    isIndexing = true
    defer { isIndexing = false }
    let hints = vaultHints()
    let extra = extraVaultPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let (vaults, entries) = await Task.detached(priority: .userInitiated) {
      let vaults = ObsidianVaultIndex.discover(hints: hints, extra: extra)
      return (vaults, vaults.flatMap(ObsidianVaultIndex.entries(in:)))
    }.value
    obsidianVaults = vaults
    obsidianEntries = entries
  }

  // MARK: - Google Drive

  var canSearchDrive: Bool {
    isDriveSearchEnabled && account.hasGrantedScopes(GoogleAPIScope.driveSearch)
  }

  /// What the settings page says about Drive search.
  var driveStatusDescription: String {
    guard isDriveSearchEnabled else { return "Off. Pasting a Drive, Docs or Sheets address always works." }
    guard account.hasClientConfiguration else { return "Set a Google OAuth client ID to search Drive." }
    if account.hasGrantedScopes(GoogleAPIScope.driveSearch) { return "Searching Drive by name." }
    if account.isAuthenticated { return "Signed in before Drive search was on. Sign in again." }
    return "Sign in with Google to search Drive."
  }

  func searchDrive(matching text: String) async throws -> [LinkCandidate] {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSearchDrive, !text.isEmpty, var request = GoogleDriveSearch.request(for: text) else { return [] }
    let token = try await account.accessToken(requiring: GoogleAPIScope.driveSearch, service: "Google Drive")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw GoogleDriveSearchError.invalidResponse }
    if http.statusCode == 401 {
      account.invalidateAfterUnauthorized()
      throw GoogleAccountError.authenticationRequired
    }
    guard (200...299).contains(http.statusCode) else {
      throw GoogleDriveSearchError.apiError(
        String(data: data, encoding: .utf8) ?? "Google Drive answered \(http.statusCode).")
    }
    return try GoogleDriveSearch.candidates(from: data)
  }
}
