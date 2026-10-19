import Foundation
import TaktCore
import TaktWorkspace

/// What a row or card says about a task filed in Waiting on: who it waits on,
/// as a chip, and when it will be chased — `↻ Tue 14:00 · #2 · every 3d`,
/// the follow-up time with the core's `waiting::chase_label` after it.
/// Android's `OutlineRow.waitingOn` and `followUp`.
struct WaitingBadge: Equatable, Sendable {
  var waitingOn: String?
  var followUp: String?

  /// Nil unless the task is in Waiting on and has something to say. The
  /// follow-up time is only for an open task: a done one will not be chased.
  static func make(
    _ details: TaskWaitingDetails?, column: String?, status: TaskStatus, now: Date = .now,
    calendar: Calendar = .current
  ) -> WaitingBadge? {
    guard let details, column == WaitingFollowUp.waitingColumnID else { return nil }
    let followUp = details.followUpAt.flatMap { at in
      status == .open ? WaitingFollowUp.label(at, chase: details.chase, now: now, calendar: calendar) : nil
    }
    guard details.waitingOn != nil || followUp != nil else { return nil }
    return WaitingBadge(waitingOn: details.waitingOn, followUp: followUp)
  }
}

/// The inspector's Waiting on section, before it is saved: who, when to
/// follow up and how often to again. Saved whole by the section's own
/// button through `WorkspaceStore.setWaiting`, as Android's `WaitingSection`
/// does — waiting is task metadata, not part of the editor draft.
struct WaitingForm: Equatable {
  var tag: String
  var followUpAt: Date?
  /// Every how many days to follow up again; nil is once.
  var everyDays: Int?

  init(tag: String = "", followUpAt: Date? = nil, everyDays: Int? = nil) {
    self.tag = tag
    self.followUpAt = followUpAt
    self.everyDays = everyDays
  }

  /// The form as the store has it.
  init(saved: TaskWaitingDetails?) {
    self.init(tag: saved?.waitingOn ?? "", followUpAt: saved?.followUpAt, everyDays: saved?.followUpEveryDays)
  }

  /// The repeat that is saved: none without a follow-up time, as the core
  /// drops it.
  var savedEveryDays: Int? { followUpAt == nil ? nil : everyDays }

  /// The tag that is saved: trimmed and clipped by the core, nil when empty.
  var savedTag: String? { WaitingFollowUp.normalizedTag(tag) }

  /// Whether saving would change anything stored.
  func differs(from saved: TaskWaitingDetails?) -> Bool {
    savedTag != saved?.waitingOn
      || followUpAt.map(Self.minute) != saved?.followUpAt.map(Self.minute)
      || savedEveryDays != saved?.followUpEveryDays
  }

  /// Whether there is anything to clear.
  static func hasWaiting(_ saved: TaskWaitingDetails?) -> Bool {
    saved?.waitingOn != nil || saved?.followUpAt != nil
  }

  /// What the section's footnote says will happen.
  func hint(title: String) -> String {
    guard followUpAt != nil else {
      return "Files it in Waiting on. Pick a time to have a follow-up land in Today."
    }
    let followUp = "“\(WaitingFollowUp.title(for: title, waitingOn: savedTag))”"
    guard let every = savedEveryDays else { return "If it is still waiting then, \(followUp) lands in Today." }
    return "If it is still waiting then, \(followUp) lands in Today; once that is done, the next lands "
      + "\(WaitingFollowUp.repeatText(every).lowercased()) later, numbered #2, #3."
  }

  // MARK: - The repeat

  /// The repeat a stepper starts from when "Every few days" is chosen.
  static let defaultEveryDays = 3

  /// One press of the repeat's − or +: a day at a time up to a week, then a
  /// week at a time, within `WaitingFollowUp.everyDaysRange`. Android's
  /// `WaitingFollowUp.stepEveryDays`.
  static func step(_ days: Int, by direction: Int) -> Int {
    let step = days > 7 || (days == 7 && direction > 0) ? 7 : 1
    let range = WaitingFollowUp.everyDaysRange
    return min(max(days + direction * step, range.lowerBound), range.upperBound)
  }

  // MARK: - The follow-up time

  /// The quick choices under the follow-up toggle: tomorrow, in three days
  /// and in a week, each at 9:00.
  static func quickChoices(now: Date = .now, calendar: Calendar = .current) -> [(title: String, date: Date)] {
    [("Tomorrow 9:00", 1), ("In 3 days", 3), ("Next week", 7)].compactMap { title, days in
      morning(daysAfter: days, now: now, calendar: calendar).map { (title, $0) }
    }
  }

  /// What switching follow-up on starts from: tomorrow at 9:00.
  static func defaultFollowUp(now: Date = .now, calendar: Calendar = .current) -> Date {
    morning(daysAfter: 1, now: now, calendar: calendar) ?? now
  }

  /// 9:00 on the day `days` after `now`'s.
  private static func morning(daysAfter days: Int, now: Date, calendar: Calendar) -> Date? {
    guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) else { return nil }
    return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
  }

  /// A date to the minute, as the core keeps a follow-up time.
  static func minute(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
  }
}
