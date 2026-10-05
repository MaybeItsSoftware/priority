import Foundation

public enum RootTaskView: Int, CaseIterable, Sendable {
  case all
  case due
  case tags
  case priority
  case kanban
  case eisenhower
  // Appended rather than slotted in: the raw values are persisted in
  // preferences and in the saved tab order, so renumbering the existing cases
  // would silently move everyone's stored root view.
  case daily

  public var title: String {
    switch self {
    case .all: return "All"
    case .due: return "Due"
    case .tags: return "Tags"
    case .priority: return "Priority"
    case .kanban: return "Kanban"
    case .eisenhower: return "Matrix"
    case .daily: return "Daily"
    }
  }
}
