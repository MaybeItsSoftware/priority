import Foundation
import TaktCore

@MainActor
final class NativeDailyLogPlugin: DailyLogPlugin {
  let pluginIdentifier = "native.dailylog.integration"
  let displayName = "Native Daily Log"
  let pluginDescription =
    "Record what you finish each day, chart it, and mirror the day into your Obsidian daily note."

  private let service: DailyLogService

  init(service: DailyLogService = DailyLogService()) {
    self.service = service
  }

  // MARK: - Vault location

  var dailiesFolderPath: String { service.dailiesFolderPath }

  func chooseDailiesFolder() throws -> String? {
    try service.chooseDailiesFolder()
  }

  func clearDailiesFolder() {
    service.clearDailiesFolder()
  }

  // MARK: - Configuration

  var rolloverHour: Int {
    get { service.rolloverHour }
    set { service.rolloverHour = newValue }
  }

  var boundary: DayBoundary { service.boundary }

  var noteFormat: DailyNoteFormat {
    get { service.noteFormat }
    set { service.noteFormat = newValue }
  }

  var createsMissingNotes: Bool {
    get { service.createsMissingNotes }
    set { service.createsMissingNotes = newValue }
  }

  var writesNotesAutomatically: Bool {
    get { service.writesNotesAutomatically }
    set { service.writesNotesAutomatically = newValue }
  }

  // MARK: - Log

  var events: [DayLogEvent] { service.events }

  var onExternalChange: (() -> Void)? {
    get { service.onExternalChange }
    set { service.onExternalChange = newValue }
  }

  func record(_ event: DayLogEvent) {
    service.record(event)
  }

  func snapshotPlanIfNeeded(plannedTaskIds: [Int], now: Date) {
    service.snapshotPlanIfNeeded(plannedTaskIds: plannedTaskIds, now: now)
  }

  // MARK: - Dailies

  var dailies: [Daily] { service.dailies }

  func dailies(dueOn date: Date) -> [Daily] {
    service.dailies(dueOn: date)
  }

  func completedDailyIds(on date: Date) -> Set<String> {
    service.completedDailyIds(on: date)
  }

  @discardableResult
  func addDaily(title: String, schedule: Daily.Schedule) -> Daily? {
    service.addDaily(title: title, schedule: schedule)
  }

  func updateDaily(id: String, title: String?, schedule: Daily.Schedule?) {
    service.updateDaily(id: id, title: title, schedule: schedule)
  }

  func archiveDaily(id: String) {
    service.archiveDaily(id: id)
  }

  func restoreDaily(id: String) {
    service.restoreDaily(id: id)
  }

  var allDailiesIncludingArchived: [Daily] { service.allDailiesIncludingArchived }

  func moveDaily(id: String, by offset: Int) {
    service.moveDaily(id: id, by: offset)
  }

  @discardableResult
  func setDaily(id: String, completed: Bool, now: Date) -> Bool {
    service.setDaily(id: id, completed: completed, now: now)
  }

  // MARK: - Projections
  //
  // Forwarded rather than left to callers so the Daily view never has to know
  // that `DayLogAggregator` exists, let alone hold the event array itself.

  func summary(on date: Date) -> DayLogAggregator.DaySummary {
    service.summary(on: date)
  }

  func dailyBuckets(endingOn now: Date, days: Int) -> [DayLogAggregator.Bucket] {
    service.dailyBuckets(endingOn: now, days: days)
  }

  func weeklyBuckets(endingOn now: Date, weeks: Int) -> [DayLogAggregator.Bucket] {
    service.weeklyBuckets(endingOn: now, weeks: weeks)
  }

  var recordedDayCount: Int { service.recordedDayCount }

  var firstRecordedDay: Date? { service.firstRecordedDay }

  // MARK: - Notes

  @discardableResult
  func writeDailyNote(for day: Date, titlesByTaskId: [Int: String]) throws -> URL {
    try service.writeDailyNote(for: day, titlesByTaskId: titlesByTaskId)
  }

  func writeClosedDayNotesIfNeeded(now: Date, titlesByTaskId: [Int: String]) {
    service.writeClosedDayNotesIfNeeded(now: now, titlesByTaskId: titlesByTaskId)
  }
}
