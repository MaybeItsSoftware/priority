import Foundation
import TaktCore

/// Contract for the daily-log capability: record what happened, project it, and
/// mirror a finished day into an Obsidian daily note.
///
/// Unlike the other plugin contracts this one does *not* live in
/// `PluginProtocols.swift`, and it is excluded from the `TaktPlugins` SPM
/// target. It traffics in `TaktCore` types (`DayLogEvent`, `DayBoundary`),
/// and since a file can only belong to one SPM target, `TaktPlugins`
/// cannot import the module that defines them — the same constraint that keeps
/// `MCPClientInstaller.swift` app-only. Nothing is lost in coverage: the logic
/// worth testing lives in `CoreLogic/` and is exercised by `corelogic-tests`.
/// `AnyObject`-constrained, unlike the other plugin contracts: this one has
/// settable configuration, and settings UI writes to it through a `let`
/// reference. Without the class constraint those writes wouldn't compile.
@MainActor
protocol DailyLogPlugin: Plugin, AnyObject {
  // MARK: Vault location

  /// Path of the folder holding the daily notes, or "" when unconfigured.
  var dailiesFolderPath: String { get }
  func chooseDailiesFolder() throws -> String?
  func clearDailiesFolder()

  // MARK: Configuration

  /// Hour at which one logical day becomes the next.
  var rolloverHour: Int { get set }
  var boundary: DayBoundary { get }
  var noteFormat: DailyNoteFormat { get set }
  /// Whether a missing daily note may be created. Off by default so the plugin
  /// can never race a Templater/Daily Notes template into existence.
  var createsMissingNotes: Bool { get set }
  /// Whether a day's note is written automatically once that day has closed.
  var writesNotesAutomatically: Bool { get set }

  // MARK: Log

  var events: [DayLogEvent] { get }
  func record(_ event: DayLogEvent)

  /// Fired after a change made *outside this process* — an MCP `daily_add` or
  /// `daily_tick`, or the user editing the files by hand — has been reloaded.
  /// The UI reads its projections straight off the plugin, so without this a
  /// external edit would only appear after a relaunch.
  var onExternalChange: (() -> Void)? { get set }

  /// Fired when a write that should have reached disk did not — a log append
  /// that failed, a dailies edit that could not be saved — or when the dailies
  /// file exists but will not decode. The plugin keeps the in-memory state
  /// usable in every case, so this is a report, not a failure: the UI should
  /// tell the user their history or configuration is not being kept, the way
  /// `DailyLogManager.onError` surfaces a failed note write.
  var onPersistenceError: ((Error) -> Void)? { get set }

  /// Captures the day's plan once per logical day. Repeat calls within the same
  /// day are ignored, so this is safe to call on every popover open.
  func snapshotPlanIfNeeded(plannedTaskIds: [Int], now: Date)

  // MARK: Dailies
  //
  // The set of dailies is configuration and is edited in place; whether one is
  // *done* is a question about a specific day and is answered from the log. The
  // two are stored separately for that reason, and nothing here caches
  // done-ness — see `Daily`.

  /// Every non-archived daily, in the user's display order.
  var dailies: [Daily] { get }
  /// The dailies expected on the logical day containing `date`, in order.
  func dailies(dueOn date: Date) -> [Daily]
  /// Ids ticked off on the logical day containing `date`.
  func completedDailyIds(on date: Date) -> Set<String>

  @discardableResult
  func addDaily(title: String, schedule: Daily.Schedule) -> Daily?
  func updateDaily(id: String, title: String?, schedule: Daily.Schedule?)
  /// Archives rather than deletes, so days that recorded a tick against this id
  /// still render with a title instead of an orphan. This is what the UI calls
  /// "delete" — see `DailyLogManager.deleteDaily`.
  func archiveDaily(id: String)
  /// Puts an archived daily back where it was. The inverse of `archiveDaily`,
  /// and what makes deleting reversible.
  func restoreDaily(id: String)
  /// Archived ones included, for the restore list. Every other reader wants
  /// `dailies`, which is active-only.
  var allDailiesIncludingArchived: [Daily] { get }
  func moveDaily(id: String, by offset: Int)

  /// Ticks or un-ticks a daily for the logical day containing `now`. Returns the
  /// resulting state. Idempotent — setting it to what it already is records
  /// nothing, so a double tap can't litter the log.
  @discardableResult
  func setDaily(id: String, completed: Bool, now: Date) -> Bool

  // MARK: Projections
  //
  // Exposed on the plugin rather than left to callers so the Daily view never
  // has to know `DayLogAggregator` exists, let alone hold the event array and
  // risk projecting it differently from the note writer.

  func summary(on date: Date) -> DayLogAggregator.DaySummary
  func dailyBuckets(endingOn now: Date, days: Int) -> [DayLogAggregator.Bucket]
  func weeklyBuckets(endingOn now: Date, weeks: Int) -> [DayLogAggregator.Bucket]
  /// Distinct logical days with at least one event — how the Daily view decides
  /// whether there is enough history to draw a chart.
  var recordedDayCount: Int { get }
  var firstRecordedDay: Date? { get }

  // MARK: Notes

  @discardableResult
  func writeDailyNote(for day: Date, titlesByTaskId: [Int: String]) throws -> URL

  /// Writes the note for any closed day that hasn't been mirrored yet. No-op
  /// unless `writesNotesAutomatically` is on and a folder is configured.
  func writeClosedDayNotesIfNeeded(now: Date, titlesByTaskId: [Int: String])
}
