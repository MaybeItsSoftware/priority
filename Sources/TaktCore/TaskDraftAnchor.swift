import Foundation

/// Where an open new-task draft row is drawn: beside a task, inside it, or at
/// the foot of the pane (or board column).
public enum TaskDraftAnchor: Equatable, Sendable {
  case below(String)
  case above(String)
  /// Inside the task: drawn straight after its row, one step further in.
  case inside(String)
  case end

  public var referenceID: String? {
    switch self {
    case let .below(id), let .above(id), let .inside(id): id
    case .end: nil
    }
  }
}

/// A row the draft could sit beside, as drawn: its id and, where the pane is
/// a tree, its parent's. Flat panes (a board column, the matrix) leave the
/// parent nil, which makes every row a sibling of every other.
public struct TaskDraftRow: Equatable, Sendable {
  public let id: String
  public let parentID: String?

  public init(id: String, parentID: String? = nil) {
    self.id = id
    self.parentID = parentID
  }
}

/// Keeps a draft row on screen when the task it was drawn beside leaves.
///
/// The draft is drawn only next to its reference task, so when that task
/// goes — a completion's linger runs out, another client deletes it, a
/// refresh files it elsewhere — the row, and what was typed in it, went with
/// it. This finds the gap the row sat in and the nearest task still drawn
/// beside that gap, keeping the new task at the same level where it can:
///
/// 1. the nearest surviving sibling before the gap, drafted below it;
/// 2. else the nearest surviving sibling after the gap, drafted above it
///    (for a draft inside the task, its own children count first, then its
///    siblings);
/// 3. else the reference's parent, if it is still drawn, drafted inside it;
/// 4. else any row before the gap (below), then any after it (above);
/// 5. else the foot of the pane.
public enum TaskDraftReanchor {
  /// The anchor to draw the draft at once `previous` has become `current`.
  ///
  /// An anchor whose task is still drawn is kept as it is, and so is one
  /// whose task was not drawn before either: that row was never on screen
  /// beside it, so there is no position to keep.
  public static func anchor(
    _ anchor: TaskDraftAnchor, previous: [TaskDraftRow], current: [TaskDraftRow]
  ) -> TaskDraftAnchor {
    guard let referenceID = anchor.referenceID else { return .end }
    let surviving = Set(current.map(\.id))
    guard !surviving.contains(referenceID),
      let index = previous.firstIndex(where: { $0.id == referenceID })
    else { return anchor }
    let reference = previous[index]
    // The row sat in the gap before `gap`: in front of the reference when
    // above it, straight after it otherwise.
    let gap: Int = if case .above = anchor { index } else { index + 1 }
    let before = previous[..<gap].reversed().filter { $0.id != referenceID && surviving.contains($0.id) }
    let after = previous[gap...].filter { $0.id != referenceID && surviving.contains($0.id) }
    // The level the new task was to be filed at: under the reference when
    // it was going inside it, beside it otherwise. Inside a task that has
    // gone, its children still drawn keep that level; failing them, the
    // reference's own level is the next best.
    var levels = [reference.parentID]
    if case .inside = anchor { levels.insert(referenceID, at: 0) }
    for parentID in levels {
      if let row = before.first(where: { $0.parentID == parentID }) { return .below(row.id) }
      if let row = after.first(where: { $0.parentID == parentID }) { return .above(row.id) }
    }
    if let parentID = reference.parentID, surviving.contains(parentID) { return .inside(parentID) }
    if let row = before.first { return .below(row.id) }
    if let row = after.first { return .above(row.id) }
    return .end
  }
}
