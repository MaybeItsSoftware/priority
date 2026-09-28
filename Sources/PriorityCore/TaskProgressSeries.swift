import Foundation

/// How far back the progress graph looks.
public enum TaskProgressPeriod: String, CaseIterable, Sendable, Identifiable {
  case week
  case month
  case quarter

  public var id: String { rawValue }

  /// Days on the graph, today included.
  public var days: Int {
    switch self {
    case .week: 7
    case .month: 30
    case .quarter: 90
    }
  }

  /// The label on the period switch.
  public var shortTitle: String {
    switch self {
    case .week: "7D"
    case .month: "30D"
    case .quarter: "90D"
    }
  }
}

/// One day on the progress graph.
public struct TaskProgressDay: Identifiable, Equatable, Sendable {
  public let dayStart: Date
  /// Tasks closed that day.
  public let completed: Int
  /// Tasks added that day.
  public let added: Int
  /// Tasks closed from the first day of the period to the end of this one.
  public let cumulativeCompleted: Int

  public var id: Date { dayStart }

  public init(dayStart: Date, completed: Int, added: Int, cumulativeCompleted: Int) {
    self.dayStart = dayStart
    self.completed = completed
    self.added = added
    self.cumulativeCompleted = cumulativeCompleted
  }
}

/// Task progress over a period, a day at a time: what was closed and what was
/// added, so the graph can say whether the work is being got through or is
/// growing faster than it goes.
///
/// Every day of the period is present, empty ones included. A day with
/// nothing done is part of the picture; left out, the line would join the
/// days either side of it and draw progress that did not happen.
public struct TaskProgressSeries: Equatable, Sendable {
  public let days: [TaskProgressDay]

  public var totalCompleted: Int { days.reduce(0) { $0 + $1.completed } }
  public var totalAdded: Int { days.reduce(0) { $0 + $1.added } }
  /// Positive when more was closed than added.
  public var net: Int { totalCompleted - totalAdded }
  public var bestDay: TaskProgressDay? {
    days.max { $0.completed < $1.completed }.flatMap { $0.completed > 0 ? $0 : nil }
  }

  public init(days: [TaskProgressDay]) {
    self.days = days
  }

  /// The interval the period covers: from the start of its first day to the
  /// end of today, half open, so it can be handed straight to a query.
  public static func interval(
    for period: TaskProgressPeriod, now: Date = .now, calendar: Calendar = .current
  ) -> DateInterval {
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -(period.days - 1), to: today) ?? today
    let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
    return DateInterval(start: start, end: end)
  }

  /// Buckets completion and creation times into the period's days. Times
  /// outside the period are ignored rather than clamped onto its ends.
  public static func build(
    period: TaskProgressPeriod,
    completions: [Date],
    creations: [Date],
    now: Date = .now,
    calendar: Calendar = .current
  ) -> TaskProgressSeries {
    let interval = interval(for: period, now: now, calendar: calendar)
    func counts(_ dates: [Date]) -> [Date: Int] {
      dates.filter { $0 >= interval.start && $0 < interval.end }
        .reduce(into: [:]) { $0[calendar.startOfDay(for: $1), default: 0] += 1 }
    }
    let done = counts(completions)
    let added = counts(creations)
    var running = 0
    var days: [TaskProgressDay] = []
    var day = interval.start
    while day < interval.end {
      let completed = done[day, default: 0]
      running += completed
      days.append(TaskProgressDay(
        dayStart: day, completed: completed, added: added[day, default: 0], cumulativeCompleted: running))
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return TaskProgressSeries(days: days)
  }
}
