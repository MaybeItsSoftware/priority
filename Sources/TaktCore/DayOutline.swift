import Foundation

/// One row of Today drawn as an outline: a task of the day, or an open
/// subtask shown beneath one, as Checkvist unfolds a branch where it stands.
public struct DayOutlineRow: Equatable, Sendable {
  public let id: String
  /// Steps in from the day's own rows; zero for a task of the day.
  public let depth: Int
  /// The row it is drawn beneath; nil at the top of the day.
  public let parentID: String?
  /// Whether it has open subtasks to show.
  public let hasChildren: Bool
  /// Whether they are showing.
  public let isUnfolded: Bool

  public init(id: String, depth: Int, parentID: String?, hasChildren: Bool, isUnfolded: Bool) {
    self.id = id
    self.depth = depth
    self.parentID = parentID
    self.hasChildren = hasChildren
    self.isUnfolded = isUnfolded
  }
}

/// Today's tasks with the branches you have unfolded, as rows.
///
/// The day is flat until you open a task: then its open subtasks follow it,
/// one step in, in outline order, whether or not they are on today
/// themselves. A subtask that is also on today is drawn once — beneath its
/// parent, while the parent is open — so the cursor never walks it twice.
public enum DayOutline {
  /// - Parameters:
  ///   - day: the day's tasks, in the order the day reads.
  ///   - unfolded: the tasks whose subtasks are showing.
  ///   - children: a task's open subtasks, in outline order.
  public static func rows(
    day: [String], unfolded: Set<String>, children: (String) -> [String]
  ) -> [DayOutlineRow] {
    // Everything drawn beneath an open branch somewhere, so it is not drawn
    // at the top of the day as well. Whatever claims a task of the day is
    // itself drawn — at the top, or beneath something that is — because a
    // tree has no cycles, so the claim always lands on a row.
    var claimed = Set<String>()
    var scanned = Set<String>()
    func claim(_ id: String) {
      guard unfolded.contains(id), scanned.insert(id).inserted else { return }
      for child in children(id) {
        claimed.insert(child)
        claim(child)
      }
    }
    day.forEach(claim)

    var rows: [DayOutlineRow] = []
    var drawn = Set<String>()
    func draw(_ id: String, depth: Int, parent: String?) {
      guard drawn.insert(id).inserted else { return }
      let kids = children(id)
      let isOpen = !kids.isEmpty && unfolded.contains(id)
      rows.append(
        DayOutlineRow(id: id, depth: depth, parentID: parent, hasChildren: !kids.isEmpty, isUnfolded: isOpen))
      guard isOpen else { return }
      for kid in kids { draw(kid, depth: depth + 1, parent: id) }
    }
    for id in day where !claimed.contains(id) { draw(id, depth: 0, parent: nil) }
    return rows
  }

  /// What → (or `l`) does on a row.
  public enum Step: Equatable, Sendable {
    /// Show the row's subtasks.
    case unfold(String)
    /// Hide them.
    case fold(String)
    /// Put the cursor on another row.
    case select(String)
    /// Nothing in the day: → goes on to the inspector, ← to the sidebar.
    case leave
  }

  /// →: open a folded branch, then step into it. A row with nothing beneath
  /// it has nowhere further right to go in the day.
  public static func right(from id: String, in rows: [DayOutlineRow]) -> Step {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return .leave }
    let row = rows[index]
    guard row.hasChildren else { return .leave }
    guard row.isUnfolded else { return .unfold(id) }
    let next = rows.index(after: index)
    guard next < rows.endIndex, rows[next].parentID == id else { return .leave }
    return .select(rows[next].id)
  }

  /// ←: fold an open branch, then step up to the row it hangs from, and at
  /// the top of the day leave.
  public static func left(from id: String, in rows: [DayOutlineRow]) -> Step {
    guard let row = rows.first(where: { $0.id == id }) else { return .leave }
    if row.isUnfolded { return .fold(id) }
    if let parent = row.parentID { return .select(parent) }
    return .leave
  }

  /// Whether `id` is drawn somewhere beneath `ancestor`.
  public static func isDrawn(_ id: String, beneath ancestor: String, in rows: [DayOutlineRow]) -> Bool {
    let parents = Dictionary(rows.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
    var current = parents[id] ?? nil
    var visited = Set<String>()
    while let parent = current, visited.insert(parent).inserted {
      if parent == ancestor { return true }
      current = parents[parent] ?? nil
    }
    return false
  }

  /// Where the cursor goes when its row leaves the day — ticked off, say:
  /// the next subtask of the same parent, else the one before, else the
  /// parent, as everywhere else (`SelectionSuccessor`). Nil when the row is
  /// still drawn or nothing is left.
  public static func successor(
    of id: String, previous: [DayOutlineRow], remaining: [String]
  ) -> String? {
    let parents = Dictionary(previous.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
    return SelectionSuccessor.successor(
      of: id, previousOrder: previous.map(\.id), remaining: Set(remaining),
      parentOf: { parents[$0] ?? nil })
  }
}
