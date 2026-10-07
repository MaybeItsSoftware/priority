import Foundation
import OSLog
import TaktCore

/// Carries forward the state left behind when the app was renamed.
///
/// Renaming the app changed its bundle identifier, and on macOS that identifier
/// *is* the key to two stores the user's data lives in: `UserDefaults` resolves
/// to `~/Library/Preferences/<bundle id>.plist`, and the Application Support
/// container is named after the app. A rename therefore moves nothing — it
/// silently points the app at empty locations, and the first save writes that
/// emptiness back. Priorities, recurrence rules, the Checkvist list id, every
/// daily and the whole day log would appear to have been deleted by an update.
///
/// It has happened twice — Bar Tasker became Priority, and Priority became
/// Takt — and each name is still listed below, because someone can update
/// across both at once.
///
/// This runs before anything reads either store: first thing in
/// `TaktEntryPoint.main()`, before `MainApp` exists, so no stored-property
/// initialiser anywhere in the object graph can open a file at the new
/// location ahead of it. It is deliberately:
///
/// - **idempotent** — the Application Support copy stops the moment the new
///   location has an entry, so it is safe on every launch without a "have I
///   migrated yet?" flag. The preferences copy is the exception and *does*
///   keep a marker per legacy domain, because for preferences "the new
///   location has no value" is not a safe signal: a key the app has since
///   deliberately removed (the Checkvist remote key, once it moved to the
///   keychain) looks exactly like a key never copied, and re-copying it on
///   every launch resurrected it;
/// - **non-destructive** — the old preferences domain and the old directory are
///   left exactly where they are. If anything about the new name turns out to
///   be wrong, the previous state is still on disk. They are safe to delete by
///   hand once a rename has clearly settled.
///
/// The keychain is not touched. The Priority → Takt rename kept every keychain
/// service name as it was, so those items are found where they always were;
/// the Bar Tasker → Priority one is handled by `CheckvistCredentialStore`'s
/// legacy service list.
enum LegacyNameMigration {
  private static let logger = Logger(
    subsystem: AppIdentity.bundleIdentifier, category: "migration")

  /// Every identifier this app has shipped under, newest legacy name first.
  /// Append rather than replace: someone updating from two names ago has to
  /// land on their data too.
  private static let legacyBundleIdentifiers = [
    "uk.co.maybeitsadam.priority",
    "uk.co.maybeitsadam.bar-tasker",
  ]

  /// Application Support directory names matching those identifiers.
  private static let legacyDirectoryNames = ["Priority", "Bar Tasker"]

  private static let currentDirectoryName = AppIdentity.applicationSupportDirectoryName

  /// Suffixes SQLite gives the files that belong to a database: its
  /// write-ahead log, the log's index, and a rollback journal.
  private static let sqliteSidecarSuffixes = ["-wal", "-shm", "-journal"]

  static func runIfNeeded() {
    migratePreferences()
    migrateApplicationSupport()
  }

  // MARK: - Preferences

  /// The key under which a legacy domain is marked as already copied.
  static func preferencesMigrationMarkerKey(for identifier: String) -> String {
    "legacyPreferencesCopied.\(identifier)"
  }

  /// Copies keys the current domain does not already have, once per legacy
  /// domain.
  ///
  /// Key-by-key rather than wholesale so the copy can never clobber a value
  /// the new domain already holds. One-shot because the old domain is never
  /// cleared: without the marker this ran on every launch, and any key the
  /// app had removed on purpose in the meantime came straight back from the
  /// old plist. The marker is written in the *new* domain, so wiping the
  /// app's preferences wipes it too and the next launch migrates again —
  /// which is the right behaviour for a reset.
  private static func migratePreferences() {
    let defaults = UserDefaults.standard

    for identifier in legacyBundleIdentifiers {
      let markerKey = preferencesMigrationMarkerKey(for: identifier)
      guard defaults.object(forKey: markerKey) == nil else { continue }
      guard let legacy = defaults.persistentDomain(forName: identifier), !legacy.isEmpty else {
        continue
      }

      var copied = 0
      for (key, value) in legacy where defaults.object(forKey: key) == nil {
        defaults.set(value, forKey: key)
        copied += 1
      }
      defaults.set(true, forKey: markerKey)

      logger.notice(
        "Carried \(copied, privacy: .public) preference(s) forward from \(identifier, privacy: .public)"
      )
    }
  }

  // MARK: - Application Support

  /// Copies each entry the destination does not already have.
  ///
  /// Entry-by-entry rather than copying the directory wholesale, because the
  /// destination usually *already exists* by the time this runs: `AppDelegate`
  /// builds its object graph in stored-property initialisers, which Swift runs
  /// before `applicationDidFinishLaunching`, and `UserPluginManager` creates
  /// its `Plugins` subdirectory on the way up. A "does the destination exist?"
  /// guard therefore sees a directory containing nothing but `Plugins` and
  /// skips the copy — silently leaving every daily and the whole day log
  /// behind. Asking per entry makes the ordering irrelevant.
  ///
  /// Copied rather than moved: this holds the day log, which is append-only
  /// history that cannot be reconstructed, so leaving the original in place
  /// costs a few kilobytes and buys a way back.
  ///
  /// A SQLite database is several files, and they are copied as one: the
  /// `-wal` beside `priority.sqlite` holds every write since the last
  /// checkpoint, so the database without it is out of date, and a log laid
  /// beside a *different* database is corruption. A sidecar is therefore
  /// copied exactly when its database is, never on its own.
  private static func migrateApplicationSupport() {
    let manager = FileManager.default
    guard
      let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }

    let destination = base.appendingPathComponent(currentDirectoryName, isDirectory: true)

    for name in legacyDirectoryNames {
      let source = base.appendingPathComponent(name, isDirectory: true)
      guard
        let entries = try? manager.contentsOfDirectory(
          at: source, includingPropertiesForKeys: nil)
      else { continue }

      let names = Set(entries.map(\.lastPathComponent))
      var copied: [String] = []
      for entry in entries {
        let target = destination.appendingPathComponent(entry.lastPathComponent)
        // Sidecars travel with their database, below, and never on their own:
        // a log left without its database is worse than no log.
        if isSQLiteSidecar(entry.lastPathComponent, among: names) { continue }
        // Never overwrite: anything already at the new name is newer than the
        // old copy by definition, and clobbering it would be the data loss
        // this exists to prevent, in the other direction.
        guard !manager.fileExists(atPath: target.path) else { continue }
        do {
          try manager.createDirectory(at: destination, withIntermediateDirectories: true)
          try copyWithSidecars(entry, to: target, manager: manager)
          copied.append(entry.lastPathComponent)
        } catch {
          // Not fatal: the app comes up on an empty store, which is the same
          // state as a fresh install rather than a crash. Logged loudly
          // because it is the one failure that looks to a user like data loss.
          logger.error(
            "Could not carry \(entry.lastPathComponent, privacy: .public) forward from \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }

      if !copied.isEmpty {
        logger.notice(
          "Carried \(copied.count, privacy: .public) item(s) forward from \(name, privacy: .public): \(copied.joined(separator: ", "), privacy: .public)"
        )
      }
    }
  }

  /// Whether a file is a SQLite sidecar: named for a database beside it, or
  /// for a `.sqlite` file that is no longer there.
  private static func isSQLiteSidecar(_ name: String, among names: Set<String>) -> Bool {
    sqliteSidecarSuffixes.contains { suffix in
      guard name.hasSuffix(suffix) else { return false }
      let database = String(name.dropLast(suffix.count))
      return names.contains(database) || database.hasSuffix(".sqlite")
    }
  }

  /// Copies `source`, and its SQLite sidecars when it has any, all or
  /// nothing: if one part fails, the parts already copied are removed again,
  /// so the next launch retries from a clean slate rather than finding a
  /// database that "already exists" without its log.
  private static func copyWithSidecars(_ source: URL, to target: URL, manager: FileManager) throws {
    let pairs =
      [(source, target)]
      + sqliteSidecarSuffixes.compactMap { suffix in
        let sidecar = URL(fileURLWithPath: source.path + suffix)
        guard manager.fileExists(atPath: sidecar.path) else { return nil }
        return (sidecar, URL(fileURLWithPath: target.path + suffix))
      }
    var done: [URL] = []
    do {
      for (from, to) in pairs {
        try manager.copyItem(at: from, to: to)
        done.append(to)
      }
    } catch {
      for url in done { try? manager.removeItem(at: url) }
      throw error
    }
  }
}
