import Foundation
import TaktCore

/// Time span shown by the Daily view's completion chart.
///
/// The range changes the *bucket*, never the mark: 30 and 90 days are one bar
/// per day, a year is one bar per week. Switching to a line for the long range
/// would interpolate between buckets, and a slope drawn through a day nothing
/// happened on is a claim the data doesn't support.
enum DailyChartRange: Int, CaseIterable, Identifiable {
  case thirtyDays
  case ninetyDays
  case year

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .thirtyDays: return "30d"
    case .ninetyDays: return "90d"
    case .year: return "1y"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .thirtyDays: return "Last 30 days"
    case .ninetyDays: return "Last 90 days"
    case .year: return "Last year, by week"
    }
  }

  /// Number of buckets drawn. 52 weekly bars for the year keeps each bar wide
  /// enough to read; 365 daily bars in a popover would be under two points each.
  var bucketCount: Int {
    switch self {
    case .thirtyDays: return 30
    case .ninetyDays: return 90
    case .year: return 52
    }
  }

  var isWeekly: Bool { self == .year }

  var bucketNoun: String { isWeekly ? "week" : "day" }
}
