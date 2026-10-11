import Foundation
import TaktRustCore

/// Arranging the day by hand: where the planned tasks go when one of them is
/// moved up or down.
///
/// Only the planned rows take part. A derived row — overdue, due today,
/// starting today — is in the day because of a date, and its place follows
/// from that date, so moving it would be arranging something the next read
/// puts back. The rule is the Rust core's (`core/src/shaping.rs`), shared
/// with Android.
public enum DayArrangement {
  /// The planned order with `taskID` moved `offset` places, clamped at the
  /// ends. `nil` when the task is not in the order or cannot move that way,
  /// so a caller has nothing to write.
  public static func moving(
    _ taskID: String,
    by offset: Int,
    in order: [String]
  ) -> [String]? {
    dayArrangementMoving(taskId: taskID, offset: Int64(offset), order: order)
  }

  /// `plan` with its planned entries put in `order`, everything else where it
  /// was. Lets the day show a move straight away rather than a ranking later,
  /// which is what keeps a second ⌥↓ pressed quickly moving the same task on
  /// from where the first left it.
  public static func applying(_ order: [String], to plan: [DayPlanEntry]) -> [DayPlanEntry] {
    let ids = dayArrangementApplying(
      order: order, ids: plan.map(\.id), planned: plan.map { $0.reason == .planned })
    return zip(plan, ids).map { entry, id in
      entry.reason == .planned ? DayPlanEntry(id: id, reason: .planned) : entry
    }
  }
}
