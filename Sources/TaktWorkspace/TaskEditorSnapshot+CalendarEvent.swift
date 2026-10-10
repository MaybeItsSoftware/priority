import Foundation
import TaktCore

/// When a calendar event made from a task should sit.
///
/// Both ways into Google Calendar — the inspector's "Add to Google Calendar"
/// and the Google Calendar settings page's "Create event from selected task" —
/// read the task's dates through this, so an event lands in the same place
/// whichever button made it.
public struct CalendarEventTiming: Equatable, Sendable {
  /// The event's start, or nil to let the calendar start it now.
  public let date: Date?
  public let isAllDay: Bool

  public init(date: Date?, isAllDay: Bool) {
    self.date = date
    self.isAllDay = isAllDay
  }
}

extension TaskEditorSnapshot {
  /// An exact due time is a timed event; a due day with no time is an
  /// all-day event on that day; failing both, a start time is a timed event
  /// then. A task with none of them gets an undated event.
  public func calendarEventTiming(calendar: Calendar = .current) -> CalendarEventTiming {
    if let dueAt {
      return CalendarEventTiming(date: dueAt, isAllDay: false)
    }
    if let dueDay = planning?.dueDate.flatMap({ TaskCalendarDate.date($0, calendar: calendar) }) {
      return CalendarEventTiming(date: dueDay, isAllDay: true)
    }
    if let start = planning?.startAt {
      return CalendarEventTiming(date: start, isAllDay: false)
    }
    return CalendarEventTiming(date: nil, isAllDay: false)
  }
}
