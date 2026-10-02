import ActivityKit
import Foundation

/// The running focus block, as a Live Activity and on the Dynamic Island.
///
/// The clock is not pushed every second: the state carries when the block
/// would have started had it never paused, and the widget draws a live timer
/// from that. Only pausing, resuming and switching task update the activity.
struct FocusActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var taskID: String
    var taskTitle: String
    var timerStart: Date
    var isPaused: Bool
    /// Seconds worked, as of the last update. What a paused block shows.
    var elapsedSeconds: Int
    /// What was committed to on the focus screen, when something was.
    var plannedSeconds: Int?

    /// When the committed time runs out, for a progress bar.
    var plannedEnd: Date? {
      plannedSeconds.map { timerStart.addingTimeInterval(TimeInterval($0)) }
    }
  }

  /// The session this activity stands for. Fixed for its life.
  var sessionID: String
}
