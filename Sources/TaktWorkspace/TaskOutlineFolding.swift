import Foundation
import TaktCore

/// Folding a depth-first outline, the way Checkvist folds a branch: a folded
/// task stays on screen and everything beneath it goes, so a subtree can be
/// walked or put away without opening the task as a scope of its own.
///
/// Pure over `TaskOutlineItem`s, so the outline pane and the subtask rows on a
/// board card fold by the same rule and the arrow keys walk exactly the rows
/// that are drawn.
public enum TaskOutlineFolding {
  /// The rows still drawn once every folded task's descendants are removed. A
  /// fold beneath a folded task changes nothing until its ancestor opens.
  public static func visible(_ items: [TaskOutlineItem], folded: Set<String>) -> [TaskOutlineItem] {
    guard !folded.isEmpty else { return items }
    return visible(items, closing: folded.contains)
  }

  /// The rows still drawn once the descendants of every row `closes` answers
  /// true for are removed: a fold, or — on a board card — a subtask that is a
  /// card of its own in another column, whose subtree that card draws.
  public static func visible(_ items: [TaskOutlineItem], closing closes: (String) -> Bool) -> [TaskOutlineItem] {
    var hiddenBelow: Int?
    return items.filter { item in
      if let depth = hiddenBelow {
        if item.depth > depth { return false }
        hiddenBelow = nil
      }
      if closes(item.id) { hiddenBelow = item.depth }
      return true
    }
  }

  /// Every row with something beneath it: the ones that get a disclosure.
  /// Read from the outline as drawn before folding, so a folded task still
  /// knows it has children.
  public static func parentIDs(_ items: [TaskOutlineItem]) -> Set<String> {
    var result = Set<String>()
    for (item, next) in zip(items, items.dropFirst()) where next.depth > item.depth {
      result.insert(item.id)
    }
    return result
  }

  /// The row a row hangs from: the nearest earlier row one level up. `nil`
  /// for a row at the top of the outline, or one that is not in it.
  public static func parentID(of id: String, in items: [TaskOutlineItem]) -> String? {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
    let depth = items[index].depth
    return items[..<index].last(where: { $0.depth < depth })?.id
  }

  /// The first row beneath a row, if it has one.
  public static func firstChildID(of id: String, in items: [TaskOutlineItem]) -> String? {
    guard let index = items.firstIndex(where: { $0.id == id }), index + 1 < items.count,
      items[index + 1].depth > items[index].depth
    else { return nil }
    return items[index + 1].id
  }

  /// The rows as drawn, in the shape Today's tree is walked in, so ← and →
  /// mean the same on a list's outline as on the day — open a branch, step
  /// in, fold it, step out — by the one rule (`DayOutline.right`/`left`).
  ///
  /// - Parameters:
  ///   - visible: the rows drawn, folds already applied.
  ///   - parents: the rows with something beneath them, folded or not.
  ///   - folded: the rows whose branch is put away.
  public static func dayOutlineRows(
    _ visible: [TaskOutlineItem], parents: Set<String>, folded: Set<String>
  ) -> [DayOutlineRow] {
    var ancestors: [TaskOutlineItem] = []
    return visible.map { item in
      while let last = ancestors.last, last.depth >= item.depth { ancestors.removeLast() }
      let parentID = ancestors.last?.id
      ancestors.append(item)
      let hasChildren = parents.contains(item.id)
      return DayOutlineRow(
        id: item.id, depth: item.depth, parentID: parentID, hasChildren: hasChildren,
        isUnfolded: hasChildren && !folded.contains(item.id))
    }
  }

  /// Every row beneath a row, at any depth.
  public static func descendantIDs(of id: String, in items: [TaskOutlineItem]) -> [String] {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
    let depth = items[index].depth
    return items[(index + 1)...].prefix(while: { $0.depth > depth }).map(\.id)
  }
}
