import Foundation

/// Arranging the day by hand: where the planned tasks go when one of them is
/// moved up or down.
///
/// Only the planned rows take part. A derived row — overdue, due today,
/// starting today — is in the day because of a date, and its place follows
/// from that date, so moving it would be arranging something the next read
/// puts back.
public enum DayArrangement {
  /// The planned order with `taskID` moved `offset` places, clamped at the
  /// ends. `nil` when the task is not in the order or cannot move that way,
  /// so a caller has nothing to write.
  public static func moving(
    _ taskID: String,
    by offset: Int,
    in order: [String]
  ) -> [String]? {
    guard offset != 0, let index = order.firstIndex(of: taskID) else { return nil }
    let target = min(max(index + offset, 0), order.count - 1)
    guard target != index else { return nil }
    var arranged = order
    arranged.remove(at: index)
    arranged.insert(taskID, at: target)
    return arranged
  }

  /// `plan` with its planned entries put in `order`, everything else where it
  /// was. Lets the day show a move straight away rather than a ranking later,
  /// which is what keeps a second ⌥↓ pressed quickly moving the same task on
  /// from where the first left it.
  public static func applying(_ order: [String], to plan: [DayPlanEntry]) -> [DayPlanEntry] {
    var remaining = order.makeIterator()
    return plan.map { entry in
      guard entry.reason == .planned, let next = remaining.next() else { return entry }
      return DayPlanEntry(id: next, reason: .planned)
    }
  }
}
