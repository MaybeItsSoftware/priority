import Foundation

// MARK: - KanbanColumnCondition

public enum KanbanColumnCondition: Codable, Hashable {
  /// Task has this tag in its content (without the # prefix).
  case tag(String)
  /// Task falls in this due bucket (stored as RootDueBucket.rawValue).
  case dueBucket(Int)
  /// Catch-all: matches any task not already claimed by an earlier column.
  case catchAll
  /// Task sits in this Eisenhower quadrant (stored as `MatrixQuadrant.rawValue`).
  ///
  /// The join between the two views. A board defined by quadrant is fed by the
  /// matrix, which is why placing tasks there stopped being busywork.
  case matrixQuadrant(String)
  /// Task has a priority rank at or above `rank` — `1` is the top, so
  /// `priorityAtLeast(3)` claims P1, P2 and P3.
  case priorityAtLeast(Int)
  /// Task has no children. The board draws a card per matching task at every
  /// depth, so a six-level tree puts a parent and its whole subtree on the
  /// board as peers; this is how you get only the things you actually do.
  case leafOnly
  /// Task has no coordinate on the matrix yet — the board's own inbox.
  case unplacedOnMatrix

  public var displayTitle: String {
    switch self {
    case .tag(let name): return "#\(name)"
    case .dueBucket(let raw):
      return RootDueBucket(rawValue: raw)?.title ?? "Due bucket \(raw)"
    case .catchAll: return "Everything else"
    case .matrixQuadrant(let raw):
      return MatrixQuadrant(rawValue: raw)?.title ?? "Quadrant \(raw)"
    case .priorityAtLeast(let rank): return "P\(rank) or higher"
    case .leafOnly: return "Has no subtasks"
    case .unplacedOnMatrix: return "Not on the matrix"
    }
  }

  /// Whether moving a task into this condition is actionable (can set a due date or tag).
  public var isWritable: Bool {
    switch self {
    case .tag: return true
    case .dueBucket(let raw):
      guard let bucket = RootDueBucket(rawValue: raw) else { return false }
      switch bucket {
      case .today, .tomorrow, .nextSevenDays, .noDueDate: return true
      default: return false
      }
    case .catchAll: return true
    // Dropping a card into a quadrant column places it on the matrix, which is
    // the same write the matrix view's drop does — one axis, two surfaces.
    case .matrixQuadrant: return true
    // A rank is per-parent bookkeeping the board cannot infer a value for, and
    // "has no subtasks" and "not on the matrix" describe a task rather than
    // ask something of it. A column of only these accepts no drops.
    case .priorityAtLeast, .leafOnly, .unplacedOnMatrix: return false
    }
  }
}

// MARK: - KanbanSortOrder

public enum KanbanSortOrder: String, Codable, CaseIterable, Identifiable {
  case position
  case dueAscending
  case dueDescending
  case priorityAscending
  case priorityThenDueAscending
  case alphabetical

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .position: return "Default order"
    case .dueAscending: return "Due date (earliest first)"
    case .dueDescending: return "Due date (latest first)"
    case .priorityAscending: return "Priority (highest first)"
    case .priorityThenDueAscending: return "Priority, then due date"
    case .alphabetical: return "Alphabetical"
    }
  }
}

// MARK: - KanbanColumn

public struct KanbanColumn: Identifiable, Codable {
  public var id: UUID
  public var name: String
  /// A task matches this column if it satisfies ANY of these conditions (OR logic).
  /// Columns are evaluated in order; a task belongs to the first column it matches.
  public var conditions: [KanbanColumnCondition]
  public var sortOrder: KanbanSortOrder
  /// How many cards this column should hold before it is overloaded. `nil` is
  /// no limit, which is what every previously-saved column decodes as.
  ///
  /// Advisory: going over is shown, never prevented. A board that refuses a
  /// drop because a number says so is a board people stop using.
  public var wipLimit: Int?

  public init(
    id: UUID = UUID(),
    name: String,
    conditions: [KanbanColumnCondition],
    sortOrder: KanbanSortOrder = .position,
    wipLimit: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.conditions = conditions
    self.sortOrder = sortOrder
    self.wipLimit = wipLimit
  }

  /// How a column's load reads against its limit.
  public enum Load: Equatable {
    case unlimited
    case within
    case atLimit
    case over(by: Int)
  }

  public func load(count: Int) -> Load {
    guard let wipLimit, wipLimit > 0 else { return .unlimited }
    if count > wipLimit { return .over(by: count - wipLimit) }
    if count == wipLimit { return .atLimit }
    return .within
  }

  // Stored in evaluation order (specific first, catch-all last).
  // The board displays them reversed so Today is on the right.
  public static var defaults: [KanbanColumn] {
    [
      KanbanColumn(
        name: "Today",
        conditions: [
          .dueBucket(RootDueBucket.asap.rawValue),
          .dueBucket(RootDueBucket.overdue.rawValue),
          .dueBucket(RootDueBucket.today.rawValue),
        ],
        sortOrder: .priorityThenDueAscending
      ),
      KanbanColumn(
        name: "Next 7 Days",
        conditions: [
          .dueBucket(RootDueBucket.tomorrow.rawValue),
          .dueBucket(RootDueBucket.nextSevenDays.rawValue),
        ],
        sortOrder: .priorityThenDueAscending
      ),
      KanbanColumn(
        name: "Waiting On",
        conditions: [.tag("waiting")],
        sortOrder: .priorityThenDueAscending
      ),
      KanbanColumn(
        name: "Backlog",
        conditions: [.tag("backlog")],
        sortOrder: .priorityThenDueAscending
      ),
      // Last, so it takes only what the columns above declined.
      //
      // Without it a new board is four empty columns for anyone who has not
      // yet set a due date or a tag — which is most people on day one, and is
      // exactly how a board teaches you it is broken rather than empty.
      KanbanColumn(
        name: "Unsorted",
        conditions: [.catchAll],
        sortOrder: .priorityThenDueAscending
      ),
    ]
  }
}
