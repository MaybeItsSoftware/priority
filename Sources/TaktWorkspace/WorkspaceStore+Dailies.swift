import Foundation
import TaktRustCore
import TaktCore

/// Dailies, the contributions logged against them, and the ranking that feeds
/// the focus screen. Split from `WorkspaceStore.swift` only for size; this is
/// the same type and the same database.
extension WorkspaceStore {

  // MARK: - Dailies

  /// Every non-archived daily due on `day`, joined to its task and to that
  /// day's contribution, in display order.
  public func dailies(on day: Date = .now, calendar: Calendar = .current) throws -> [DailyItem] {
    // The Rust core's `rows::dailies_on`: a habit when its rule shows it, any
    // other daily when it is due, never one whose task is gone or is a list.
    try Self.mappingCoreErrors {
      try core.dailiesOn(dayMs: day.coreMilliseconds, zone: calendar.timeZone.identifier)
    }.map(DailyItem.init)
  }

  /// Every daily regardless of schedule — what a settings editor lists.
  public func allDailies() throws -> [WorkspaceDaily] {
    try Self.mappingCoreErrors { try core.allDailies() }.map(WorkspaceDaily.init)
  }

  public func daily(forTaskId taskId: String) throws -> WorkspaceDaily? {
    try Self.mappingCoreErrors { try core.dailyForTask(taskId: taskId) }.map(WorkspaceDaily.init)
  }

  /// Makes `taskId` a daily, or returns the one it already has. Idempotent so
  /// the inspector's toggle can be driven from anywhere without checking first.
  /// Makes a task a daily: the Rust core's `dailies::make_daily`.
  @discardableResult
  public func makeDaily(
    taskId: String,
    weekdays: Set<Int> = Set(1...7),
    intervalDays: Int? = nil,
    targetSeconds: Int? = nil,
    now: Date = .now
  ) throws -> WorkspaceDaily {
    let id = try coreWrite {
      try core.makeDaily(
        taskId: taskId, weekdays: weekdays.sorted().map { UInt32(clamping: $0) },
        intervalDays: intervalDays.map(Int64.init), targetSeconds: targetSeconds.map(Int64.init),
        nowMs: now.coreMilliseconds)
    }
    guard let daily = try Self.mappingCoreErrors({ try core.daily(id: id) }).map(WorkspaceDaily.init) else {
      throw WorkspaceStoreError.missingDaily
    }
    return daily
  }

  /// Archives rather than deletes, so logged contributions keep a parent.
  public func archiveDaily(taskId: String, now: Date = .now) throws {
    try coreWrite { try core.archiveDaily(taskId: taskId, nowMs: now.coreMilliseconds) }
  }

  /// Edits a daily: the Rust core's `dailies::update_daily`. A doubly
  /// optional field left nil keeps its value; `.some(nil)` clears it.
  public func updateDaily(
    id: String, weekdays: Set<Int>? = nil, intervalDays: Int?? = nil, targetSeconds: Int?? = nil, now: Date = .now
  ) throws {
    let days: [UInt32]? = weekdays.map { set in set.sorted().map { UInt32(clamping: $0) } }
    let interval: Int64? = (intervalDays ?? nil).map { Int64($0) }
    let target: Int64? = (targetSeconds ?? nil).map { Int64($0) }
    let edit = DailyEdit(
      weekdays: days, setInterval: intervalDays != nil, intervalDays: interval,
      setTarget: targetSeconds != nil, targetSeconds: target)
    try coreWrite { try core.updateDaily(id: id, edit: edit, nowMs: now.coreMilliseconds) }
  }

  /// Records progress against a daily's task for `day`, accumulating seconds
  /// onto any contribution already logged that day.
  ///
  /// `complete` marks the day's commitment met. Passing `false` with seconds is
  /// how a part-finished focus block is credited without claiming the day.
  @discardableResult
  public func logContribution(
    dailyId: String, seconds: Int = 0, complete: Bool = true, now: Date = .now, calendar: Calendar = .current
  ) throws -> DailyContribution {
    // The Rust core's `dailies::log_contribution`, keyed on the calendar's day.
    let id = try coreWrite {
      try core.logContribution(
        dailyId: dailyId, seconds: Int64(seconds), complete: complete, nowMs: now.coreMilliseconds,
        zone: calendar.timeZone.identifier)
    }
    guard let contribution = try Self.mappingCoreErrors({ try core.contribution(id: id) }).map(DailyContribution.init) else {
      throw WorkspaceStoreError.missingDaily
    }
    return contribution
  }

  /// Un-ticks a day without discarding the time already logged against it.
  public func clearContribution(dailyId: String, on day: Date = .now, calendar: Calendar = .current) throws {
    try coreWrite {
      try core.clearContribution(dailyId: dailyId, dayMs: day.coreMilliseconds, zone: calendar.timeZone.identifier)
    }
  }

  /// Contributions for one daily over the last `days` days, oldest first — the
  /// run of days behind a streak.
  public func contributionHistory(
    dailyId: String, days: Int, endingOn day: Date = .now, calendar: Calendar = .current
  ) throws -> [DailyContribution] {
    let keys = (0..<max(1, days)).compactMap { offset -> String? in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: day) else { return nil }
      return DailyContribution.dayKey(for: date, calendar: calendar)
    }
    return try Self.mappingCoreErrors { try core.contributions(dailyId: dailyId, dayKeys: keys) }
      .map(DailyContribution.init)
  }

  // MARK: - Completion context

  /// What a celebration needs to know about today, in one read.
  ///
  /// Both numbers are questions about *today* rather than about the task being
  /// completed, which is why they are fetched together: asking twice invites
  /// the two halves to disagree about where the day boundary fell.
  public struct CompletionContext: Sendable, Equatable {
    /// How many things have already been finished today, this one included.
    /// 1 means "the first thing today", which is what earns the streak note.
    public let ordinalToday: Int
    /// Consecutive days ending today on which something was finished.
    public let streakDays: Int

    public init(ordinalToday: Int, streakDays: Int) {
      self.ordinalToday = ordinalToday
      self.streakDays = streakDays
    }
  }

  public func completionContext(now: Date = .now, calendar: Calendar = .current) throws -> CompletionContext {
    // The Rust core's `rows::completion_context`, streak walk included.
    let context = try Self.mappingCoreErrors {
      try core.completionContext(nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier)
    }
    return CompletionContext(ordinalToday: Int(context.ordinalToday), streakDays: Int(context.streakDays))
  }

  // MARK: - Next up

  /// Every open task that could reasonably be done now, flattened into the
  /// shape `NextUpSelector` scores.
  ///
  /// Tasks with open children are left out: you do not "do" a project, you do
  /// its next leaf, and offering the parent on the focus screen means offering
  /// something that can never be finished in one sitting. Dailies already
  /// contributed to today are excluded rather than scored down, so ticking one
  /// visibly removes it from consideration.
  public func nextUpCandidates(now: Date = .now, calendar: Calendar = .current) throws -> [NextUpCandidate] {
    // The Rust core's `focus::candidates`.
    try Self.mappingCoreErrors {
      try core.nextUpCandidates(nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier)
    }.map(NextUpCandidate.init)
  }

  /// Writes a hand-arranged focus order: every task in `orderedTaskIDs` takes
  /// its position in that array as its rank.
  ///
  /// The whole visible order is written, not just the task that moved. Ranking
  /// one task by hand while its neighbours keep floating on score produces an
  /// order that rearranges itself the moment anything changes, which is the
  /// opposite of what dragging something into place asks for.
  /// Pins one task to `index` in the ladder, leaving every other task to be
  /// ordered by score around it.
  ///
  /// Deliberately one task rather than the whole visible order. Writing the
  /// entire ladder is what froze it: every task acquired a rank from a single
  /// nudge, after which nothing could ever be re-ranked again.
  public func pinTask(id taskId: String, atIndex index: Int, now: Date = .now) throws {
    try coreWrite { try core.pinTask(taskId: taskId, index: Int64(index), nowMs: now.coreMilliseconds) }
  }

  /// Releases one task back to the ranking.
  public func unpinTask(id taskId: String, now: Date = .now) throws {
    try coreWrite { try core.unpinTask(taskId: taskId, nowMs: now.coreMilliseconds) }
  }

  /// Hands the ladder back to the ranking.
  public func clearFocusOrder(now: Date = .now) throws {
    try coreWrite { try core.clearFocusOrder(nowMs: now.coreMilliseconds) }
  }

  public func hasManualFocusOrder() throws -> Bool {
    try Self.mappingCoreErrors { try core.hasManualFocusOrder() }
  }

  /// Pushes a task out of consideration until `date` by setting its start time.
  /// This is what "schedule it for later" on the focus screen writes.
  public func scheduleTask(id: String, startAt: Date?, now: Date = .now) throws {
    // The Rust core's `editor::schedule_task`.
    try coreWrite {
      try core.scheduleTask(id: id, startAtMs: startAt?.coreMilliseconds, nowMs: now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
  }

  /// Brings the plugin-era dailies across: each becomes a task in a "Habits"
  /// list with a daily attached to it, on the same schedule.
  ///
  /// `progressTaskIDs` are workspace tasks already flagged for daily progress
  /// under the old UserDefaults scheme; they keep their task and simply gain a
  /// daily. Both halves match on identity, so running this twice is a no-op.
  @discardableResult
  public func importLegacyDailies(
    _ legacy: [TaktWorkspace.LegacyDailySeed], progressTaskIDs: [String] = [], now: Date = .now
  ) throws -> Int {
    // The Rust core's `imports::import_legacy_dailies`.
    let seeds = legacy.map { seed in
      TaktRustCore.LegacyDailySeed(
        id: seed.id, title: seed.title, weekdays: seed.activeWeekdays.sorted().map { UInt32(clamping: $0) },
        intervalDays: seed.intervalDays.map { Int64($0) }, intervalAnchorMs: seed.intervalAnchor?.coreMilliseconds,
        targetSeconds: seed.targetSeconds.map { Int64($0) }, archivedAtMs: seed.archivedAt?.coreMilliseconds,
        createdAtMs: seed.createdAt.coreMilliseconds)
    }
    let imported = try coreWrite {
      try core.importLegacyDailies(legacy: seeds, progressTaskIds: progressTaskIDs, nowMs: now.coreMilliseconds)
    }
    return Int(imported)
  }
}
