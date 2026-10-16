import Foundation
import TaktRustCore

extension WorkspaceKanbanColumn {
  /// The id a new column titled `title` takes, unique among `columns`: the
  /// Rust core's `board_column_id`, shared with Android.
  public static func newID(title: String, among columns: [WorkspaceKanbanColumn]) -> String {
    boardColumnId(title: title, taken: columns.map(\.id))
  }
}

extension WorkspaceFilterDefinition {
  /// Whether a pane showing this filter list leaves finished tasks out, given
  /// the hide-completed toggle. A filter list that asks for finished work
  /// shows it whatever the toggle says: hiding it would empty the list it was
  /// made to show.
  public func hidesCompleted(whenToggled hidesCompleted: Bool) -> Bool {
    hidesCompleted && show == .open
  }

  /// Whether a pane showing this filter list leaves buried tasks out, given
  /// the hide-later toggle. One with a rule on the start date asks about
  /// starts itself, so it shows what it matches whatever the toggle says.
  public func hidesLater(whenToggled hidesLater: Bool) -> Bool {
    hidesLater && !rules.contains { $0.field == "start" }
  }
}
