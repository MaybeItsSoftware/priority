import Foundation

/// The security-scoped bookmark dance, once, for every plugin that remembers a
/// folder the user picked in an open panel (Obsidian's inbox and linked
/// folders, the daily-log notes folder).
///
/// The app is not sandboxed — `Takt.release.entitlements` has no
/// `app-sandbox` key — so `startAccessingSecurityScopedResource` is currently
/// a no-op that returns `false`. The bookmarks are still made with
/// `.withSecurityScope` and every access still goes through `withAccess`,
/// because that is what keeps the option of sandboxing open: the day the
/// entitlement is added, nothing here has to change. Until then the practical
/// value is that a bookmark survives the folder being moved or renamed, which
/// a stored path does not.
enum SecurityScopedFolderBookmark {
  /// Bookmark data for a folder the user has just chosen.
  static func make(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  /// Resolves bookmark data to a URL. If the OS reports the bookmark stale,
  /// a fresh one is minted and handed to `onStale` so the caller can persist
  /// it; the resolved URL is returned either way. A failure to re-mint is not
  /// a failure to resolve, so it is swallowed — the stale data still works
  /// this time, and the next resolve gets another go at refreshing it.
  static func resolve(_ bookmarkData: Data, onStale: ((Data) -> Void)? = nil) throws -> URL {
    var isStale = false
    let resolvedURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    if isStale, let onStale, let refreshed = try? make(for: resolvedURL) {
      onStale(refreshed)
    }
    return resolvedURL
  }

  /// The folder's current path, for display, or nil when there is no bookmark
  /// or it no longer resolves.
  static func path(from bookmarkData: Data?) -> String? {
    guard let bookmarkData else { return nil }
    return (try? resolve(bookmarkData))?.path
  }

  /// Runs `body` while holding security-scoped access to `url`. Every read or
  /// write under a bookmark-resolved folder — directory creation, probes,
  /// the write itself — must happen inside one of these, not just the step
  /// that assembles the destination URL.
  static func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return try body()
  }
}
