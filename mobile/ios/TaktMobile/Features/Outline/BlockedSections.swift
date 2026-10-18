import Foundation
import TaktCore

/// Where the "Blocked" label goes on the phone's outline and board. Blocked
/// tasks sink below their open siblings (the core's ordering), so each group
/// — an outline parent's children, a board column's cards — ends with them;
/// the label heads that run once. The rule itself is TaktCore's
/// `BlockedSection`, the one the Mac draws by.
enum BlockedSections {
  /// The outline rows to draw the label above: in each sibling group, the
  /// first of the blocked run it ends with.
  static func outlineLabels(rows: [OutlineRow], blocked: Set<String>) -> Set<String> {
    outlineLabels(rows: rows, blocked: blocked, buried: []).blocked
  }

  /// The outline rows to draw the "Blocked" and "Buried" labels above:
  /// siblings run open, then blocked, then buried (the core's order), and
  /// each run's first row carries its label. A task that is both is buried.
  static func outlineLabels(
    rows: [OutlineRow], blocked: Set<String>, buried: Set<String>
  ) -> (blocked: Set<String>, buried: Set<String>) {
    guard !blocked.isEmpty || !buried.isEmpty else { return ([], []) }
    let open = rows.lazy.filter { $0.status == .open }
    return BlockedSection.labelledIDs(
      rows.map { (id: $0.id, group: "\($0.listID)/\($0.parentID ?? "")") },
      blocked: Set(open.filter { blocked.contains($0.id) }.map(\.id)),
      buried: Set(open.filter { buried.contains($0.id) }.map(\.id)))
  }

  /// The card in a column to draw the label above, if the column ends with
  /// blocked cards.
  static func boardLabel(cards: [BoardCard], blocked: Set<String>) -> String? {
    guard !blocked.isEmpty else { return nil }
    return BlockedSection.labelledIDs(
      cards.map { (id: $0.id, group: 0) },
      blocked: Set(cards.lazy.filter { $0.status == .open && blocked.contains($0.id) }.map(\.id))
    ).first
  }
}

/// One line of the drawn outline: a task row, or the label over a group's
/// blocked tail. The label is its own entry rather than part of the row it
/// heads, so the row's selection, swipes and drag stay the row's alone.
enum OutlineEntry: Identifiable, Equatable {
  case row(OutlineRow)
  /// The label above the row with this id.
  case blockedLabel(before: String, depth: Int, isBuried: Bool = false)

  var id: String {
    switch self {
    case .row(let row): row.id
    case .blockedLabel(let rowID, _, let isBuried): "\(isBuried ? "buried" : "blocked")-label.\(rowID)"
    }
  }

  /// The rows, with a label entry before each one that starts a blocked run.
  static func entries(rows: [OutlineRow], blocked: Set<String>, buried: Set<String> = []) -> [OutlineEntry] {
    let labelled = BlockedSections.outlineLabels(rows: rows, blocked: blocked, buried: buried)
    guard !labelled.blocked.isEmpty || !labelled.buried.isEmpty else { return rows.map(OutlineEntry.row) }
    var entries: [OutlineEntry] = []
    entries.reserveCapacity(rows.count + labelled.blocked.count + labelled.buried.count)
    for row in rows {
      if labelled.blocked.contains(row.id) { entries.append(.blockedLabel(before: row.id, depth: row.depth)) }
      if labelled.buried.contains(row.id) {
        entries.append(.blockedLabel(before: row.id, depth: row.depth, isBuried: true))
      }
      entries.append(.row(row))
    }
    return entries
  }

  /// A drag's offsets in the entries turned into offsets in the rows: the
  /// labels are not rows, so each counts for nothing. Nil when the drag
  /// started on a label, which cannot move.
  static func rowMove(
    in entries: [OutlineEntry], source: IndexSet, destination: Int
  ) -> (source: IndexSet, destination: Int)? {
    func rowsBefore(_ offset: Int) -> Int {
      entries.prefix(offset).reduce(0) { count, entry in
        if case .row = entry { return count + 1 }
        return count
      }
    }
    var rowSource = IndexSet()
    for offset in source {
      guard entries.indices.contains(offset), case .row = entries[offset] else { return nil }
      rowSource.insert(rowsBefore(offset))
    }
    guard !rowSource.isEmpty else { return nil }
    return (rowSource, rowsBefore(destination))
  }
}
