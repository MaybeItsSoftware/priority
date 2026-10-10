import Foundation
import TaktRustCore

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
  /// The Rust core's `progress::task_progress_interval`.
  public static func interval(
    for period: TaskProgressPeriod, now: Date = .now, calendar: Calendar = .current
  ) -> DateInterval {
    let span = taskProgressInterval(
      days: UInt32(period.days), nowMs: now.rankingMilliseconds, zone: calendar.timeZone.identifier)
    return DateInterval(start: Date(rankingMilliseconds: span.startMs), end: Date(rankingMilliseconds: span.endMs))
  }

  /// Buckets completion and creation times into the period's days. Times
  /// outside the period are ignored rather than clamped onto its ends.
  /// The Rust core's `progress::task_progress_days`.
  public static func build(
    period: TaskProgressPeriod,
    completions: [Date],
    creations: [Date],
    now: Date = .now,
    calendar: Calendar = .current
  ) -> TaskProgressSeries {
    let days = taskProgressDays(
      days: UInt32(period.days), completionsMs: completions.map(\.rankingMilliseconds),
      creationsMs: creations.map(\.rankingMilliseconds), nowMs: now.rankingMilliseconds,
      zone: calendar.timeZone.identifier)
    return TaskProgressSeries(days: days.map {
      TaskProgressDay(
        dayStart: Date(rankingMilliseconds: $0.dayStartMs), completed: Int($0.completed), added: Int($0.added),
        cumulativeCompleted: Int($0.cumulativeCompleted))
    })
  }
}
