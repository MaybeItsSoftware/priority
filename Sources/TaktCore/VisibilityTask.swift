import Foundation

/// The slice of a task that the visibility and filter algorithms actually read.
///
/// `TaskVisibilityEngine` and `TaskFilterEngine` decide what the user sees —
/// which is the behaviour most worth pinning down in tests — but they used to
/// name `CheckvistTask` directly, which kept them out of `TaktCore` (it may
/// not depend on the plugin layer) and therefore out of every test target. They
/// were the largest pieces of genuinely pure logic in the app with no coverage
/// at all.
///
/// Naming this abstraction instead is not just a packaging trick: sorting and
/// filtering a task list has nothing to do with Checkvist, and stating exactly
/// which six properties the algorithms depend on is a useful thing to have
/// written down. `CheckvistTask` conforms in a one-line app-side extension, and
/// tests conform a small fixture struct.
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
