import Foundation
import OSLog
import Observation
import PriorityCore

/// Read-only access to the task data the daily log needs.
///
/// Kept behind a protocol for the same reason `IntegrationDataSource` is: the
/// manager needs a slice of repository/view-model state, and taking that as a
/// dependency directly would drag the whole coordinator in behind it.
@MainActor
protocol DailyLogDataSource: AnyObject {
  /// Open tasks that are due or starting today — the day's plan, derived rather
  /// than authored. Overdue tasks count: they are on today's plate too.
  var plannedTaskIdsForToday: [Int] { get }
  /// Titles for every open task, so the note can name an unfinished item.
  var taskTitlesById: [Int: String] { get }
  /// Whether the task list has actually arrived yet.
  ///
  /// Distinguishes "nothing is planned today" from "we don't know yet", which
  /// look identical through `plannedTaskIdsForToday` and must not: the snapshot
  /// is taken once per day, so mistaking the second for the first would freeze
  /// an empty plan in for the rest of the day.
  var hasLoadedTasks: Bool { get }
}

/// Coordinates the daily-log plugin with the rest of the app.
///
/// Everything durable lives in the plugin; this is the thin app-side layer that
/// decides *when* to snapshot the plan, when to mirror a closed day into
/// Obsidian, and what the Daily view is currently looking at.
@MainActor
@Observable final class DailyLogManager {
  /// Days of history after which the chart is showing a full window rather than
  /// a run-up.
  ///
  /// This no longer gates the chart — it is drawn from day one, because a flat
  /// run of days is a true statement about a history that has just started, and
  /// withholding it made the view look unfinished. All this now decides is
  /// whether the "collecting since …" line appears underneath to explain the
  /// flat left-hand side.
  static let fullChartHistoryDays = 14

  @ObservationIgnored private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "dailylog")
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored let plugin: any DailyLogPlugin

  @ObservationIgnored weak var dataSource: DailyLogDataSource?

  /// Called with an error message (or nil to clear) when a note write fails.
  @ObservationIgnored var onError: ((String?) -> Void)?

  /// Fired when a daily is ticked *on*, so the coordinator can celebrate it the
  /// way it celebrates a task close. Un-ticking deliberately doesn't fire:
  /// correcting a mis-click isn't an achievement.
  ///
  /// A callback rather than a direct call into the celebration manager, for the
  /// same reason `onError` is one — this manager shouldn't grow a dependency on
  /// the UI layer to report something that happened in the log.
  @ObservationIgnored var onDailyTicked: ((Daily) -> Void)?

  var dailyLogEnabled: Bool {
    didSet { preferencesStore.set(dailyLogEnabled, for: .dailyLogIntegrationEnabled) }
  }

  var dailiesFolderPath: String

  var chartRange: DailyChartRange {
    didSet { preferencesStore.set(chartRange.rawValue, for: .dailyLogChartRangeRawValue) }
  }

  /// Bumped whenever an event is recorded, purely so SwiftUI re-reads the
  /// projections. The event array itself is deliberately not `@Observable`
  /// state — it is owned by the plugin, and mirroring it here would mean two
  /// copies that can drift.
  private(set) var revision: Int = 0

  init(preferencesStore: PreferencesStore, plugin: any DailyLogPlugin) {
    self.preferencesStore = preferencesStore
    self.plugin = plugin
    self.dailyLogEnabled = preferencesStore.bool(.dailyLogIntegrationEnabled, default: false)
    self.dailiesFolderPath = plugin.dailiesFolderPath
    self.chartRange =
      DailyChartRange(rawValue: preferencesStore.int(.dailyLogChartRangeRawValue, default: 0))
      ?? .thirtyDays

    // A daily added or ticked by the MCP server lands in the same files this
    // reads, so bump the revision to re-run the projections. Same mechanism as
    // `record`, just triggered from outside the process.
    self.plugin.onExternalChange = { [weak self] in
      guard let self else { return }
      self.cachedCompletedDailyIds = nil
      self.revision &+= 1
    }
  }

  // MARK: - Recording
  //
  // Recording stays on even when the Obsidian half is disabled: the log is what
  // the Daily view reads, and a user who turns the vault mirror off still wants
  // their own history. `dailyLogEnabled` gates the *note writing*, not the log.

  func recordCompletion(taskId: Int, title: String, now: Date = Date()) {
    record(.completed(taskId: taskId, title: title, at: now))
  }

  func recordReopen(taskId: Int, title: String, now: Date = Date()) {
    record(.reopened(taskId: taskId, title: title, at: now))
  }

  func recordInvalidation(taskId: Int, title: String, now: Date = Date()) {
    record(.invalidated(taskId: taskId, title: title, at: now))
  }

  func recordDeferral(taskId: Int, title: String, now: Date = Date()) {
    record(.deferred(taskId: taskId, title: title, at: now))
  }

  func recordFocusSession(taskId: Int, title: String, seconds: Int, now: Date = Date()) {
    guard seconds > 0 else { return }
    record(.focusSessionEnded(taskId: taskId, title: title, seconds: seconds, at: now))
  }

  private func record(_ event: DayLogEvent) {
    plugin.record(event)
    revision &+= 1
  }

  // MARK: - Dailies
  //
  // Ticking a daily appends to the same log as a task completion, so it lands
  // in the chart alongside everything else and needs no separate history.

  /// Index of the selected daily within `todaysDailies`, for keyboard use.
  /// Clamped on read rather than maintained on every mutation, because the list
  /// can shrink underneath it (archiving, or a weekday-limited daily aging out
  /// at rollover) from places that have no business knowing about selection.
  var selectedDailyIndex: Int = 0

  /// Whether the inline "add a daily" field is open. Owned here rather than as
  /// view `@State` so the keyboard router can open it — and close it, which is
  /// what Escape does.
  var isAddingDaily: Bool = false
  var newDailyTitle: String = ""
  /// Schedule applied to the next daily added from the inline field. Sticky
  /// across commits so a run of "every other day" habits can be typed in one
  /// go, and reset by `cancelAddingDaily` along with everything else.
  var newDailySchedule: Daily.Schedule = .weekdays(Daily.allWeekdays)

  var todaysDailies: [Daily] { plugin.dailies(dueOn: Date()) }

  var allDailies: [Daily] { plugin.dailies }

  func isDailyCompleted(_ daily: Daily, on date: Date = Date()) -> Bool {
    completedDailyIds(on: date).contains(daily.id)
  }

  /// Memoised for the same reason the other projections are: the Daily view
  /// asks per row, and each ask would otherwise walk the whole log.
  @ObservationIgnored private var cachedCompletedDailyIds: (key: String, value: Set<String>)?

  func completedDailyIds(on date: Date = Date()) -> Set<String> {
    let key = "\(revision)|\(plugin.boundary.dayKey(for: date))"
    if let cachedCompletedDailyIds, cachedCompletedDailyIds.key == key {
      return cachedCompletedDailyIds.value
    }
    let value = plugin.completedDailyIds(on: date)
    cachedCompletedDailyIds = (key, value)
    return value
  }

  func toggleDaily(_ daily: Daily, now: Date = Date()) {
    let isDone = completedDailyIds(on: now).contains(daily.id)
    plugin.setDaily(id: daily.id, completed: !isDone, now: now)
    revision &+= 1
    // After the revision bump, so anything the handler reads back — the day's
    // count, in particular — already includes this tick.
    if !isDone { onDailyTicked?(daily) }
  }

  @discardableResult
  func addDaily(title: String, schedule: Daily.Schedule = .weekdays(Daily.allWeekdays)) -> Bool {
    guard plugin.addDaily(title: title, schedule: schedule) != nil else { return false }
    revision &+= 1
    return true
  }

  func renameDaily(_ daily: Daily, to title: String) {
    plugin.updateDaily(id: daily.id, title: title, schedule: nil)
    revision &+= 1
  }

  // MARK: Renaming
  //
  // A draft, not a live binding. See `DailyTitleEdit` for the bug that
  // distinction fixes — briefly: the store trims and rejects empties, which are
  // the right rules for a finished title and the wrong ones for a half-typed
  // word.

  /// Which daily is open for renaming, if any. Owned here rather than as view
  /// `@State` for the same reason `isAddingDaily` is: the keyboard router opens
  /// and closes it, and it has to survive the popover being redrawn.
  private(set) var editingDailyId: String?
  /// The draft title. Written on every keystroke, read by nobody but the field.
  var editingDailyTitle: String = ""

  func beginEditingDaily(_ daily: Daily) {
    // Adding and renaming are the same screen real estate and would fight over
    // focus, so opening one closes the other.
    cancelAddingDaily()
    editingDailyId = daily.id
    editingDailyTitle = daily.title
    selectDaily(daily)
  }

  @discardableResult
  func beginEditingSelectedDaily() -> Bool {
    guard let daily = selectedDaily else { return false }
    beginEditingDaily(daily)
    return true
  }

  /// Commits the draft and closes the editor. Committing an empty or unchanged
  /// draft is a no-op rather than an error — the editor still closes, because
  /// from the user's side pressing Return means "I'm done here" either way.
  func commitDailyEdit() {
    defer { cancelDailyEdit() }
    guard let id = editingDailyId,
      let daily = allDailies.first(where: { $0.id == id }),
      let title = DailyTitleEdit.committed(draft: editingDailyTitle, original: daily.title)
    else { return }
    renameDaily(daily, to: title)
  }

  func cancelDailyEdit() {
    editingDailyId = nil
    editingDailyTitle = ""
  }

  // MARK: Deleting

  /// Archives rather than removes, which is what makes this safe to call
  /// "delete" in the UI. The day log references dailies by id, so a real
  /// deletion would leave every past day that ticked this one rendering an
  /// orphaned identifier instead of a title. Archiving takes it out of every
  /// list you can see today and leaves history intact — see
  /// `DailyCollection.archive`.
  func deleteDaily(_ daily: Daily) {
    // An open editor pointing at a row that is about to vanish would leave the
    // field on screen with nothing behind it.
    if editingDailyId == daily.id { cancelDailyEdit() }
    archiveDaily(daily)
  }

  @discardableResult
  func deleteSelectedDaily() -> Daily? {
    guard let daily = selectedDaily else { return nil }
    deleteDaily(daily)
    return daily
  }

  /// Puts an archived daily back. The counterpart to `deleteDaily`, and the
  /// reason deleting is safe to do without a confirmation.
  func restoreDaily(_ daily: Daily) {
    plugin.restoreDaily(id: daily.id)
    revision &+= 1
  }

  /// Every archived daily, most recently archived first — what the settings
  /// pane offers to restore.
  var archivedDailies: [Daily] {
    plugin.allDailiesIncludingArchived
      .filter(\.isArchived)
      .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
  }

  func setDailySchedule(_ daily: Daily, to schedule: Daily.Schedule) {
    plugin.updateDaily(id: daily.id, title: nil, schedule: schedule)
    revision &+= 1
    // A daily can leave today's list by being rescheduled off it, so the cursor
    // has to be pulled back in the same way archiving does it.
    clampDailySelection()
  }

  func archiveDaily(_ daily: Daily) {
    plugin.archiveDaily(id: daily.id)
    revision &+= 1
    clampDailySelection()
  }

  func moveDaily(_ daily: Daily, by offset: Int) {
    plugin.moveDaily(id: daily.id, by: offset)
    revision &+= 1
  }

  // MARK: Daily selection

  var selectedDaily: Daily? {
    let today = todaysDailies
    guard today.indices.contains(selectedDailyIndex) else { return today.first }
    return today[selectedDailyIndex]
  }

  /// Moves the cursor to a specific daily, so a click leaves the keyboard
  /// selection where the user just pointed rather than back where it was.
  func selectDaily(_ daily: Daily) {
    guard let index = todaysDailies.firstIndex(where: { $0.id == daily.id }) else { return }
    selectedDailyIndex = index
  }

  func moveDailySelection(by offset: Int) {
    let count = todaysDailies.count
    guard count > 0 else { return }
    selectedDailyIndex = min(count - 1, max(0, selectedDailyIndex + offset))
  }

  func clampDailySelection() {
    let count = todaysDailies.count
    selectedDailyIndex = count == 0 ? 0 : min(count - 1, max(0, selectedDailyIndex))
  }

  /// Commits the inline add field. Returns false when there was nothing to add,
  /// so the caller can leave the field open rather than closing on an empty
  /// Return.
  @discardableResult
  func commitNewDaily() -> Bool {
    let title = newDailyTitle
    guard addDaily(title: title, schedule: newDailySchedule) else { return false }
    newDailyTitle = ""
    return true
  }

  func cancelAddingDaily() {
    isAddingDaily = false
    newDailyTitle = ""
    newDailySchedule = .weekdays(Daily.allWeekdays)
  }

  // MARK: - Day lifecycle

  /// Snapshots today's plan if it hasn't been taken yet, then mirrors any day
  /// that has closed since the last run. Safe to call on every popover open —
  /// both halves are idempotent within a logical day.
  func refreshForToday(now: Date = Date()) {
    // Skipped entirely — not stamped as done — until the list has loaded, so
    // the next call (the deferred one at launch, or the next popover open)
    // still gets to take the day's real plan.
    if let dataSource, dataSource.hasLoadedTasks {
      plugin.snapshotPlanIfNeeded(plannedTaskIds: dataSource.plannedTaskIdsForToday, now: now)
      revision &+= 1
    }

    guard dailyLogEnabled else { return }
    plugin.writeClosedDayNotesIfNeeded(
      now: now,
      titlesByTaskId: dataSource?.taskTitlesById ?? [:]
    )
  }

  /// A day as markdown, for a destination that is not the vault.
  ///
  /// The same rendering `writeDailyNote` splices into an Obsidian note, so a
  /// day reads identically wherever it is written. The markers come with it;
  /// stripping them is the caller's business, because only the caller knows
  /// whether its destination can carry an HTML comment.
  func renderedDaySection(for day: Date = Date()) -> String {
    DailyNoteMarkdown.section(
      summary: summary(on: day),
      titlesByTaskId: dataSource?.taskTitlesById ?? [:],
      dailies: plugin.dailies(dueOn: day)
    )
  }

  /// The file-name pattern dailies are named with, so another integration can
  /// title a day the same way this one names it.
  var dayTitlePattern: String { plugin.noteFormat.fileNameFormat }

  /// Writes a day's note on demand, regardless of the automatic setting.
  @discardableResult
  func writeNoteNow(for day: Date = Date()) -> Bool {
    guard dailyLogEnabled else {
      onError?("Enable the Daily Log integration in Preferences first.")
      return false
    }
    do {
      _ = try plugin.writeDailyNote(
        for: day,
        titlesByTaskId: dataSource?.taskTitlesById ?? [:]
      )
      onError?(nil)
      return true
    } catch {
      onError?(error.localizedDescription)
      return false
    }
  }

  // MARK: - Folder

  @discardableResult
  func chooseDailiesFolder() -> Bool {
    do {
      guard let path = try plugin.chooseDailiesFolder() else { return false }
      dailiesFolderPath = path
      onError?(nil)
      return true
    } catch {
      onError?("Failed to save dailies folder access.")
      return false
    }
  }

  func clearDailiesFolder() {
    plugin.clearDailiesFolder()
    dailiesFolderPath = ""
    // Enabled-with-nowhere-to-write is not a state worth keeping: it would fail
    // on every rollover and log an error a day forever.
    dailyLogEnabled = false
  }

  // MARK: - Projections
  //
  // Memoised because these are called from view bodies, and were called from
  // the legacy panel's height calculation on every layout pass. Each projection
  // nets completions across the entire log, so recomputing them per pass would
  // have put the whole history on the layout path. The cache key folds in
  // `revision` and the logical day, so a new event or a rollover invalidates it
  // without anything having to remember to.

  @ObservationIgnored private var cachedSummary: (key: String, value: DayLogAggregator.DaySummary)?
  @ObservationIgnored private var cachedBuckets: (key: String, value: [DayLogAggregator.Bucket])?
  @ObservationIgnored private var cachedStreak: (key: String, value: Int)?

  func summary(on date: Date = Date()) -> DayLogAggregator.DaySummary {
    let key = "\(revision)|\(plugin.boundary.dayKey(for: date))"
    if let cachedSummary, cachedSummary.key == key { return cachedSummary.value }
    let value = plugin.summary(on: date)
    cachedSummary = (key, value)
    return value
  }

  /// Everything finished today — task closes *and* daily ticks — which is the
  /// same pairing the chart counts, so the celebration tally can't disagree with
  /// the bar the user is looking at.
  ///
  /// Both halves are memoised already, so this is cheap enough to call on the
  /// completion path.
  func completedTodayCount(on date: Date = Date()) -> Int {
    summary(on: date).completedCount + completedDailyIds(on: date).count
  }

  /// Consecutive days *before* today on which something was completed.
  ///
  /// Today is excluded by the aggregator on purpose, so the two completion
  /// funnels agree: the task path classifies its milestone before the close is
  /// recorded and the daily path after it, and a streak that counted today
  /// would come out a day apart depending on which asked. Callers add the day
  /// they are in the middle of earning.
  ///
  /// Memoised on the log's revision, like the rest of this file's projections:
  /// it walks a day at a time and stops at the first gap, but the completion
  /// path is not the place to re-derive it per keystroke.
  func priorCompletionStreak(now: Date = Date()) -> Int {
    let key = "\(revision)|\(plugin.boundary.dayKey(for: now))"
    if let cachedStreak, cachedStreak.key == key { return cachedStreak.value }
    let value = DayLogAggregator.priorCompletionStreak(
      events: plugin.events,
      boundary: plugin.boundary,
      now: now
    )
    cachedStreak = (key, value)
    return value
  }

  func chartBuckets(now: Date = Date()) -> [DayLogAggregator.Bucket] {
    let key = "\(revision)|\(chartRange.rawValue)|\(plugin.boundary.dayKey(for: now))"
    if let cachedBuckets, cachedBuckets.key == key { return cachedBuckets.value }
    let value =
      chartRange.isWeekly
      ? plugin.weeklyBuckets(endingOn: now, weeks: chartRange.bucketCount)
      : plugin.dailyBuckets(endingOn: now, days: chartRange.bucketCount)
    cachedBuckets = (key, value)
    return value
  }

  /// Also on the layout path via `panelHeight`, so it gets the same treatment.
  @ObservationIgnored private var cachedRecordedDayCount: (revision: Int, value: Int)?

  var hasFullChartHistory: Bool {
    if let cachedRecordedDayCount, cachedRecordedDayCount.revision == revision {
      return cachedRecordedDayCount.value >= Self.fullChartHistoryDays
    }
    let value = plugin.recordedDayCount
    cachedRecordedDayCount = (revision, value)
    return value >= Self.fullChartHistoryDays
  }

  var firstRecordedDay: Date? { plugin.firstRecordedDay }
}
