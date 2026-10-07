import Foundation

/// Where an arrow key leaves a cursor in a list of `count` rows.
///
/// A single step wraps: ↑ on the first row goes to the last, ↓ on the last
/// goes to the first, so the far end of a long list is one key away rather
/// than a held one. A bigger jump — Page Up, Page Down — stops at the end
/// instead, because overshooting by a page and landing near the top again
/// would lose your place.
public enum CursorStepping {
  public static func index(from current: Int, by offset: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    if abs(offset) == 1 {
      return ((current + offset) % count + count) % count
    }
    return min(max(0, current + offset), count - 1)
  }
}
