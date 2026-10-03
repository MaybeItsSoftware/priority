import AppKit
import Foundation
import OSLog
import PriorityCore

/// Owns the daily log: the append-only event file, the dailies-folder bookmark,
/// and the managed-section write into an Obsidian daily note.
///
/// The split of responsibility is deliberate and load-bearing:
/// **Checkvist owns current state, this log owns history, Obsidian owns the
/// archive.** Nothing here ever writes back to Checkvist, and nothing here ever
/// reads a daily note for task state, so there is no sync and no conflict —
/// only a one-way append. That is what makes it safe to run unattended.
///
/// Not `@MainActor`-isolated as a whole, matching `ObsidianSyncService`: the
/// plugin that owns it is main-actor, but a main-actor initialiser can't be
/// used as a default argument (those evaluate at the call site, which is
/// nonisolated). Only the method that drives `NSOpenPanel` needs the actor.
final class DailyLogService {
  private static let bookmarkDefaultsKey = "dailyLogFolderBookmark"
  private static let rolloverHourDefaultsKey = "dailyLogRolloverHour"
  private static let fileNameFormatDefaultsKey = "dailyLogNoteFileNameFormat"
  private static let folderFormatDefaultsKey = "dailyLogNoteFolderFormat"
  private static let createsMissingNotesDefaultsKey = "dailyLogCreatesMissingNotes"
  private static let writesAutomaticallyDefaultsKey = "dailyLogWritesNotesAutomatically"
  private static let lastSnapshotDayKeyDefaultsKey = "dailyLogLastSnapshotDayKey"
  private static let lastWrittenNoteDayKeyDefaultsKey = "dailyLogLastWrittenNoteDayKey"

  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "dailylog")
  private let defaults: UserDefaults
  private let store: DayLogFileStore
  private let dailiesStore: DailyDefinitionsStore

  /// The whole log, held in memory. A year of heavy use is a few thousand
  /// events, and every projection needs the full history anyway (a reopen can
  /// cancel a completion from any earlier day), so paging would buy nothing but
  /// a re-read on each popover open.
  private var cachedEvents: [DayLogEvent]

  /// The set of dailies, held in memory and written through on every edit. Tiny
  /// by nature — a list you tick off every morning does not grow unbounded.
  private var cachedDailies: DailyCollection

  private var folderBookmark: Data?

  /// Fired after an *external* change to either file has been reloaded, so the
  /// UI can re-read its projections. Set by `DailyLogManager`.
  var onExternalChange: (() -> Void)?

  private var directoryWatcher: DispatchSourceFileSystemObject?
  private var watchedDirectoryDescriptor: CInt = -1
  private let storeDirectory: URL

  init(defaults: UserDefaults = .standard, storeDirectoryURL: URL? = nil) {
    self.defaults = defaults
    let directoryURL = storeDirectoryURL ?? Self.defaultStoreDirectoryURL()
    self.storeDirectory = directoryURL
    self.store = DayLogFileStore(directoryURL: directoryURL)
    self.dailiesStore = DailyDefinitionsStore(directoryURL: directoryURL)
    self.cachedEvents = store.loadAll()
    self.cachedDailies = dailiesStore.load()
    self.folderBookmark = defaults.data(forKey: Self.bookmarkDefaultsKey)
    startWatchingStoreDirectory()
  }

  deinit {
    directoryWatcher?.cancel()
  }

  /// Watches the store *directory* rather than the two files.
  ///
  /// `dailies.json` is saved atomically — written to a temporary and renamed
  /// over the target — so a watch on the file follows the old, now-unlinked
  /// inode and goes silent after the first external save. The directory's inode
  /// is stable and sees the rename, so one watcher covers both files and
  /// survives any number of saves.
  ///
  /// Without this, an MCP-side edit would sit on disk unseen until the next
  /// launch, and the app's own next edit would be computed from a stale cache.
  private func startWatchingStoreDirectory() {
    try? FileManager.default.createDirectory(
      at: storeDirectory, withIntermediateDirectories: true)

    let descriptor = open(storeDirectory.path, O_EVTONLY)
    guard descriptor >= 0 else {
      logger.error("Could not watch the daily-log directory; external edits need a relaunch.")
      return
    }
    watchedDirectoryDescriptor = descriptor

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      self?.reloadFromDisk()
    }
    source.setCancelHandler { [weak self] in
      guard let self, self.watchedDirectoryDescriptor >= 0 else { return }
      close(self.watchedDirectoryDescriptor)
      self.watchedDirectoryDescriptor = -1
    }
    source.resume()
    directoryWatcher = source
  }

  /// Size and modification date of a watched file, as a change detector.
  private struct FileStamp: Equatable {
    let size: Int
    let modified: Date

    init?(_ url: URL) {
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
        let size = values.fileSize,
        let modified = values.contentModificationDate
      else { return nil }
      self.size = size
      self.modified = modified
    }
  }

  private var lastLogStamp: FileStamp?
  private var lastDailiesStamp: FileStamp?

  /// Re-reads both files and notifies, but only when something actually
  /// changed: the watcher also fires for this process's own writes, and
  /// bumping the UI revision on every self-inflicted save would redraw the
  /// popover on each keystroke of a rename.
  ///
  /// The stat check in front is what keeps that cheap. The watcher fires on
  /// *every* write to the directory — including this process's own, so every
  /// recorded event triggers one — and the day log is append-only, so decoding
  /// it and comparing the whole array meant the cost of each write grew with
  /// the length of the user's history. Two `stat` calls settle it instead, and
  /// the deep comparison below still has the final say on whether to notify.
  private func reloadFromDisk() {
    let logStamp = FileStamp(store.fileURL)
    let dailiesStamp = FileStamp(dailiesStore.fileURL)
    if logStamp == lastLogStamp, dailiesStamp == lastDailiesStamp,
      lastLogStamp != nil || lastDailiesStamp != nil
    {
      return
    }
    lastLogStamp = logStamp
    lastDailiesStamp = dailiesStamp

    let events = store.loadAll()
    let dailies = dailiesStore.load()
    guard events != cachedEvents || dailies != cachedDailies else { return }
    cachedEvents = events
    cachedDailies = dailies
    onExternalChange?()
  }

  /// `~/Library/Application Support/Takt/`, alongside the user plugins
  /// folder. Inside the app's own container it needs no security scope.
  ///
  /// Not private because `MCPServer` reads the same two files to answer
  /// `daily_log_fetch` / `dailies_list`. It runs as the same bundle in a
  /// separate process, so resolving the path twice would be two chances to
  /// disagree about where the history lives.
  static func defaultStoreDirectoryURL() -> URL {
    AppIdentity.applicationSupportDirectory()
  }

  // MARK: - Configuration

  var rolloverHour: Int {
    get {
      guard defaults.object(forKey: Self.rolloverHourDefaultsKey) != nil else {
        return DayBoundary.defaultRolloverHour
      }
      return min(23, max(0, defaults.integer(forKey: Self.rolloverHourDefaultsKey)))
    }
    set { defaults.set(min(23, max(0, newValue)), forKey: Self.rolloverHourDefaultsKey) }
  }

  var boundary: DayBoundary {
    DayBoundary(rolloverHour: rolloverHour)
  }

  var noteFormat: DailyNoteFormat {
    get {
      DailyNoteFormat(
        fileNameFormat: defaults.string(forKey: Self.fileNameFormatDefaultsKey)
          ?? DailyNoteFormat.default.fileNameFormat,
        folderFormat: defaults.string(forKey: Self.folderFormatDefaultsKey)
          ?? DailyNoteFormat.default.folderFormat
      )
    }
    set {
      defaults.set(newValue.fileNameFormat, forKey: Self.fileNameFormatDefaultsKey)
      defaults.set(newValue.folderFormat, forKey: Self.folderFormatDefaultsKey)
    }
  }

  /// Defaults to off. A vault that builds its dailies from a Templater template
  /// would get a bare stub instead if we created the file first, so the safe
  /// default is to write only into notes that already exist.
  var createsMissingNotes: Bool {
    get { defaults.bool(forKey: Self.createsMissingNotesDefaultsKey) }
    set { defaults.set(newValue, forKey: Self.createsMissingNotesDefaultsKey) }
  }

  var writesNotesAutomatically: Bool {
    get {
      guard defaults.object(forKey: Self.writesAutomaticallyDefaultsKey) != nil else { return true }
      return defaults.bool(forKey: Self.writesAutomaticallyDefaultsKey)
    }
    set { defaults.set(newValue, forKey: Self.writesAutomaticallyDefaultsKey) }
  }

  // MARK: - Folder

  var dailiesFolderPath: String {
    Self.pathFromBookmarkData(folderBookmark) ?? ""
  }

  @MainActor
  func chooseDailiesFolder() throws -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Dailies"
    panel.message = "Select the folder holding your Obsidian daily notes."

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }

    let bookmark = try selectedURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    folderBookmark = bookmark
    defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
    return selectedURL.path
  }

  func clearDailiesFolder() {
    folderBookmark = nil
    defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
  }

  // MARK: - Recording

  var events: [DayLogEvent] { cachedEvents }

  func record(_ event: DayLogEvent) {
    cachedEvents.append(event)
    do {
      try store.append(event)
    } catch {
      // The in-memory copy still has it, so the current session stays correct;
      // only durability is lost. Failing the user's completion because a log
      // line didn't land would be a far worse trade.
      logger.error("Daily log append failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Records the day's plan the first time it is called on a given logical day.
  ///
  /// This is what makes "planned vs done" work without the user planning
  /// anything: the plan is simply whatever was due or starting when the day
  /// began, captured once so that later edits can't rewrite this morning's
  /// intent.
  func snapshotPlanIfNeeded(plannedTaskIds: [Int], now: Date) {
    let key = boundary.dayKey(for: now)
    if defaults.string(forKey: Self.lastSnapshotDayKeyDefaultsKey) == key {
      // Already snapshotted today — unless what landed was empty and we now
      // have a real plan. That happens when the list hadn't loaded yet at the
      // time of the first call, and an empty plan is worth nothing, so there is
      // no intent to preserve by keeping it. `DayLogAggregator.summary` reads
      // the last snapshot of the day, so the upgrade simply wins.
      guard !plannedTaskIds.isEmpty, recordedPlanIsEmpty(forDayKey: key) else { return }
    }
    record(.planSnapshot(taskIds: plannedTaskIds, at: now))
    defaults.set(key, forKey: Self.lastSnapshotDayKeyDefaultsKey)
  }

  private func recordedPlanIsEmpty(forDayKey key: String) -> Bool {
    let latest = cachedEvents.last {
      $0.kind == .planSnapshot && boundary.dayKey(for: $0.at) == key
    }
    return latest?.plannedTaskIds?.isEmpty ?? true
  }

  // MARK: - Dailies

  var dailies: [Daily] { cachedDailies.active }

  func dailies(dueOn date: Date) -> [Daily] {
    cachedDailies.due(on: boundary.logicalDay(for: date), calendar: boundary.calendar)
  }

  func completedDailyIds(on date: Date) -> Set<String> {
    DayLogAggregator.completedDailyIds(events: cachedEvents, boundary: boundary, on: date)
  }

  @discardableResult
  func addDaily(title: String, schedule: Daily.Schedule) -> Daily? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var daily = Daily(title: trimmed)
    daily.setSchedule(schedule)
    mutateDailies { $0.add(daily) }
    // Re-read rather than returning the local copy: `add` assigns the sort
    // index against whatever was on disk, so the stored value is the truthful
    // one.
    return cachedDailies.daily(withId: daily.id)
  }

  func updateDaily(id: String, title: String?, schedule: Daily.Schedule?) {
    mutateDailies { collection in
      collection.update(id: id) { daily in
        if let title {
          let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
          // An empty rename is a slip, not an instruction to blank the row.
          if !trimmed.isEmpty { daily.title = trimmed }
        }
        if let schedule { daily.setSchedule(schedule) }
      }
    }
  }

  func archiveDaily(id: String) {
    mutateDailies { $0.archive(id: id) }
  }

  func restoreDaily(id: String) {
    mutateDailies { $0.restore(id: id) }
  }

  /// Archived ones included — only the settings pane's restore list wants
  /// these. Everything else reads `dailies`, which is active-only.
  var allDailiesIncludingArchived: [Daily] { cachedDailies.dailies }

  func moveDaily(id: String, by offset: Int) {
    mutateDailies { $0.move(id: id, by: offset) }
  }

  @discardableResult
  func setDaily(id: String, completed: Bool, now: Date) -> Bool {
    let alreadyCompleted = completedDailyIds(on: now).contains(id)
    guard alreadyCompleted != completed else { return alreadyCompleted }

    let title = cachedDailies.daily(withId: id)?.title ?? ""
    record(
      completed
        ? .dailyCompleted(dailyId: id, title: title, at: now)
        : .dailyUncompleted(dailyId: id, title: title, at: now)
    )
    return completed
  }

  /// Applies an edit to the dailies on disk and refreshes the cache from the
  /// saved result.
  ///
  /// Goes through `DailyDefinitionsStore.mutate`, which re-reads inside a file
  /// lock, so an edit made here composes with one made by the `--mcp-server`
  /// process instead of overwriting it. Writing `cachedDailies` back wholesale
  /// — which this used to do — silently destroyed anything the other process
  /// had added since launch.
  private func mutateDailies(_ transform: (inout DailyCollection) -> Void) {
    do {
      cachedDailies = try dailiesStore.mutate(transform)
    } catch {
      // Apply locally so the session stays usable; only durability is lost.
      // Same trade as `record`.
      transform(&cachedDailies)
      logger.error("Dailies save failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Projections

  func summary(on date: Date) -> DayLogAggregator.DaySummary {
    DayLogAggregator.summary(events: cachedEvents, boundary: boundary, on: date)
  }

  func dailyBuckets(endingOn now: Date, days: Int) -> [DayLogAggregator.Bucket] {
    DayLogAggregator.dailyBuckets(
      events: cachedEvents, boundary: boundary, endingOn: now, days: days)
  }

  func weeklyBuckets(endingOn now: Date, weeks: Int) -> [DayLogAggregator.Bucket] {
    DayLogAggregator.weeklyBuckets(
      events: cachedEvents, boundary: boundary, endingOn: now, weeks: weeks)
  }

  var recordedDayCount: Int {
    DayLogAggregator.recordedDayCount(events: cachedEvents, boundary: boundary)
  }

  var firstRecordedDay: Date? {
    DayLogAggregator.firstRecordedDay(events: cachedEvents, boundary: boundary)
  }

  // MARK: - Notes

  @discardableResult
  func writeDailyNote(for day: Date, titlesByTaskId: [Int: String]) throws -> URL {
    let folderURL = try resolvedFolderURL()
    let relativePath = DailyNotePath.relativePath(for: day, format: noteFormat)
    let summary = summary(on: day)
    let section = DailyNoteMarkdown.section(
      summary: summary,
      titlesByTaskId: titlesByTaskId,
      dailies: dailies(dueOn: day)
    )

    return try withSecurityScope(folderURL) {
      let noteURL = folderURL.appendingPathComponent(relativePath)
      let existing = try? String(contentsOf: noteURL, encoding: .utf8)

      guard let existing else {
        guard createsMissingNotes else {
          throw DailyLogError.noteMissing(path: relativePath)
        }
        try FileManager.default.createDirectory(
          at: noteURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try (section + "\n").write(to: noteURL, atomically: true, encoding: .utf8)
        return noteURL
      }

      let merged = DailyNoteMarkdown.merged(section: section, into: existing)
      guard merged != existing else { return noteURL }
      try merged.write(to: noteURL, atomically: true, encoding: .utf8)
      return noteURL
    }
  }

  /// Mirrors any logical day that has closed since the last write.
  ///
  /// Only closed days are written: mirroring a day still in progress would keep
  /// rewriting the block all afternoon, and the note is meant to be a record of
  /// what a day *was*, not a live dashboard. That is what the Daily view is for.
  func writeClosedDayNotesIfNeeded(now: Date, titlesByTaskId: [Int: String]) {
    guard writesNotesAutomatically, !dailiesFolderPath.isEmpty else { return }

    let todayKey = boundary.dayKey(for: now)
    let previousDay = boundary.day(offsetBy: -1, from: now)
    let previousKey = boundary.dayKey(for: previousDay)

    guard defaults.string(forKey: Self.lastWrittenNoteDayKeyDefaultsKey) != previousKey,
      previousKey != todayKey
    else { return }

    // Nothing happened, nothing to say — don't stamp an empty block into a note.
    let summary = summary(on: previousDay)
    guard
      summary.completedCount > 0 || summary.plannedCount > 0 || summary.focusSeconds > 0
        || !dailies(dueOn: previousDay).isEmpty
    else {
      defaults.set(previousKey, forKey: Self.lastWrittenNoteDayKeyDefaultsKey)
      return
    }

    do {
      try writeDailyNote(for: previousDay, titlesByTaskId: titlesByTaskId)
      defaults.set(previousKey, forKey: Self.lastWrittenNoteDayKeyDefaultsKey)
    } catch {
      // Left unstamped on purpose so the next launch retries — a missing note
      // today (say, because the vault is on an unmounted drive) shouldn't cost
      // that day's entry permanently.
      logger.error(
        "Daily note write for \(previousKey, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - Security-scoped access

  /// Runs `body` while holding security-scoped access. Release builds are
  /// sandboxed, so every read and write under the bookmark-resolved folder has
  /// to happen inside one of these — see `ObsidianSyncService` for the same
  /// pattern and the same reason.
  private func withSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return try body()
  }

  private func resolvedFolderURL() throws -> URL {
    guard let folderBookmark else { throw DailyLogError.folderNotConfigured }

    var isStale = false
    let resolvedURL = try URL(
      resolvingBookmarkData: folderBookmark,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    if isStale,
      let refreshed = try? resolvedURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    {
      self.folderBookmark = refreshed
      defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
    }
    return resolvedURL
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

enum DailyLogError: LocalizedError {
  case folderNotConfigured
  case noteMissing(path: String)

  var errorDescription: String? {
    switch self {
    case .folderNotConfigured:
      return "Choose your Obsidian dailies folder in Settings first."
    case .noteMissing(let path):
      return
        "No daily note at \(path). Create it in Obsidian, or turn on \"Create missing notes\"."
    }
  }
}
