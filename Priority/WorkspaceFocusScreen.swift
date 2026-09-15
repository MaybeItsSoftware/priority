import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The way into the focus screen, sitting above the lists.
///
/// It shows what it would start on, because a button that hides its own
/// consequence gets pressed once and then avoided. When a session is already
/// running it becomes the way back to it rather than a second start.
struct WorkspaceFocusLauncher: View {
  @Environment(WorkspaceViewModel.self) private var model
  @State private var isHovering = false

  var body: some View {
    Button {
      if model.activeFocusSession != nil {
        model.showsFocusPanel = true
      } else {
        model.presentFocusScreen()
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: model.activeFocusSession == nil ? "target" : "timer")
          Text(model.activeFocusSession == nil ? "FOCUS" : "IN SESSION")
            .font(.caption2.weight(.bold))
            .tracking(1.2)
          Spacer(minLength: 0)
          Text("⌘8")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
        }
        .foregroundStyle(model.activeFocusSession == nil ? .secondary : Color.accentColor)

        Text(headline)
          .font(.callout.weight(.medium))
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(.primary)

        if let detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(
        isHovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .focusable()
    .onHover { isHovering = $0 }
    .help(model.activeFocusSession == nil ? "Start a focus session on your next task" : "Return to the running session")
    .accessibilityLabel(model.activeFocusSession == nil ? "Start focus. Next up: \(headline)" : "Return to focus session")
  }

  private var headline: String {
    if let active = model.activeFocusTask { return active.title }
    return model.nextUp?.candidate.title ?? "Nothing to pick up"
  }

  private var detail: String? {
    if model.activeFocusSession != nil { return "Session running" }
    guard let reason = model.nextUp?.reason else { return "Add a task or a daily to get started" }
    return reason.explanation.localizedCapitalized
  }
}
/// Focus mode: the workspace gets out of the way and one task is put in front
/// of you.
///
/// The work is presented as a **ladder**. The foot of it is the most important
/// thing you could be doing; climbing moves up through work of decreasing
/// priority. That direction is the whole interaction — deciding what to do is
/// rarely "show me everything", it is "not that, what's next", and a ladder
/// answers that one rung at a time without ever showing you the backlog.
///
/// From any rung you can stage the task (commit to it, set an estimate, start)
/// or simply tick it off, because a fair number of things on any list are
/// already done or were never really work.
struct WorkspaceFocusScreen: View {
  @Environment(WorkspaceViewModel.self) private var model

  /// How many rungs either side of the cursor are drawn. A window rather than
  /// the whole list: a focus screen you can scroll through is a task list.
  private static let visibleAbove = 3
  private static let visibleBelow = 2

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.focusLadder.isEmpty {
        emptyState
      } else {
        ladder
      }
      Divider()
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("FOCUS")
        .font(.caption.weight(.bold))
        .tracking(1.5)
        .foregroundStyle(.secondary)
      if !model.focusLadder.isEmpty {
        Text("rung \(model.focusLadderIndex + 1) of \(model.focusLadder.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      Spacer()
      Button("Leave") { model.dismissFocusScreen() }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focusable()
      Text("Esc")
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  private var footer: some View {
    HStack(spacing: 18) {
      hint("↑", "Less important")
      hint("↓", "More important")
      hint("↵", model.stagedTask == nil ? "Stage" : "Begin")
      hint("X", "Tick off")
      Spacer()
      if model.stagedTask != nil {
        Text("Staged — set the estimate and begin")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
  }

  private func hint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 5) {
      Text(key)
        .font(.caption2.monospaced())
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "Nothing waiting",
      systemImage: "checkmark.circle",
      description: Text("Every daily is done and no task is due. Add something, or enjoy it."))
      .frame(maxHeight: .infinity)
  }

  // MARK: - The ladder

  /// Drawn top-down as least-important → most-important, so that climbing is
  /// literally upward movement on screen.
  private var ladder: some View {
    let index = model.focusLadderIndex
    let upper = min(model.focusLadder.count - 1, index + Self.visibleAbove)
    let lower = max(0, index - Self.visibleBelow)

    return VStack(spacing: 0) {
      if upper < model.focusLadder.count - 1 {
        moreMarker("\(model.focusLadder.count - 1 - upper) less important above")
      }
      Spacer(minLength: 0)
      ForEach(Array(stride(from: upper, through: lower, by: -1)), id: \.self) { rung in
        if rung == index {
          selectedRung(model.focusLadder[rung])
        } else {
          neighbourRung(model.focusLadder[rung], distance: abs(rung - index))
        }
      }
      Spacer(minLength: 0)
      if lower > 0 {
        moreMarker("\(lower) more important below")
      }
    }
    .padding(.horizontal, 28)
    .frame(maxHeight: .infinity)
  }

  private func moreMarker(_ text: String) -> some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(.quaternary)
      .padding(.vertical, 8)
  }

  /// A rung you are not on: enough to recognise, not enough to weigh up.
  private func neighbourRung(_ scored: ScoredNextUp, distance: Int) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon(for: scored.reason))
        .font(.caption)
      Text(scored.candidate.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .font(.callout)
    // Fading with distance makes the ordering legible without a single number
    // on screen: the further from your cursor, the less it is asking of you.
    .foregroundStyle(.secondary.opacity(max(0.25, 1 - Double(distance) * 0.28)))
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .contentShape(Rectangle())
    .onTapGesture { model.moveFocusLadder(by: rungOffset(to: scored)) }
  }

  private func rungOffset(to scored: ScoredNextUp) -> Int {
    guard let target = model.focusLadder.firstIndex(where: { $0.candidate.id == scored.candidate.id })
    else { return 0 }
    return target - model.focusLadderIndex
  }

  /// The rung under the cursor, and the only one that argues its case.
  private func selectedRung(_ scored: ScoredNextUp) -> some View {
    let task = model.focusLadderTask
    let isStaged = model.stagedTask?.id == scored.candidate.id

    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Image(systemName: icon(for: scored.reason))
          .foregroundStyle(tint(for: scored.reason))
        Text(scored.reason.explanation.localizedCapitalized)
          .font(.caption.weight(.medium))
          .foregroundStyle(tint(for: scored.reason))
        Spacer(minLength: 0)
        if let task, let list = model.list(for: task) {
          Text(list.name)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Text(scored.candidate.title)
        .font(.system(size: 26, weight: .semibold))
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      if let meta = metaLine(for: scored, task: task) {
        Text(meta)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if isStaged {
        estimatePicker
        stagedActions
      } else {
        unstagedActions
      }
    }
    .padding(20)
    .frame(maxWidth: 560, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(isStaged ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isStaged ? 2 : 1))
  }

  private func metaLine(for scored: ScoredNextUp, task: WorkspaceTask?) -> String? {
    var parts: [String] = []
    if let due = scored.candidate.dueAt {
      parts.append("Due \(due.formatted(.relative(presentation: .named)))")
    }
    if let estimate = scored.candidate.estimateSeconds {
      parts.append("~\(max(1, estimate / 60))m")
    }
    if let task, let item = model.dailyItem(for: task), item.secondsLoggedToday > 0 {
      parts.append("\(item.secondsLoggedToday / 60)m done today")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Actions

  private var unstagedActions: some View {
    HStack(spacing: 10) {
      Button {
        model.stageFocusLadderSelection()
      } label: {
        Label("Stage this", systemImage: "target")
      }
      .buttonStyle(.borderedProminent)
      .focusable()
      .keyboardShortcut(.defaultAction)

      Button {
        model.completeFocusLadderSelection()
      } label: {
        Label("Tick off", systemImage: "checkmark")
      }
      .buttonStyle(.bordered)
      .focusable()

      Menu {
        ForEach(WorkspaceDeferral.allCases) { option in
          Button(option.title) {
            guard let task = model.focusLadderTask else { return }
            model.scheduleForLater(task, until: option.date(from: .now))
          }
        }
      } label: {
        Label("Later", systemImage: "clock")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Spacer(minLength: 0)
    }
  }

  private var stagedActions: some View {
    HStack(spacing: 10) {
      Button {
        model.beginStagedFocus()
      } label: {
        Label("Begin \(max(1, model.focusEstimateMinutes))m", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .focusable()
      .keyboardShortcut(.defaultAction)

      Button("Not yet") { model.unstageFocusTask() }
        .buttonStyle(.bordered)
        .focusable()

      Spacer(minLength: 0)
    }
  }

  private var estimatePicker: some View {
    @Bindable var bindable = model
    return VStack(alignment: .leading, spacing: 8) {
      Text("HOW LONG WILL YOU GIVE IT?")
        .font(.caption2.weight(.bold))
        .tracking(1.2)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ForEach([5, 10, 15, 25, 45, 60, 90], id: \.self) { minutes in
          Button("\(minutes)m") { model.focusEstimateMinutes = minutes }
            .buttonStyle(.bordered)
            .tint(model.focusEstimateMinutes == minutes ? Color.accentColor : nil)
            .focusable()
        }
        Stepper("", value: $bindable.focusEstimateMinutes, in: 1...480, step: 5)
          .labelsHidden()
      }
    }
  }

  // MARK: - Reason styling

  private func icon(for reason: NextUpReason) -> String {
    switch reason {
    case .daily: return "arrow.triangle.2.circlepath"
    case .overdue: return "exclamationmark.triangle.fill"
    case .dueToday: return "calendar.badge.exclamationmark"
    case .dueSoon: return "calendar"
    case .today: return "tray.full"
    case .importance: return "star.fill"
    case .priority: return "flag.fill"
    case .order: return "list.bullet"
    }
  }

  private func tint(for reason: NextUpReason) -> Color {
    switch reason {
    case .daily: return .green
    case .overdue: return .red
    case .dueToday, .dueSoon: return .orange
    case .today: return .accentColor
    case .importance, .priority: return .purple
    case .order: return .secondary
    }
  }
}

enum WorkspaceDeferral: String, CaseIterable, Identifiable {
  case anHour
  case thisAfternoon
  case tomorrow
  case nextWeek

  var id: String { rawValue }

  var title: String {
    switch self {
    case .anHour: return "In an hour"
    case .thisAfternoon: return "This afternoon"
    case .tomorrow: return "Tomorrow morning"
    case .nextWeek: return "Next week"
    }
  }

  func date(from now: Date, calendar: Calendar = .current) -> Date {
    switch self {
    case .anHour:
      return now.addingTimeInterval(3_600)
    case .thisAfternoon:
      let afternoon = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
      // Already past two o'clock: an hour from now is the honest reading.
      return afternoon > now ? afternoon : now.addingTimeInterval(3_600)
    case .tomorrow:
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    case .nextWeek:
      let week = calendar.date(byAdding: .day, value: 7, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: week) ?? week
    }
  }
}
