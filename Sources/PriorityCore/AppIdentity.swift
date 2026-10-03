import Foundation

/// The product's name and the identifiers derived from it, defined once.
///
/// The product was called Priority before it was Takt, and the code still is:
/// modules, targets and types keep the old name because renaming them buys
/// nothing a user can see. What a user *can* see — the app's name, where its
/// files live, what its logs are filed under — comes from here, so the next
/// rename is one file rather than a search.
public enum AppIdentity {
  /// The name a person sees: the app, its windows and menus.
  public static let displayName = "Takt"

  /// The Mac app's bundle identifier, which is also its log subsystem.
  public static let bundleIdentifier = "uk.co.maybeitssoftware.takt"

  /// The folder under `~/Library/Application Support` holding the workspace
  /// database, the day log, themes, the keymap, plugins and the rest.
  ///
  /// Earlier names are carried forward by the app's `LegacyNameMigration`,
  /// which copies their folders' contents in here before anything reads them.
  public static let applicationSupportDirectoryName = "Takt"

  /// `~/Library/Application Support/Takt/`. Not created here: callers that
  /// write into it create what they need.
  public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: applicationSupportDirectoryName, directoryHint: .isDirectory)
  }
}
