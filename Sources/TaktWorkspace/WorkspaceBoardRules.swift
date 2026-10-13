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
}
