import Foundation

/// Where a deliberately started focus block runs once the app has put its own
/// window away.
enum FocusRunSurface: Int, CaseIterable {
  /// The floating focus panel, left up over whatever you work in.
  case panel
  /// Only the menu bar: the status item carries the task and its clock, and
  /// the keyboard goes back to the app you were in.
  case menuBar
  /// Both at once.
  case both

  var showsPanel: Bool { self != .menuBar }
  var showsMenuBarClock: Bool { self != .panel }
}
