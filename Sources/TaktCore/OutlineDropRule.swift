import Foundation
import TaktRustCore

/// How a drag in an outline lands in the tree, read from the rows directly
/// above and below the drop: before a sibling, after the last of them, or
/// into another parent's children. The rule is the Rust core's
/// (`outline_drop_plan` in `core/src/shaping.rs`), shared with Android; one
/// call per drop.
public enum OutlineDropRule {
  public enum Plan: Equatable, Sendable {
    /// Before the sibling at this row index.
    case before(Int)
    /// After the last of its siblings.
    case toEnd
    /// Into the children of the parent of the row at `anchor`, before that row
    /// when `before`, else at the end of them.
    case reparent(anchor: Int, before: Bool)
  }

  /// One row as a drop reads it.
  public struct Row: Equatable, Sendable {
    public var depth: Int
    public var parentID: String?
    public var listID: String

    public init(depth: Int, parentID: String?, listID: String) {
      self.depth = depth
      self.parentID = parentID
      self.listID = listID
    }
  }

  /// `destination` is the index in `rows`, before the move, that the row is
  /// inserted in front of (SwiftUI's `onMove` offset). Nil when the drop
  /// changes nothing.
  public static func plan(rows: [Row], source: Int, destination: Int) -> Plan? {
    guard source >= 0, destination >= 0 else { return nil }
    let plan = outlineDropPlan(
      rows: rows.map {
        OutlineDropRow(depth: UInt32(max(0, $0.depth)), parentId: $0.parentID, listId: $0.listID)
      },
      source: UInt32(source), destination: UInt32(destination))
    switch plan {
    case .none: return nil
    case .before(let target): return .before(Int(target))
    case .toEnd: return .toEnd
    case .reparent(let anchor, let before): return .reparent(anchor: Int(anchor), before: before)
    }
  }
}
