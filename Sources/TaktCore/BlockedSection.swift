import TaktRustCore

/// Where the "Blocked" label goes in a list of tasks.
///
/// Blocked tasks sink below their open siblings (the core's ordering), so
/// each group of siblings — an outline parent's children, a board column's
/// cards — ends with its blocked ones. A quiet label above the first of them
/// says what they are, once per group, rather than leaving the greying to say
/// it alone.
///
/// The rule is the Rust core's (`core/src/shaping.rs`), shared with Android;
/// this keeps the generic signature, numbering the groups before they cross.
public enum BlockedSection {
  /// The ids to draw the label above: in each group, the first of the run of
  /// blocked tasks the group ends with. A blocked task with an unblocked one
  /// after it in its group — a stale read, say — is greyed but not labelled,
  /// since a label there would head a section that is not all blocked.
  ///
  /// - Parameters:
  ///   - items: the rows in drawing order, each with the group it belongs to.
  ///     A group's rows need not be contiguous: an outline draws a sibling's
  ///     subtasks between it and the next sibling.
  ///   - blocked: the ids drawn as blocked.
  public static func labelledIDs<Group: Hashable>(
    _ items: [(id: String, group: Group)], blocked: Set<String>
  ) -> Set<String> {
    guard !blocked.isEmpty else { return [] }
    var numbers: [Group: UInt32] = [:]
    var groups: [UInt32] = []
    groups.reserveCapacity(items.count)
    for item in items {
      if let number = numbers[item.group] {
        groups.append(number)
      } else {
        let number = UInt32(numbers.count)
        numbers[item.group] = number
        groups.append(number)
      }
    }
    let labelled = blockedSectionLabels(groups: groups, blocked: items.map { blocked.contains($0.id) })
    return Set(labelled.map { items[Int($0)].id })
  }
}
