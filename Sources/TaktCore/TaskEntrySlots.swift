import Foundation

/// Where the keyboard is in the add field: the title, or one of the three
/// slots to the right of it. → walks right through them, ← back, and ← from
/// the date slot is the text again with the caret at its end.
public enum TaskEntryFocus: Int, CaseIterable, Sendable, Equatable {
  case text
  case date
  case conditions
  case estimate

  /// → or Tab: the slot to the right, staying on the last one.
  public var next: TaskEntryFocus {
    TaskEntryFocus(rawValue: rawValue + 1) ?? self
  }

  /// ← or ⇧Tab: the slot to the left, ending at the text.
  public var previous: TaskEntryFocus {
    TaskEntryFocus(rawValue: rawValue - 1) ?? .text
  }

  public var isSlot: Bool { self != .text }
}

/// What a key in a slot asks of the field around it. The slot's own values
/// change in `TaskEntryDraft`; these are the things the draft cannot do
/// itself.
public enum TaskEntryEffect: Equatable, Sendable {
  /// The key was used and nothing else needs doing.
  case handled
  /// Not the slot's key; let it go on.
  case ignored
  /// Return: file the task with whatever the slots hold.
  case submit
  /// Esc: as it does in the text.
  case cancel
  /// ↓ in the date slot: the calendar, with the keyboard in it.
  case openCalendar
  /// ↓ or Space in the conditions slot: the conditions finder.
  case openConditions
}

/// The three values the add field's slots hold for a task not yet made, and
/// which of them — or the title — has the keyboard. Applied when the task is
/// created, in the same undo step.
public struct TaskEntryDraft: Equatable, Sendable {
  public var focus: TaskEntryFocus
  /// The day it is due, at its start.
  public var dueDate: Date?
  /// The conditions it needs, in the editor's groups: all of the groups,
  /// any condition within one.
  public var requirementGroups: [[String]]
  public var estimateMinutes: Int?
  /// Whether the last key in the estimate slot was a digit, so the next one
  /// carries on the number rather than starting a new one.
  public var isTypingEstimate: Bool

  public init(
    focus: TaskEntryFocus = .text, dueDate: Date? = nil, requirementGroups: [[String]] = [],
    estimateMinutes: Int? = nil, isTypingEstimate: Bool = false
  ) {
    self.focus = focus
    self.dueDate = dueDate
    self.requirementGroups = requirementGroups
    self.estimateMinutes = estimateMinutes
    self.isTypingEstimate = isTypingEstimate
  }

  public var estimateSeconds: Int? { estimateMinutes.map { $0 * 60 } }

  public var isEmpty: Bool {
    dueDate == nil && requirementGroups.isEmpty && estimateMinutes == nil
  }

  /// A key pressed while a slot has the keyboard, spelled as the catalogue
  /// spells keys (`up`, `shift+up`, `delete`, `7`). Keys in the text are the
  /// field's, so this ignores them.
  public mutating func handle(
    key: String, today: Date = .now, calendar: Calendar = .current
  ) -> TaskEntryEffect {
    guard focus.isSlot else { return .ignored }
    let wasTyping = isTypingEstimate
    isTypingEstimate = false
    switch key {
    case "right", "tab":
      focus = focus.next
      return .handled
    case "left", "shift+tab":
      focus = focus.previous
      return .handled
    case "enter":
      return .submit
    case "escape":
      return .cancel
    default:
      break
    }
    switch focus {
    case .text:
      return .ignored
    case .date:
      switch key {
      case "up":
        dueDate = TaskEntryDate.stepped(dueDate, byDays: 1, today: today, calendar: calendar)
      case "shift+up":
        dueDate = TaskEntryDate.stepped(dueDate, byDays: 7, today: today, calendar: calendar)
      case "down":
        return .openCalendar
      case "delete":
        dueDate = nil
      default:
        return .ignored
      }
      return .handled
    case .conditions:
      switch key {
      case "down", "space":
        return .openConditions
      case "delete":
        if !requirementGroups.isEmpty { requirementGroups.removeLast() }
        return .handled
      default:
        return .ignored
      }
    case .estimate:
      switch key {
      case "up":
        estimateMinutes = TaskEntryEstimate.stepped(estimateMinutes, by: 1)
      case "down":
        estimateMinutes = TaskEntryEstimate.stepped(estimateMinutes, by: -1)
      case "delete":
        estimateMinutes = nil
      default:
        guard key.count == 1, let digit = Int(key) else { return .ignored }
        estimateMinutes = TaskEntryEstimate.typing(digit, onto: estimateMinutes, continuing: wasTyping)
        isTypingEstimate = true
      }
      return .handled
    }
  }
}

/// The date slot's arithmetic and wording.
public enum TaskEntryDate {
  /// `days` on from `date`, at the start of that day. With no date yet the
  /// first step lands on today, and a week's step on a week from today.
  public static func stepped(
    _ date: Date?, byDays days: Int, today: Date = .now, calendar: Calendar = .current
  ) -> Date {
    let start = calendar.startOfDay(for: today)
    guard let date else {
      return days == 1 ? start : calendar.date(byAdding: .day, value: days, to: start) ?? start
    }
    let day = calendar.startOfDay(for: date)
    return calendar.date(byAdding: .day, value: days, to: day) ?? day
  }

  /// "Today", "Tomorrow", "Yesterday", or the day itself: "Fri 16 Oct".
  public static func label(_ date: Date, today: Date = .now, calendar: Calendar = .current) -> String {
    let start = calendar.startOfDay(for: today)
    let day = calendar.startOfDay(for: date)
    switch calendar.dateComponents([.day], from: start, to: day).day {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    default:
      var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
      style.calendar = calendar
      style.timeZone = calendar.timeZone
      return date.formatted(style)
    }
  }
}

/// The estimate slot's presets, stepping and typing.
public enum TaskEntryEstimate {
  /// What ↑ and ↓ step through, in minutes.
  public static let presets = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240, 360, 480]
  /// The most typing digits can make: a long day's work.
  public static let maximumMinutes = 999

  /// The next preset above (`by` > 0) or below the value, so a typed 20 goes
  /// to 30 or 15. ↑ with nothing starts at the first preset; ↓ from the
  /// first, or with nothing, leaves no estimate.
  public static func stepped(_ minutes: Int?, by offset: Int) -> Int? {
    guard offset != 0 else { return minutes }
    guard let minutes else { return offset > 0 ? presets.first : nil }
    if offset > 0 {
      let above = presets.filter { $0 > minutes }
      return above.isEmpty ? minutes : above[min(offset, above.count) - 1]
    }
    let below = presets.filter { $0 < minutes }
    return below.isEmpty ? nil : below[max(below.count + offset, 0)]
  }

  /// A digit typed into the slot: the minutes, carried on from the number
  /// already typed or starting afresh. Zero minutes is no estimate.
  public static func typing(_ digit: Int, onto minutes: Int?, continuing: Bool) -> Int? {
    let base = continuing ? (minutes ?? 0) : 0
    let next = min(base * 10 + digit, maximumMinutes)
    return next == 0 ? nil : next
  }

  /// "15m", "1h", "1.5h", "2h 10m".
  public static func label(_ minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes)m" }
    let hours = minutes / 60
    let rest = minutes % 60
    if rest == 0 { return "\(hours)h" }
    if rest == 30 { return "\(hours).5h" }
    return "\(hours)h \(rest)m"
  }
}

/// The calendar the date slot opens with ↓: one month of days, a cursor on
/// one of them that the arrows move, Return to take it.
public enum TaskEntryCalendar {
  /// The cursor moved by an arrow: a day across, a week up and down.
  public static func moved(
    _ day: Date, by key: String, calendar: Calendar = .current
  ) -> Date? {
    let days: Int
    switch key {
    case "left": days = -1
    case "right": days = 1
    case "up": days = -7
    case "down": days = 7
    case "pageup", "shift+up": return calendar.date(byAdding: .month, value: -1, to: day)
    case "pagedown", "shift+down": return calendar.date(byAdding: .month, value: 1, to: day)
    default: return nil
    }
    return calendar.date(byAdding: .day, value: days, to: day)
  }

  /// The month holding `day`, as rows of seven from the calendar's first
  /// weekday: nil for the cells before the first and after the last.
  public static func weeks(containing day: Date, calendar: Calendar = .current) -> [[Date?]] {
    guard let month = calendar.dateInterval(of: .month, for: day),
      let count = calendar.range(of: .day, in: .month, for: day)?.count
    else { return [] }
    let first = calendar.startOfDay(for: month.start)
    let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    var cells: [Date?] = Array(repeating: nil, count: lead)
    for offset in 0..<count {
      cells.append(calendar.date(byAdding: .day, value: offset, to: first))
    }
    while cells.count % 7 != 0 { cells.append(nil) }
    return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
  }
}
