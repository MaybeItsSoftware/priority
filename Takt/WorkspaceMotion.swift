import AppKit
import SwiftUI

/// The app's one motion: a short ease-out, used for the small changes a
/// keyboard-first app makes constantly — a selection moving, a branch folding,
/// a view swapping in.
///
/// Short enough that holding an arrow key never waits on it, and applied only
/// to changes of a single row or a single pane, never to a reload of a whole
/// list, so a thousand-row outline costs nothing more than it did. Reduce
/// Motion collapses the duration rather than removing the change.
enum WorkspaceMotion {
  static let duration: Double = 0.14

  /// The animation for a value change, or nil under Reduce Motion.
  static var quick: Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: duration)
  }

  /// Runs `body` animated, or plainly under Reduce Motion.
  static func animate<Result>(_ body: () throws -> Result) rethrows -> Result {
    try withAnimation(quick, body)
  }
}
