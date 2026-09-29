import PriorityCore
import PriorityWorkspace
import SwiftUI

// The day's finish-by figure, kept beside the day view rather than in it: the
// arithmetic is `DayForecast`'s, and what is here is only how the app feeds it
// and how the figure reads.

extension WorkspaceViewModel {
  /// The given tasks as the forecast sees them. The stored totals only gain a
  /// block when it ends, so the running task's live elapsed is added on top —
  /// without it the finish time would stand still for the whole block. On a
  /// break the block has already been recorded, so nothing is added then.
  func dayForecast(for tasks: [WorkspaceTask], now: Date) -> DayForecast {
    let session = activeFocusSession
    let runningID = session?.phase == .running ? session?.activeTaskId : nil
    let entries = tasks.map { task -> DayForecast.Entry in
      var logged = taskLoggedSeconds[task.id] ?? 0
      if task.id == runningID, let session { logged += session.elapsedSeconds(now: now) }
      return DayForecast.Entry(estimateSeconds: task.estimateSeconds, loggedSeconds: logged)
    }
    return DayForecast(entries: entries, now: now)
  }

  /// Whether a block's clock is moving, which is when the finish time is
  /// worth redrawing more often than once a minute.
  var isFocusBlockTicking: Bool {
    guard let session = activeFocusSession else { return false }
    return session.phase == .running && session.pausedAt == nil
  }
}

extension DayForecast {
  /// "1h 20m of 3h · 1h 40m left · done by 17:35", with whatever does not
  /// apply left off: no estimates means no "of" and no finish, and a day whose
  /// estimates are all spent has nothing left to finish by.
  var tallyText: String {
    let spent = Self.hoursAndMinutes(loggedSeconds)
    guard estimatedSeconds > 0 else { return "\(spent) logged" }
    var parts = ["\(spent) of \(Self.hoursAndMinutes(estimatedSeconds))"]
    if let leftAndFinish { parts.append(leftAndFinish) }
    return parts.joined(separator: " · ")
  }

  /// The panel's "Est 3h · 1h 40m left · done by 17:35": its bar already
  /// shows what is spent, so the line leads with the plan instead.
  var panelLine: String {
    guard estimatedSeconds > 0 else { return "No estimates yet" }
    let plan = "Est \(Self.hoursAndMinutes(estimatedSeconds))"
    guard let leftAndFinish else { return plan }
    return "\(plan) · \(leftAndFinish)"
  }

  /// Says how the finish time was reached, since it is naive on purpose, and
  /// how many tasks it could not count — each one makes it optimistic.
  var helpText: String {
    guard estimatedSeconds > 0 else {
      return "Time focused on today's tasks. Nothing on the day has an estimate yet, so there is no finish time."
    }
    var text = "Time focused on today's tasks against their estimates. "
    text += finishAt == nil
      ? "Every estimate is used up."
      : "The finish time is now plus what the estimates still owe, worked straight through with no breaks."
    switch unestimatedCount {
    case 0: break
    case 1: text += " 1 task has no estimate and is not counted."
    default: text += " \(unestimatedCount) tasks have no estimate and are not counted."
    }
    return text
  }

  private var leftAndFinish: String? {
    guard let finishAt else { return nil }
    // The user's own clock, 12- or 24-hour as their locale has it.
    let time = finishAt.formatted(date: .omitted, time: .shortened)
    return "\(Self.hoursAndMinutes(remainingSeconds)) left · done by \(time)"
  }

  /// Hours and minutes, never seconds: an estimate measured to the second is
  /// a precision nobody typed in. The day view's own durations use this too,
  /// so a figure in the tally and the same figure on a card cannot disagree.
  static func hoursAndMinutes(_ seconds: Int) -> String {
    let minutes = max(0, seconds) / 60
    if minutes < 60 { return "\(minutes)m" }
    let remainder = minutes % 60
    return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
  }
}

/// A row's estimate. In the window it is a button onto the estimate quick
/// edit: dim like the rest of the row's second line until the pointer is on
/// it, then ink and underlined, so it reads as clickable without shouting
/// about it when it is not. The panel passes no action — it has no overlay
/// host to open the edit in — and gets plain text.
///
/// Its own view so its hover is its own: the row already tracks one for the
/// whole card, and the estimate lighting up whenever the card does would
/// promise a click anywhere on the row.
struct DayEstimateLabel: View {
  @Environment(\.theme) private var theme
  let text: String
  var help: String = ""
  var action: (() -> Void)?
  @State private var isHovering = false

  var body: some View {
    if let action {
      Button(action: action) {
        label.underline(isHovering)
          .foregroundStyle(isHovering ? theme.ink : theme.dim)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
      .onHover { isHovering = $0 }
      .help(help)
      .accessibilityLabel("Estimate: \(text)")
      .accessibilityHint(help)
    } else {
      label.foregroundStyle(theme.dim)
    }
  }

  private var label: some View {
    Text(text)
      .font(theme.captionFont)
      .monospacedDigit()
  }
}
