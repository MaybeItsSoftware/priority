import Foundation

/// The slice of a Checkvist task that `TaskFilterEngine` and `DayLogPlan` read.
///
/// Named so that pure logic about Checkvist tasks can live in `TaktCore`, which
/// may not depend on the plugin layer that defines `CheckvistTask`, and be
/// tested there. `CheckvistTask` conforms in a one-line app-side extension, and
/// tests conform a small fixture struct. The legacy visibility engine this was
/// written for went in Phase 6 of the desktop roadmap.
public protocol VisibilityTask: Identifiable, Equatable {
  var id: Int { get }
  var content: String { get }
  /// The raw due string as entered — may be a keyword like "asap" or "today"
  /// that never resolves to a calendar date.
  var due: String? { get }
  /// The parsed form of `due`, when it names an actual date.
  var dueDate: Date? { get }
  var position: Int? { get }
  var parentId: Int? { get }
}
