import AppKit
import Foundation
import OSLog
import TaktCore

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
  private let store: DayLogHistory
  private let dailiesStore: DailyDefinitionsStore

  // The whole log is held in memory, in the Rust core, behind `store`. A
  // year of heavy use is a few thousand events, and every projection needs
  // the full history anyway (a reopen can cancel a completion from any
  // earlier day), so paging would buy nothing but a re-read on each popover
  // open. Holding it in the core is what keeps each projection one call
  // across the boundary rather than the whole history every time.

  /// The set of dailies, held in memory and written through on every edit. Tiny
  /// by nature — a list you tick off every morning does not grow unbounded.
  private var cachedDailies: DailyCollection

  private var folderBookmark: Data?

  /// Fired after an *external* change to either file has been reloaded, so the
  /// UI can re-read its projections. Set by `DailyLogManager`.
  var onExternalChange: (() -> Void)?

  /// Fired when something that should have reached disk did not: a log append
  /// that failed, a dailies edit that could not be saved, or a `dailies.json`
  /// that exists but will not decode. The in-memory state stays usable in each
  /// case, so these are not fatal — but they are the user's history and their
  /// configuration silently not being kept, which they need to hear about
  /// rather than discover at the next launch. Set by `DailyLogManager`.
  var onPersistenceError: ((Error) -> Void)? {
    didSet {
      // A dailies file that was already broken at launch is reported as soon
      // as there is someone to tell.
      if onPersistenceError != nil, reportedDailiesLoadFailure == nil {
        loadDailiesReportingFailure()
      }
    }
  }

  private var directoryWatcher: DispatchSourceFileSystemObject?
  private var logFileWatcher: DispatchSourceFileSystemObject?
  private let storeDirectory: URL

  /// The last dailies-file failure reported, so a file that stays broken is
  /// announced once rather than on every write event the watcher delivers.
  private var reportedDailiesLoadFailure: String?

  init(defaults: UserDefaults = .standard, storeDirectoryURL: URL? = nil) {
    self.defaults = defaults
    let directoryURL = storeDirectoryURL ?? Self.defaultStoreDirectoryURL()
    self.storeDirectory = directoryURL
    self.store = DayLogHistory(directoryURL: directoryURL)
    self.dailiesStore = DailyDefinitionsStore(directoryURL: directoryURL)
    self.cachedDailies = DailyCollection()
    self.folderBookmark = defaults.data(forKey: Self.bookmarkDefaultsKey)
    loadDailiesReportingFailure()
    startWatchingStoreDirectory()
    startWatchingLogFile()
  }

  deinit {
    directoryWatcher?.cancel()
    logFileWatcher?.cancel()
  }

  /// Reads `dailies.json` strictly, keeping the cache as it was if the file is
  /// present but broken. Reading it as empty — which `load()` does — would be
  /// wrong here on both counts: the UI would show no dailies, and the next
  /// edit would start from nothing. `DailyDefinitionsStore.mutate` refuses to
  /// save over such a file, so the cache being stale is the lesser harm.
  private func loadDailiesReportingFailure() {
    do {
      cachedDailies = try dailiesStore.loadStrict()
      reportedDailiesLoadFailure = nil
    } catch {
      let description = error.localizedDescription
      logger.error("Dailies file unreadable: \(description, privacy: .public)")
      // Only counted as reported once somebody heard it: the first load runs
      // in `init`, before `DailyLogManager` has set the callback, and marking
      // it reported then would swallow a file that was broken at launch.
      if reportedDailiesLoadFailure != description, let onPersistenceError {
        reportedDailiesLoadFailure = description
        onPersistenceError(error)
      }
    }
  }

  /// Watches the store *directory*, for `dailies.json` and for the log file
  /// appearing, disappearing or being replaced.
  ///
  /// `dailies.json` is saved atomically — written to a temporary and renamed
  /// over the target — so a watch on that file would follow the old,
  /// now-unlinked inode and go silent after the first external save. The
  /// directory's inode is stable and sees the rename.
  ///
  /// What the directory *cannot* see is an in-place append to `daylog.jsonl`:
  /// a write to an existing file changes that file's vnode, not the
  /// directory's, so an MCP `daily_tick` left the popover stale until relaunch.
  /// That is what `startWatchingLogFile` is for; this watcher's job for the
  /// log is only to notice when the file it watches has been swapped out so it
  /// can re-open it.
  private func startWatchingStoreDirectory() {
    try? FileManager.default.createDirectory(
      at: storeDirectory, withIntermediateDirectories: true)

    guard
      let source = Self.makeWatcher(
        path: storeDirectory.path,
        eventMask: [.write, .rename, .delete],
        onEvent: { [weak self] _ in
          guard let self else { return }
          self.reloadFromDisk()
          // The log file may have just been created, or replaced, by another
          // process; make sure the file watcher is on the current inode.
          if self.logFileWatcher == nil {
            self.startWatchingLogFile()
          }
        }
      )
    else {
      logger.error("Could not watch the daily-log directory; external edits need a relaunch.")
      return
    }
    directoryWatcher = source
  }

  /// Watches the log file's own descriptor, which is what sees an append.
  ///
  /// The file is append-only and never rewritten, so its inode is stable in
  /// normal use and this watch lives as long as the process does. If it is
  /// deleted or renamed out from under us — a user clearing their history, say
  /// — the watch is dropped and the directory watcher re-opens it once a new
  /// file appears. Nothing to do when the file does not exist yet: that also
  /// falls to the directory watcher.
  private func startWatchingLogFile() {
    logFileWatcher?.cancel()
    logFileWatcher = nil
    guard FileManager.default.fileExists(atPath: store.fileURL.path) else { return }

    guard
      let source = Self.makeWatcher(
        path: store.fileURL.path,
        eventMask: [.write, .extend, .rename, .delete],
        onEvent: { [weak self] events in
          guard let self else { return }
          if !events.isDisjoint(with: [.rename, .delete]) {
            self.logFileWatcher?.cancel()
            self.logFileWatcher = nil
          }
          self.reloadFromDisk()
          if self.logFileWatcher == nil {
            self.startWatchingLogFile()
          }
        }
      )
    else {
      logger.error("Could not watch the daily-log file; external ticks need a relaunch.")
      return
    }
    logFileWatcher = source
  }

  /// Opens `path` for events only and returns a resumed source, or nil if it
  /// could not be opened. The cancel handler captures the descriptor *by
  /// value*: capturing `self` weakly — as this used to — meant that once the
  /// service was deallocated the handler found no `self` and returned without
  /// closing anything, leaking the descriptor for the life of the process.
  private static func makeWatcher(
    path: String,
    eventMask: DispatchSource.FileSystemEvent,
    onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void
  ) -> DispatchSourceFileSystemObject? {
    let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: eventMask,
      queue: .main
    )
    source.setEventHandler { [weak source] in
      onEvent(source?.data ?? [])
    }
    source.setCancelHandler {
      close(descriptor)
    }
    source.resume()
    return source
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
  /// The stat check in front is what keeps that cheap. The watchers fire on
  /// *every* write — including this process's own, so every recorded event
  /// triggers one — and the day log is append-only, so decoding it and
  /// comparing the whole array meant the cost of each write grew with the
  /// length of the user's history. Two `stat` calls settle it instead, and the
  /// deep comparison below still has the final say on whether to notify.
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

    let logChanged = store.reload()
    let previousDailies = cachedDailies
    loadDailiesReportingFailure()
    guard logChanged || cachedDailies != previousDailies else { return }
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
    SecurityScopedFolderBookmark.path(from: folderBookmark) ?? ""
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

    let bookmark = try SecurityScopedFolderBookmark.make(for: selectedURL)
    folderBookmark = bookmark
    defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
    return selectedURL.path
  }

  func clearDailiesFolder() {
    folderBookmark = nil
    defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
  }

  // MARK: - Recording

  func record(_ event: DayLogEvent) {
    do {
      // Held even when the append fails.
      try store.record(event)
    } catch {
      // The in-memory copy still has it, so the current session stays correct;
      // only durability is lost. Failing the user's completion because a log
      // line didn't land would be a far worse trade — but they do need to know
      // the line is not on disk.
      logger.error("Daily log append failed: \(error.localizedDescription, privacy: .public)")
      onPersistenceError?(error)
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
      guard !plannedTaskIds.isEmpty, recordedPlanIsEmpty(on: now) else { return }
    }
    record(.planSnapshot(taskIds: plannedTaskIds, at: now))
    defaults.set(key, forKey: Self.lastSnapshotDayKeyDefaultsKey)
  }

  /// Whether the day's latest snapshot, the one the summary reads, planned
  /// nothing (or there is none).
  private func recordedPlanIsEmpty(on now: Date) -> Bool {
    summary(on: now).plannedTaskIds.isEmpty
  }

  // MARK: - Dailies

  var dailies: [Daily] { cachedDailies.active }

  func dailies(dueOn date: Date) -> [Daily] {
    cachedDailies.due(on: boundary.logicalDay(for: date), calendar: boundary.calendar)
  }

  func completedDailyIds(on date: Date) -> Set<String> {
    store.completedDailyIds(boundary: boundary, on: date)
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
      // Same trade as `record`, and the same obligation to say so: an edit
      // that looks saved and isn't — most likely because the file on disk is
      // one the store refused to overwrite — would otherwise be discovered at
      // the next launch, when it is gone.
      transform(&cachedDailies)
      logger.error("Dailies save failed: \(error.localizedDescription, privacy: .public)")
      onPersistenceError?(error)
    }
  }

  // MARK: - Projections

  func summary(on date: Date) -> DayLogAggregator.DaySummary {
    store.summary(boundary: boundary, on: date)
  }

  func dailyBuckets(endingOn now: Date, days: Int) -> [DayLogAggregator.Bucket] {
    store.dailyBuckets(boundary: boundary, endingOn: now, days: days)
  }

  func weeklyBuckets(endingOn now: Date, weeks: Int) -> [DayLogAggregator.Bucket] {
    store.weeklyBuckets(boundary: boundary, endingOn: now, weeks: weeks)
  }

  var recordedDayCount: Int {
    store.recordedDayCount(boundary: boundary)
  }

  var firstRecordedDay: Date? {
    store.firstRecordedDay(boundary: boundary)
  }

  func priorCompletionStreak(now: Date) -> Int {
    store.priorCompletionStreak(boundary: boundary, now: now)
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

    return try SecurityScopedFolderBookmark.withAccess(folderURL) {
      let noteURL = folderURL.appendingPathComponent(relativePath)

      // Existence and readability are two different questions, and conflating
      // them — `try? String(contentsOf:)` then "nil means create" — meant a
      // note that *exists* but could not be read just then (an iCloud dataless
      // file still downloading, a permissions hiccup) was replaced with a
      // stub when "create missing notes" was on. Only a genuine absence may
      // create; any other read failure is the caller's to see.
      guard FileManager.default.fileExists(atPath: noteURL.path) else {
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

      let existing = try String(contentsOf: noteURL, encoding: .utf8)
      let merged = DailyNoteMarkdown.merged(section: section, into: existing)
      guard merged != existing else { return noteURL }
      try merged.write(to: noteURL, atomically: true, encoding: .utf8)
      return noteURL
    }
  }

  /// How far back a catch-up write will reach. A machine that has been off
  /// for longer than this gets its last month mirrored, not its whole absence
  /// — the notes for older days are very likely to have been written by hand
  /// by then, and a month of stubs landing at once is not a welcome surprise.
  private static let maximumCatchUpDays = 30

  /// Mirrors every logical day that has closed since the last write.
  ///
  /// Only closed days are written: mirroring a day still in progress would keep
  /// rewriting the block all afternoon, and the note is meant to be a record of
  /// what a day *was*, not a live dashboard. That is what the Daily view is for.
  ///
  /// *Every* closed day, not just yesterday: this used to write `previousDay`
  /// alone and then stamp it, so a laptop closed on Friday and opened on Monday
  /// mirrored Sunday and silently skipped Friday and Saturday for good. The
  /// walk now runs from the day after the stamp up to yesterday, oldest first,
  /// and stops at the first failure so the stamp never jumps past a day that
  /// has not landed.
  func writeClosedDayNotesIfNeeded(now: Date, titlesByTaskId: [Int: String]) {
    guard writesNotesAutomatically, !dailiesFolderPath.isEmpty else { return }

    let todayKey = boundary.dayKey(for: now)
    let previousDay = boundary.day(offsetBy: -1, from: now)
    let previousKey = boundary.dayKey(for: previousDay)
    let lastWrittenKey = defaults.string(forKey: Self.lastWrittenNoteDayKeyDefaultsKey)

    guard lastWrittenKey != previousKey, previousKey != todayKey else { return }

    // With no stamp at all this is a first run, and there is no "since" to
    // catch up from: yesterday is the only day owed. Day keys are
    // `yyyy-MM-dd`, so plain string order is date order.
    let pendingDays: [Date]
    if let lastWrittenKey {
      pendingDays = boundary.days(endingOn: previousDay, count: Self.maximumCatchUpDays)
        .filter { boundary.dayKey(for: $0) > lastWrittenKey }
    } else {
      pendingDays = [previousDay]
    }

    for day in pendingDays {
      let key = boundary.dayKey(for: day)

      // Nothing happened, nothing to say — don't stamp an empty block into a
      // note. The day still counts as handled.
      let summary = summary(on: day)
      guard
        summary.completedCount > 0 || summary.plannedCount > 0 || summary.focusSeconds > 0
          || !dailies(dueOn: day).isEmpty
      else {
        defaults.set(key, forKey: Self.lastWrittenNoteDayKeyDefaultsKey)
        continue
      }

      do {
        try writeDailyNote(for: day, titlesByTaskId: titlesByTaskId)
        defaults.set(key, forKey: Self.lastWrittenNoteDayKeyDefaultsKey)
      } catch {
        // Left unstamped on purpose so the next launch retries — a missing
        // note today (say, because the vault is on an unmounted drive)
        // shouldn't cost that day's entry permanently. Later days wait too,
        // or the stamp would move past this one.
        logger.error(
          "Daily note write for \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        return
      }
    }
  }

  // MARK: - Folder bookmark

  /// The bookmark machinery itself — resolving, refreshing when stale, holding
  /// access around reads and writes — is `SecurityScopedFolderBookmark`,
  /// shared with `ObsidianSyncService`.
  private func resolvedFolderURL() throws -> URL {
    guard let folderBookmark else { throw DailyLogError.folderNotConfigured }
    return try SecurityScopedFolderBookmark.resolve(folderBookmark) { [weak self] refreshed in
      guard let self else { return }
      self.folderBookmark = refreshed
      self.defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
    }
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
