import AppKit
import Foundation
import TaktCore

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
    SecurityScopedFolderBookmark.path(from: inboxBookmark) ?? ""
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

    let bookmark = try SecurityScopedFolderBookmark.make(for: selectedURL)

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

    let bookmark = try SecurityScopedFolderBookmark.make(for: selectedURL)

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

    let bookmark = try SecurityScopedFolderBookmark.withAccess(parentURL) {
      let preferredName = sanitizeTaskFileName(taskContent)
      let createdFolderURL = try uniqueFolderURL(in: parentURL, preferredName: preferredName)
      try FileManager.default.createDirectory(
        at: createdFolderURL, withIntermediateDirectories: true)
      return (try SecurityScopedFolderBookmark.make(for: createdFolderURL), createdFolderURL)
    }
    let createdFolderURL = bookmark.1

    linkedFolderBookmarksByTaskId[taskId] = bookmark.0.base64EncodedString()
    persistLinkedFolderBookmarks()
    return createdFolderURL.path
  }

  func clearLinkedFolder(forTaskId taskId: Int) {
    linkedFolderBookmarksByTaskId.removeValue(forKey: taskId)
    persistLinkedFolderBookmarks()
  }

  func linkedFolderPath(forTaskId taskId: Int) -> String? {
    guard let bookmark = bookmarkDataForLinkedTask(taskId) else { return nil }
    return SecurityScopedFolderBookmark.path(from: bookmark)
  }

  func hasLinkedFolder(forTaskId taskId: Int) -> Bool {
    linkedFolderPath(forTaskId: taskId) != nil
  }

  func hasSyncedNote(task: CheckvistTask, linkedFolderTaskId: Int?) -> Bool {
    guard
      let destinationFolderURL = try? resolvedDestinationFolderURL(
        linkedFolderTaskId: linkedFolderTaskId)
    else { return false }
    return SecurityScopedFolderBookmark.withAccess(destinationFolderURL) {
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
    // The access window spans the directory creation, the creation-date probe
    // *and* the write — not just the step that assembles the destination URL.
    // The app is not sandboxed today (see `SecurityScopedFolderBookmark`), so
    // this is discipline rather than necessity; it is what lets the
    // entitlement be added later without revisiting every write.
    let markdownURL = try SecurityScopedFolderBookmark.withAccess(inboxURL) {
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
    return try SecurityScopedFolderBookmark.resolve(bookmarkData) { [weak self] refreshed in
      self?.inboxBookmark = refreshed
      UserDefaults.standard.set(refreshed, forKey: Self.bookmarkDefaultsKey)
    }
  }

  private func resolvedLinkedFolderURL(forTaskId taskId: Int) throws -> URL? {
    guard let bookmarkData = bookmarkDataForLinkedTask(taskId) else { return nil }
    return try SecurityScopedFolderBookmark.resolve(bookmarkData) { [weak self] refreshed in
      guard let self else { return }
      self.linkedFolderBookmarksByTaskId[taskId] = refreshed.base64EncodedString()
      self.persistLinkedFolderBookmarks()
    }
  }

  private func writeTaskMarkdown(task: CheckvistTask, listId: String, inboxURL: URL, syncDate: Date)
    throws -> URL
  {
    let markdownURL = try noteFileURL(
      task: task,
      destinationFolderURL: inboxURL,
      createDirectoryIfNeeded: true
    )
    let block = ManagedMarkdownBlock.takt
    let body = markdownDocument(for: task, listId: listId, syncDate: syncDate)

    guard FileManager.default.fileExists(atPath: markdownURL.path) else {
      try (block.wrap(body) + "\n").write(to: markdownURL, atomically: true, encoding: .utf8)
      return markdownURL
    }

    let localCreationDate = try? fileCreationDate(at: markdownURL)
    let latestRemoteUpdate = latestRemoteUpdateDate(for: task)
    if let localCreationDate, let latestRemoteUpdate, latestRemoteUpdate < localCreationDate {
      return markdownURL
    }

    // The file is keyed only on the task's title, so what is at that path may
    // be the user's own note that happens to share it, or a note we wrote that
    // they have since added to. Either way only the managed block is ours to
    // rewrite: everything outside the markers comes back untouched, and a file
    // with no markers that we did not write is refused rather than replaced.
    let existing = try String(contentsOf: markdownURL, encoding: .utf8)
    let merged: String
    if block.contains(existing) {
      merged = block.merging(body: body, into: existing)
    } else if Self.isLegacySyncedNote(existing, taskId: task.id) {
      // Written whole-file by an earlier Takt, before the markers. Nothing in
      // it is the user's, so adopting it into a block loses nothing.
      merged = block.wrap(body) + "\n"
    } else {
      throw ObsidianSyncError.noteNotManaged(path: markdownURL.lastPathComponent)
    }

    guard merged != existing else { return markdownURL }
    try merged.write(to: markdownURL, atomically: true, encoding: .utf8)
    return markdownURL
  }

  /// Whether `contents` is a note this service wrote before it used markers:
  /// the whole-file shape was the title, then a `Task ID:` or `Checkvist Link:`
  /// line naming this task, then `Sync Date:`. Both lines are required, so a
  /// user's note that happens to mention the task's permalink is not mistaken
  /// for ours.
  static func isLegacySyncedNote(_ contents: String, taskId: Int) -> Bool {
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(4)
    let namesTask = lines.contains {
      $0 == "Task ID: \(taskId)" || ($0.hasPrefix("Checkvist Link: ") && $0.hasSuffix("#t\(taskId)"))
    }
    let hasSyncDate = lines.contains { $0.hasPrefix("Sync Date: ") }
    return namesTask && hasSyncDate
  }

  /// Callers must already hold security-scoped access to `destinationFolderURL`
  /// (see `SecurityScopedFolderBookmark.withAccess`) — this both touches the filesystem when
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

}

enum ObsidianSyncError: LocalizedError {
  case inboxFolderNotConfigured
  case fileDateUnavailable
  /// A file already sits where the task's note would go, and it is not one
  /// Takt wrote: no managed-block markers, not the pre-marker shape either.
  case noteNotManaged(path: String)

  var errorDescription: String? {
    switch self {
    case .inboxFolderNotConfigured:
      return "Choose an Obsidian Inbox folder in Settings first."
    case .fileDateUnavailable:
      return "Unable to determine the local file date."
    case .noteNotManaged(let path):
      return
        "\(path) already exists and wasn't written by Takt, so it was left alone. "
        + "Rename it, or add <!-- priority:begin --> and <!-- priority:end --> where the task should go."
    }
  }
}
