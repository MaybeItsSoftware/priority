import TaktCore
import TaktWorkspace
import SwiftUI

/// The one question asked at the end of a focus block: how did that go?
///
/// It is deliberately the only thing on screen, and answered with the arrow
/// keys. The block is worth the minutes it took times this multiplier, which
/// starts at ×1.0 — an ordinary block — and moves a tenth at a time, so the
/// answer is a small adjustment from "it was fine" rather than a pick from a
/// menu of adjectives. The running total is shown while choosing, so the cost
/// of flattering yourself is visible at the moment you would do it.
///
/// When the clock had run out the block was a pomodoro, not a finished task,
/// so the prompt leads with a break and asks whether the task is done rather
/// than assuming it. It is asked even with the scoring question turned off,
/// without the dial.
///
/// Below the dial is a note — where it got to, what is left — which goes on
/// the end of the task's notes. Everything is reachable from the keyboard:
/// ↑ ↓ move the dial, ← → choose among the actions, ↩ takes the chosen one,
/// tab or n moves into the note and tab or esc back out, and each action has
/// a letter of its own.
struct WorkspaceFocusQualityPrompt: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let pending: WorkspaceViewModel.PendingFocusCompletion
  /// Nil when the prompt is filling a surface that already has a width — the
  /// summoned panel, where it is the whole of what is on screen.
  var fixedWidth: CGFloat? = 500

  /// Tenths, so that ten presses of ↑ land on exactly ×2.0 rather than on
  /// whatever ten additions of 0.1 come to in binary.
  @State private var tenths = 10
  @State private var note = ""
  /// The action ↩ takes. Nil until moved, which means the last in the row.
  @State private var chosen: Choice?
  @FocusState private var focus: Field?

  private enum Field: Hashable { case dial, note }

  /// The ways out of the prompt, which the action row is drawn from.
  private enum Choice: Hashable {
    case keepWorking, progress, done, takeBreak
  }

  private static let step = 1
  private static var tenthsRange: ClosedRange<Int> {
    Int(FocusPoints.multiplierRange.lowerBound * 10)...Int(FocusPoints.multiplierRange.upperBound * 10)
  }

  private var multiplier: Double { Double(tenths) / 10 }

  private var points: Double {
    FocusPoints.score(seconds: pending.seconds, multiplier: multiplier)
  }

  /// Whether the dial is drawn: always, unless this is the time-up question
  /// asked of someone who turned the scoring off.
  private var scores: Bool { !pending.timeIsUp || model.asksHowEachBlockWent() }

  /// Scored at the dial when it is drawn, at the neutral ×1.0 when not.
  private var answer: Double { scores ? multiplier : 1 }

  private var breakMinutes: Int {
    max(1, (model.activeFocusSession?.breakDurationSeconds ?? 300) / 60)
  }

  /// Left to right, with what the key that ended the block asked for last —
  /// the rightmost, chosen to begin with, and the one ↩ takes untouched.
  private var choices: [Choice] {
    if pending.timeIsUp { return [.keepWorking, .done, .takeBreak] }
    return pending.completeTask ? [.keepWorking, .progress, .done] : [.keepWorking, .done, .progress]
  }

  private var selected: Choice { chosen ?? choices[choices.count - 1] }

  private var editingNote: Bool { focus == .note }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      header
      if scores {
        dial
        tally
      }
      FocusRule()
      noteField
      actions
      FocusRule(muted: true)
      hints
    }
    .padding(theme.space.xl)
    .frame(width: fixedWidth)
    // Raised when it is a sheet over the window, the page when it fills the
    // panel: an overlay sits above the paper, a surface of its own does not.
    .background(fixedWidth == nil ? theme.paper : theme.raised)
    .interactiveDismissDisabled()
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .dial)
    // Every key below is the prompt's only while the note is not being
    // written: a "d" typed into the note is a letter, not Done.
    .onKeyPress(.upArrow) { key { nudge(by: Self.step) } }
    .onKeyPress(.downArrow) { key { nudge(by: -Self.step) } }
    .onKeyPress(.leftArrow) { key { move(by: -1) } }
    .onKeyPress(.rightArrow) { key { move(by: 1) } }
    .onKeyPress(.return) { key { run(selected) } }
    .onKeyPress(.tab) { key { focus = .note } }
    .onKeyPress(characters: ["n"]) { _ in key { focus = .note } }
    .onKeyPress(characters: ["r"]) { _ in key { tenths = 10 } }
    .onKeyPress(characters: ["d"]) { _ in key { run(.done) } }
    .onKeyPress(characters: ["b"]) { _ in
      key(when: pending.timeIsUp) { run(.takeBreak) }
    }
    .onKeyPress(characters: ["p"]) { _ in
      key(when: !pending.timeIsUp) { run(.progress) }
    }
    // A menial task, or a block that should not count for some other reason:
    // one key logs it at nothing, without stepping the dial down ten times.
    .onKeyPress(characters: ["\\"]) { _ in
      key { run(choices[choices.count - 1], multiplier: 0) }
    }
    .onAppear { focus = .dial }
    .onExitCommand {
      if editingNote { focus = .dial } else { model.cancelFocusCompletion() }
    }
  }

  /// Runs `action` for a key pressed on the prompt, and lets the key through
  /// to the note when the note has the keyboard.
  private func key(when applies: Bool = true, _ action: () -> Void) -> KeyPress.Result {
    guard !editingNote, applies else { return .ignored }
    action()
    return .handled
  }

  private func move(by delta: Int) {
    guard let index = choices.firstIndex(of: selected) else { return }
    chosen = choices[min(max(index + delta, 0), choices.count - 1)]
  }

  private func run(_ choice: Choice, multiplier: Double? = nil) {
    let score = multiplier ?? answer
    switch choice {
    case .keepWorking: model.cancelFocusCompletion()
    case .progress: model.confirmFocusCompletion(multiplier: score, completeTask: false, note: note)
    case .done: model.confirmFocusCompletion(multiplier: score, completeTask: true, note: note)
    case .takeBreak: model.takeFocusBreak(multiplier: score, note: note)
    }
  }

  private func nudge(by delta: Int) {
    let range = Self.tenthsRange
    tenths = min(max(tenths + delta, range.lowerBound), range.upperBound)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      MicroLabel(headline)
      Text(pending.title)
        .font(theme.titleFont)
        .foregroundStyle(theme.ink)
        .lineLimit(2)
        .truncationMode(.tail)
        .help(pending.title)
      Text("\(FocusPoints.formatted(pending.minutes)) minutes of focused work")
        .font(theme.captionFont)
        .monospacedDigit()
        .foregroundStyle(theme.muted)
    }
  }

  private var headline: String {
    if pending.timeIsUp { return scores ? "Time's up · how did that go?" : "Time's up" }
    return pending.completeTask ? "Complete task · how did that go?" : "Log progress · how did that go?"
  }

  /// The multiplier, large, between the two buttons that move it. Always one
  /// decimal place, so ×1.0 and ×1.1 read as neighbours rather than as a
  /// whole number and a fraction.
  private var dial: some View {
    HStack(spacing: theme.space.md) {
      stepButton("minus", help: "Less (↓)", enabled: tenths > Self.tenthsRange.lowerBound) {
        nudge(by: -Self.step)
      }
      Text("×" + String(format: "%.1f", multiplier))
        .font(theme.numeralFont(theme.scale.display, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(tenths == 10 ? theme.ink : theme.primary)
        .contentTransition(.numericText(value: multiplier))
        .animation(.snappy, value: tenths)
        .frame(minWidth: 120)
        .accessibilityLabel("Multiplier \(String(format: "%.1f", multiplier))")
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: nudge(by: Self.step)
          case .decrement: nudge(by: -Self.step)
          @unknown default: break
          }
        }
      stepButton("plus", help: "More (↑)", enabled: tenths < Self.tenthsRange.upperBound) {
        nudge(by: Self.step)
      }
      Spacer(minLength: 0)
      if tenths != 10 {
        Button("Reset") { tenths = 10 }
          .buttonStyle(FocusActionButtonStyle())
          .focusable(false)
          .help("Back to ×1.0")
      }
    }
  }

  private func stepButton(
    _ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
    }
    .buttonStyle(FocusActionButtonStyle())
    .focusable(false)
    .disabled(!enabled)
    .help(help)
    .accessibilityLabel(help)
  }

  private var tally: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        MicroLabel("This block")
        Text("\(FocusPoints.formatted(points)) pts")
          .font(theme.numeralFont(theme.scale.display))
          .monospacedDigit()
          .foregroundStyle(theme.primary)
          .contentTransition(.numericText())
          .animation(.snappy, value: points)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: theme.space.xxs) {
        MicroLabel("Today")
        Text("\(FocusPoints.formatted(model.focusPoints.today + points)) pts")
          .font(theme.numeralFont(theme.scale.title))
          .monospacedDigit()
          .foregroundStyle(theme.ink)
      }
    }
  }

  /// What was done and what is left, kept on the task. ↩ in it still takes
  /// the chosen action, so a note costs no extra keystroke to leave by.
  private var noteField: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      HStack {
        MicroLabel("Note")
        Spacer()
        Text("Added to the task's notes")
          .font(theme.captionFont)
          .foregroundStyle(theme.dim)
      }
      TextField("Note", text: $note, prompt: Text(notePrompt), axis: .vertical)
        .lineLimit(2...6)
        .themedTextField()
        .focused($focus, equals: .note)
        .onSubmit { run(selected) }
        .onKeyPress(.tab) {
          focus = .dial
          return .handled
        }
        .help("⌥↩ new line · ↩ \(title(of: selected).lowercased()) · tab or esc back to the dial")
    }
  }

  private var notePrompt: String {
    pending.completeTask && !pending.timeIsUp
      ? "What got done, anything worth remembering"
      : "Where you got to, what's next"
  }

  /// One button per way out, each with its key. The chosen one is drawn as
  /// the prominent one, so the colour says what ↩ will do.
  private var actions: some View {
    HStack(spacing: theme.space.sm) {
      ForEach(choices, id: \.self) { choice in
        Button { run(choice) } label: {
          HStack(spacing: theme.space.xs) {
            Text(title(of: choice))
            KeyCap(keyName(of: choice))
          }
        }
        .buttonStyle(FocusActionButtonStyle(prominent: choice == selected))
        .focusable(false)
        .help(help(of: choice))
        .accessibilityAddTraits(choice == selected ? .isSelected : [])
        if choice == .keepWorking { Spacer(minLength: theme.space.sm) }
      }
    }
    .animation(.snappy(duration: 0.15), value: selected)
  }

  private func title(of choice: Choice) -> String {
    switch choice {
    case .keepWorking: "Keep working"
    case .progress: pending.completeTask ? "Log, keep open" : "Log progress"
    case .done: pending.timeIsUp || !pending.completeTask ? "Done" : "Complete"
    case .takeBreak: "\(breakMinutes)-minute break"
    }
  }

  private func keyName(of choice: Choice) -> String {
    switch choice {
    case .keepWorking: "esc"
    case .progress: "p"
    case .done: "d"
    case .takeBreak: "b"
    }
  }

  private func help(of choice: Choice) -> String {
    switch choice {
    case .keepWorking: "Back to the block, with the time spent here left out"
    case .progress: "Log the time and leave the task open"
    case .done: "Log the time and finish the task"
    case .takeBreak: "Log the time, keep the task, and rest"
    }
  }

  /// The keys that are not on a button. While the note is being written they
  /// are the note's keys instead.
  private var hints: some View {
    HStack(spacing: theme.space.md) {
      if editingNote {
        KeyHint("↩", title(of: selected).lowercased())
        KeyHint("⌥↩", "new line")
        KeyHint("tab", "back")
      } else {
        if scores { KeyHint("↑↓", "adjust") }
        KeyHint("←→", "choose")
        KeyHint("↩", "confirm")
        KeyHint("n", "note")
        KeyHint("\\", "log at ×0")
      }
      Spacer(minLength: 0)
    }
  }
}
