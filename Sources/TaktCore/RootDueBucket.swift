import Foundation

public enum RootDueBucket: Int, CaseIterable {
  case overdue
  case asap
  case today
  case tomorrow
  case nextSevenDays
  case future
  case noDueDate

  public var title: String {
    switch self {
    case .overdue: return "Overdue"
    case .asap: return "ASAP"
    case .today: return "Today"
    case .tomorrow: return "Tomorrow"
    case .nextSevenDays: return "Next 7 days"
    case .future: return "Further in the future"
    case .noDueDate: return "No due date"
    }
  }
}
