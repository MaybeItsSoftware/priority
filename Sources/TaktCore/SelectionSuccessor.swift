import Foundation

/// Where the selection goes when the row it was on leaves the pane — a task
/// ticked off whose three seconds are up, with completed tasks hidden.
///
/// The row that took its place: the next task under the same parent, else the
/// one before it, else the parent itself. Only when none of those is still on
/// screen does it fall back to whatever row now sits after the old one, or
/// before it. Losing the selection instead left the arrow keys starting again
/// from the top of the pane.
public enum SelectionSuccessor {
  /// - Parameters:
  ///   - id: the row that left.
  ///   - previousOrder: the rows as they were drawn, `id` among them.
  ///   - remaining: the rows on screen now.
  ///   - parentOf: each row's parent task, nil at the top level.
  /// - Returns: nil when `id` is still on screen, was never drawn, or nothing
  ///   is left to select.
  public static func successor(
    of id: String,
    previousOrder: [String],
    remaining: Set<String>,
    parentOf: (String) -> String?
  ) -> String? {
    guard !remaining.contains(id), let index = previousOrder.firstIndex(of: id) else { return nil }
    let parent = parentOf(id)
    let after = previousOrder[(index + 1)...].filter(remaining.contains)
    let before = previousOrder[..<index].filter(remaining.contains)
    if let next = after.first(where: { parentOf($0) == parent }) { return next }
    if let previous = before.last(where: { parentOf($0) == parent }) { return previous }
    if let parent, remaining.contains(parent) { return parent }
    return after.first ?? before.last
  }
}
