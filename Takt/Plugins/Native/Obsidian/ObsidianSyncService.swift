import AppKit
import Foundation

// `ObsidianOpenMode` moved to `ObsidianOpenMode.swift` so it can be shared
// with `TaktPlugins` / `TaktAppLogic` without AppKit-bound code.

final class ObsidianSyncService {
  private static let bookmarkDefaultsKey = "obsidianInboxBookmark"
  private static let linkedFolderBookmarksDefaultsKey = "obsidianLinkedFolderBookmarksByTaskId"
  private static let obsidianBundleIdentifier = "md.obsidian"
  private static let remoteTimestampParsers: [ISO8601DateFormatter] = {
    let internet = ISO8601DateFormatter()
    internet.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]

    let internetFractional = ISO8601DateFormatter()
    internetFractional.formatOptions = [
      .withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate,
    ]

    return [internetFractional, internet]
  }()
  private static let remoteDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter
  }()

  private var inboxBookmark: Data?
  private var linkedFolderBookmarksByTaskId: [Int: String]

  init(defaults: UserDefaults = .standard) {
    self.inboxBookmark = defaults.data(forKey: Self.bookmarkDefaultsKey)
    let rawLinkedBookmarks =
      (defaults.dictionary(forKey: Self.linkedFolderBookmarksDefaultsKey) as? [String: String])
      ?? [:]
    self.linkedFolderBookmarksByTaskId = rawLinkedBookmarks.reduce(into: [:]) { partialResult, entry in
      guard let taskId = Int(entry.key) else { return }
      partialResult[taskId] = entry.value
    }
  }

  var inboxPath: String {
    Self.pathFromBookmarkData(inboxBookmark) ?? ""
  }

  @MainActor
  func chooseInboxFolder() throws -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Inbox"
    panel.message = "Select your Obsidian Inbox folder."

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }

    let bookmark = try selectedURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )

    inboxBookmark = bookmark
    UserDefaults.standard.set(bookmark, forKey: Self.bookmarkDefaultsKey)
    return selectedURL.path
  }

  func clearInboxFolder() {
    inboxBookmark = nil
    UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
  }

  @MainActor
  func chooseLinkedFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Link Folder"
    panel.message = "Select the Obsidian folder to use for \"\(taskContent)\" and its subtasks."

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }

    let bookmark = try selectedURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )

    linkedFolderBookmarksByTaskId[taskId] = bookmark.base64EncodedString()
    persistLinkedFolderBookmarks()
    return selectedURL.path
  }

  @MainActor
  func createAndLinkFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Parent"
    panel.message =
      "Choose where to create a new Obsidian folder for \"\(taskContent)\" and link it."

    guard panel.runModal() == .OK, let parentURL = panel.url else { return nil }

    let accessed = parentURL.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        parentURL.stopAccessingSecurityScopedResource()
      }
    }

    let preferredName = sanitizeTaskFileName(taskContent)
    let createdFolderURL = try uniqueFolderURL(in: parentURL, preferredName: preferredName)
    try FileManager.default.createDirectory(at: createdFolderURL, withIntermediateDirectories: true)

    let bookmark = try createdFolderURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )

    linkedFolderBookmarksByTaskId[taskId] = bookmark.base64EncodedString()
    persistLinkedFolderBookmarks()
    return createdFolderURL.path
  }

  func clearLinkedFolder(forTaskId taskId: Int) {
    linkedFolderBookmarksByTaskId.removeValue(forKey: taskId)
    persistLinkedFolderBookmarks()
  }

  func linkedFolderPath(forTaskId taskId: Int) -> String? {
    guard let bookmark = bookmarkDataForLinkedTask(taskId) else { return nil }
    return Self.pathFromBookmarkData(bookmark)
  }

  func hasLinkedFolder(forTaskId taskId: Int) -> Bool {
    linkedFolderPath(forTaskId: taskId) != nil
  }

  func hasSyncedNote(task: CheckvistTask, linkedFolderTaskId: Int?) -> Bool {
    guard
      let destinationFolderURL = try? resolvedDestinationFolderURL(
        linkedFolderTaskId: linkedFolderTaskId)
    else { return false }
    return withSecurityScope(destinationFolderURL) {
      guard
        let markdownURL = try? noteFileURL(
          task: task,
          destinationFolderURL: destinationFolderURL,
          createDirectoryIfNeeded: false
        )
      else { return false }
      return FileManager.default.fileExists(atPath: markdownURL.path)
    }
  }

  func syncTask(
    _ task: CheckvistTask,
    listId: String,
    linkedFolderTaskId: Int? = nil,
    openMode: ObsidianOpenMode = .standard,
    syncDate: Date = Date()
  ) throws -> URL {
    let inboxURL = try resolvedDestinationFolderURL(linkedFolderTaskId: linkedFolderTaskId)
    // The security scope must stay held across the directory creation, the
    // creation-date probe *and* the write — not just while the destination URL
    // is being assembled. Release builds are sandboxed
    // (`Priority.release.entitlements`), so file access outside this window is
    // denied even though it succeeds in unsandboxed Debug builds.
    let markdownURL = try withSecurityScope(inboxURL) {
      try writeTaskMarkdown(
        task: task,
        listId: listId,
        inboxURL: inboxURL,
        syncDate: syncDate
      )
    }
    openInObsidian(markdownURL, mode: openMode)
    return markdownURL
  }

  /// Runs `body` while holding security-scoped access to `url`. Every read or
  /// write under a bookmark-resolved folder must happen inside one of these.
  private func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return try body()
  }

  private func persistLinkedFolderBookmarks() {
    let raw = Dictionary(
      uniqueKeysWithValues: linkedFolderBookmarksByTaskId.map { (String($0.key), $0.value) })
    UserDefaults.standard.set(raw, forKey: Self.linkedFolderBookmarksDefaultsKey)
  }

  private func bookmarkDataForLinkedTask(_ taskId: Int) -> Data? {
    guard
      let base64 = linkedFolderBookmarksByTaskId[taskId],
      let bookmark = Data(base64Encoded: base64)
    else { return nil }
    return bookmark
  }

  private func resolvedDestinationFolderURL(linkedFolderTaskId: Int?) throws -> URL {
    if let linkedFolderTaskId,
      let linkedURL = try resolvedLinkedFolderURL(forTaskId: linkedFolderTaskId)
    {
      return linkedURL
    }
    return try resolvedInboxURL()
  }

  private func resolvedInboxURL() throws -> URL {
    guard let bookmarkData = inboxBookmark else {
      throw ObsidianSyncError.inboxFolderNotConfigured
    }
    return try resolveSecurityScopedBookmark(bookmarkData) { refreshed in
      inboxBookmark = refreshed
      UserDefaults.standard.set(refreshed, forKey: Self.bookmarkDefaultsKey)
    }
  }

  private func resolvedLinkedFolderURL(forTaskId taskId: Int) throws -> URL? {
    guard let bookmarkData = bookmarkDataForLinkedTask(taskId) else { return nil }
    return try resolveSecurityScopedBookmark(bookmarkData) { refreshed in
      linkedFolderBookmarksByTaskId[taskId] = refreshed.base64EncodedString()
      persistLinkedFolderBookmarks()
    }
  }

  /// Resolves a security-scoped bookmark, refreshing it via `onStale` if the OS reports it stale.
  private func resolveSecurityScopedBookmark(
    _ bookmarkData: Data,
    onStale: (Data) -> Void
  ) throws -> URL {
    var isStale = false
    let resolvedURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    if isStale {
      let refreshed = try resolvedURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      onStale(refreshed)
    }
    return resolvedURL
  }

  private func writeTaskMarkdown(task: CheckvistTask, listId: String, inboxURL: URL, syncDate: Date)
    throws -> URL
  {
    let markdownURL = try noteFileURL(
      task: task,
      destinationFolderURL: inboxURL,
      createDirectoryIfNeeded: true
    )
    let localCreationDate = try? fileCreationDate(at: markdownURL)
    let latestRemoteUpdate = latestRemoteUpdateDate(for: task)

    if let localCreationDate, let latestRemoteUpdate, latestRemoteUpdate < localCreationDate {
      return markdownURL
    }

    let markdown = markdownDocument(for: task, listId: listId, syncDate: syncDate)
    try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    return markdownURL
  }

  /// Callers must already hold security-scoped access to `destinationFolderURL`
  /// (see `withSecurityScope`) — this both touches the filesystem when
  /// `createDirectoryIfNeeded` is set and returns a URL the caller will read or
  /// write immediately afterwards.
  private func noteFileURL(
    task: CheckvistTask,
    destinationFolderURL: URL,
    createDirectoryIfNeeded: Bool
  ) throws -> URL {
    if createDirectoryIfNeeded {
      try FileManager.default.createDirectory(
        at: destinationFolderURL,
        withIntermediateDirectories: true
      )
    }

    let safeName = sanitizeTaskFileName(task.content)
    return destinationFolderURL.appendingPathComponent("\(safeName).md")
  }

  private func openInObsidian(_ markdownURL: URL, mode: ObsidianOpenMode) {
    let obsidianURL = makeObsidianOpenURL(for: markdownURL, mode: mode)

    if mode == .newWindow,
      let obsidianURL,
      let obsidianAppURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: Self.obsidianBundleIdentifier)
    {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      NSWorkspace.shared.open(
        [obsidianURL],
        withApplicationAt: obsidianAppURL,
        configuration: configuration
      ) { _, _ in }
      return
    }

    if let obsidianURL, NSWorkspace.shared.open(obsidianURL) {
      return
    }

    if let obsidianAppURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: Self.obsidianBundleIdentifier)
    {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = mode == .standard
      NSWorkspace.shared.open(
        [markdownURL],
        withApplicationAt: obsidianAppURL,
        configuration: configuration
      ) { _, _ in }
      return
    }

    NSWorkspace.shared.open(markdownURL)
  }

  private func makeObsidianOpenURL(for markdownURL: URL, mode: ObsidianOpenMode) -> URL? {
    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    var queryItems = [URLQueryItem(name: "path", value: markdownURL.path)]
    if mode == .newWindow {
      queryItems.append(URLQueryItem(name: "paneType", value: "window"))
    }
    components.queryItems = queryItems
    return components.url
  }

  private func markdownDocument(for task: CheckvistTask, listId: String, syncDate: Date) -> String {
    let iso = ISO8601DateFormatter()
    var lines: [String] = []
    lines.append(task.content)
    if listId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("Task ID: \(task.id)")
    } else {
      lines.append("Checkvist Link: \(CheckvistEndpoints.taskPermalink(listId: listId, taskId: task.id))")
    }
    lines.append("")
    lines.append("Sync Date: \(iso.string(from: syncDate))")
    lines.append("")
    lines.append("Notes")

    let noteContents = (task.notes ?? [])
      .map(\.content)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    if noteContents.isEmpty {
      lines.append("_No notes_")
    } else {
      for noteContent in noteContents {
        lines.append(noteContent)
        lines.append("")
      }
      if lines.last?.isEmpty == true {
        lines.removeLast()
      }
    }

    return lines.joined(separator: "\n")
  }

  /// Longest note base name we will produce. HFS+/APFS cap a single path
  /// component at 255 *bytes*; leaving headroom for the ".md" suffix and the
  /// "-2"-style collision suffixes added by `uniqueFolderURL` keeps us clear of
  /// an opaque "file name too long" write failure on long task titles.
  private static let maximumFileNameByteCount = 200

  private func sanitizeTaskFileName(_ raw: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
    let cleanedScalars = raw.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) }
    let cleaned = String(cleanedScalars)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    guard !cleaned.isEmpty else { return "Task" }
    return Self.truncatedToByteCount(cleaned, limit: Self.maximumFileNameByteCount)
  }

  /// Trims to at most `limit` UTF-8 bytes without splitting a character.
  private static func truncatedToByteCount(_ value: String, limit: Int) -> String {
    guard value.utf8.count > limit else { return value }
    var truncated = ""
    var byteCount = 0
    for character in value {
      let width = String(character).utf8.count
      if byteCount + width > limit { break }
      truncated.append(character)
      byteCount += width
    }
    let trimmed = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Task" : trimmed
  }

  private func uniqueFolderURL(in parentURL: URL, preferredName: String) throws -> URL {
    let fileManager = FileManager.default
    var candidateURL = parentURL.appendingPathComponent(preferredName, isDirectory: true)
    var suffix = 2

    while fileManager.fileExists(atPath: candidateURL.path) {
      candidateURL = parentURL.appendingPathComponent(
        "\(preferredName)-\(suffix)", isDirectory: true)
      suffix += 1
    }

    return candidateURL
  }

  private func latestRemoteUpdateDate(for task: CheckvistTask) -> Date? {
    var candidates: [Date] = []
    if let taskUpdatedDate = parseRemoteTimestamp(task.updatedAt) {
      candidates.append(taskUpdatedDate)
    }
    for note in task.notes ?? [] {
      if let noteUpdatedDate = parseRemoteTimestamp(note.updatedAt) {
        candidates.append(noteUpdatedDate)
      }
    }
    return candidates.max()
  }

  private func parseRemoteTimestamp(_ raw: String?) -> Date? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    for parser in Self.remoteTimestampParsers {
      if let parsed = parser.date(from: raw) {
        return parsed
      }
    }
    return Self.remoteDateFormatter.date(from: raw)
  }

  private func fileCreationDate(at url: URL) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let date = attributes[.creationDate] as? Date {
      return date
    }
    if let date = attributes[.modificationDate] as? Date {
      return date
    }
    throw ObsidianSyncError.fileDateUnavailable
  }

  private static func pathFromBookmarkData(_ bookmarkData: Data?) -> String? {
    guard let bookmarkData else { return nil }

    var isStale = false
    guard
      let resolvedURL = try? URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else { return nil }

    return resolvedURL.path
  }
}

enum ObsidianSyncError: LocalizedError {
  case inboxFolderNotConfigured
  case fileDateUnavailable

  var errorDescription: String? {
    switch self {
    case .inboxFolderNotConfigured:
      return "Choose an Obsidian Inbox folder in Settings first."
    case .fileDateUnavailable:
      return "Unable to determine the local file date."
    }
  }
}
