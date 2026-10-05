import TaktCore
import SwiftUI

/// No motion at all: the row simply goes.
///
/// Not a no-op for the *whole* interaction — the haptics still fire, because
/// they sit outside the celebration protocol. This is the preset for someone
/// who wants completing a task to cost zero milliseconds, and it is the only
/// one that genuinely adds no latency to the close.
///
/// Silent too, and not by omission: a preset whose whole point is that nothing
/// happens should not start making noise when the sound preference goes on.
@MainActor
final class NoneCelebrationPlugin: CompletionCelebrationPlugin {
  let pluginIdentifier = "native.celebration.none"
  let displayName = "None"
  let pluginDescription = "No animation. Completing is instant."
  let celebrationIconSystemName = "circle.slash"
  let rowTreatment = CelebrationRowTreatment.none

  /// An empty script, which the default `runInline` returns from immediately
  /// without so much as a zero-length sleep.
  func inlineScript(for event: CompletionEvent, reduceMotion: Bool) -> CelebrationScript {
    .empty
  }
}
