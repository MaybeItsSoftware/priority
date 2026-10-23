import AppKit
import Foundation
import TaktCore
import TaktWorkspace

/// Starting each day afresh: at the hour the day changes — the daily log's,
/// 04:00 unless you moved it — what holds goes back to the conditions you
/// start every day with, as the core's `day_start` decides.
///
/// The Mac looks at launch, whenever the context is read again (after the
/// CLI, the agent or a pull wrote it), on coming to the front, and on the
/// focus clock's tick, so a Mac left on overnight starts the day at four
/// rather than when it is next touched. The core resets once a day, on
/// whichever device looks first.
@MainActor
extension WorkspaceViewModel {
  /// Reads how each day starts, and starts it if it has changed. Run before
  /// the context is read. The first time, an hour this Mac's daily log kept
  /// before the account had one is brought in; after that the account's hour
  /// is the daily log's too, so a change made on another device lands here.
  /// Returns whether the context was reset.
  @discardableResult
  func startDayIfDue(now: Date = .now) -> Bool {
    guard let store, let workspace else { return false }
    let defaults = UserDefaults.standard
    let key = DailyLogService.rolloverHourDefaultsKey
    if lastDayStartCheck == .distantPast, defaults.object(forKey: key) != nil {
      _ = try? store.adoptDayStartHour(defaults.integer(forKey: key), now: now)
    }
    lastDayStartCheck = now
    guard var settings = try? store.dayStart() else { return false }
    var reset = false
    if settings.isDue(at: now) {
      reset = (try? store.applyDayStart(in: workspace.id, now: now)) ?? false
      settings = (try? store.dayStart()) ?? settings
    }
    if dayStart != settings { dayStart = settings }
    // Written straight to the key, not through the daily log's setter, which
    // would send it back to the account as a change made here.
    let local = defaults.object(forKey: key) == nil ? DayBoundary.defaultRolloverHour : defaults.integer(forKey: key)
    if local != settings.hour { defaults.set(settings.hour, forKey: key) }
    return reset
  }

  /// The focus clock's question, every half minute: has the day changed?
  /// Answered without the core's write unless it has.
  func checkDayStart(now: Date) {
    guard now.timeIntervalSince(lastDayStartCheck) >= 30 else { return }
    lastDayStartCheck = now
    guard dayStart.isDue(at: now) else { return }
    restoreFocusContext()
  }

  /// Saves how each day starts. Changing it never resets there and then:
  /// today counts as started.
  private func saveDayStart(_ change: (inout DayStart) -> Void) {
    guard let store else { return }
    var next = dayStart
    change(&next)
    guard next != dayStart else { return }
    perform(mirrors: false) {
      try store.setDayStart(next)
      dayStart = try store.dayStart()
      UserDefaults.standard.set(dayStart.hour, forKey: DailyLogService.rolloverHourDefaultsKey)
    }
  }

  /// Whether each day starts afresh, or what holds carries over.
  func setDayStartResets(_ resets: Bool) {
    saveDayStart { $0.resets = resets }
  }

  /// The hour the day changes, wrapping round the clock.
  func setDayStartHour(_ hour: Int) {
    saveDayStart { $0.hour = (hour % 24 + 24) % 24 }
  }

  /// The hour set in the daily log's settings, which the account follows.
  func dayChangeHourChangedElsewhere(_ hour: Int) {
    guard hour != dayStart.hour else { return }
    saveDayStart { $0.hour = hour }
  }

  /// Ticks a condition the day starts with, or off; a place replaces the
  /// last place, as saying where you are does. Ticking one switches the
  /// reset on. Returns the conditions as saved.
  @discardableResult
  func toggleDayStartCondition(_ id: String) -> [String] {
    let places = Set(focusConditions.filter(\.isLocation).map(\.id))
    saveDayStart { settings in
      if settings.conditionIDs.contains(id) {
        settings.conditionIDs.remove(id)
      } else {
        settings.conditionIDs = FocusContextSelection.changing(
          settings.conditionIDs, on: [id], off: [], locationIDs: places)
        settings.resets = true
      }
    }
    return Array(dayStart.conditionIDs)
  }

  /// The conditions each day starts with, in the tab's order, or nil with
  /// none: "Home · Laptop".
  var dayStartSummary: String? {
    let names = focusConditions.filter { dayStart.conditionIDs.contains($0.id) && !$0.isArchived }.map(\.name)
    return names.isEmpty ? nil : names.joined(separator: " · ")
  }

  /// Space and `p` on "Start each day"'s rows, which the tab's other rows
  /// read differently: Space switches starting afresh, and on "Start with"
  /// Space or `p` opens the picker. Whether the command was taken.
  func runDayStartCommand(_ id: WorkspaceCommandID) -> Bool {
    switch (id, conditionsCursorStop) {
    case (.conditionsToggle, .dayStart): setDayStartResets(!dayStart.resets)
    case (.conditionsToggle, .dayStartConditions), (.conditionsProvides, .dayStartConditions): presentDayStartPicker()
    case (.conditionsToggle, .dayStartHour): break
    default: return false
    }
    return true
  }

  /// `p` or Return on "Start with": the picker, ticking the starting set.
  func presentDayStartPicker() {
    presentOverlay(.conditions(WorkspaceConditionPickerRequest(dayStart: ())))
  }
}
